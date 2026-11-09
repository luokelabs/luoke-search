import Foundation
import Testing
@testable import LuokeSearchKit

// The pre-release security review (10-23), must-fix 1 and 2: clients that go away early, and deeply nested
// JSON, used to take the whole serving process down (SIGPIPE, exit 141; a thread's stack overflowing, exit 138).
struct ReleaseReviewSocketTests {
    static let ping = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)

    static func started(maxConnections: Int = 32) throws -> (AgentSocket, String) {
        let path = "/tmp/lsag-\(UUID().uuidString.prefix(8)).sock"
        let socket = AgentSocket(path: path, server: MCPServer(name: "t", version: "0"))
        socket.maxConnections = maxConnections
        try socket.start()
        return (socket, path)
    }

    static func answers(_ path: String) -> Bool {
        eventually(5) {
            (try? UnixHTTP.request(socket: path, method: "POST", target: "/mcp", body: ping, timeout: 5).status) == 200
        }
    }

    /// A whole request on a fresh connection, closed without reading the answer.
    static func sendAndLeave(_ path: String, _ body: Data) {
        let fd = rawConnect(path)
        var request = Data("POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        request.append(body)
        _ = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        close(fd)
    }

    static func nested(_ depth: Int) -> Data {
        let inner = String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)
        return Data(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":\#(inner)}}"#.utf8)
    }

    @Test("Must-fix 1: a client that connects and closes without a word doesn't end the server")
    func connectAndClose() throws {
        let (socket, path) = try Self.started()
        defer { socket.stop() }
        for _ in 0..<20 {
            close(rawConnect(path))
        }
        Thread.sleep(forTimeInterval: 0.3)   // the server's threads answer (or not) the closed ones meanwhile
        #expect(Self.answers(path))
    }

    @Test("Must-fix 1: a client that sends its request and goes without reading the answer doesn't end the server")
    func sendAndGo() throws {
        let (socket, path) = try Self.started()
        defer { socket.stop() }
        let note = Data(#"{"jsonrpc":"2.0","method":"notifications/x"}"#.utf8)   // answered with a bare 202
        for round in 0..<50 {
            Self.sendAndLeave(path, round.isMultiple(of: 2) ? note : Self.ping)
        }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(Self.answers(path))
    }

    @Test("Must-fix 1: turning away (503) clients that are already gone doesn't end the server")
    func turnedAwayAndGone() throws {
        let (socket, path) = try Self.started(maxConnections: 1)
        defer { socket.stop() }
        let holding = rawConnect(path)   // takes the one place, says nothing
        Thread.sleep(forTimeInterval: 0.2)
        for _ in 0..<20 {
            close(rawConnect(path))
        }
        Thread.sleep(forTimeInterval: 0.3)
        close(holding)
        #expect(Self.answers(path))
    }

    @Test("Must-fix 1: a connection that sent nothing at all gets nothing back, not a 400")
    func nothingForNothing() throws {
        let (socket, path) = try Self.started()
        defer { socket.stop() }
        let quiet = rawConnect(path)
        shutdown(quiet, SHUT_WR)
        #expect(readAll(quiet).isEmpty)
        close(quiet)
        // Half a request is still a bad one.
        let half = rawConnect(path)
        _ = "POST /mcp HTTP/1.1\r\n".withCString { Darwin.write(half, $0, strlen($0)) }
        shutdown(half, SHUT_WR)
        #expect(readAll(half).hasPrefix("HTTP/1.1 400"))
        close(half)
    }

    @Test("Must-fix 2: deeply nested JSON on the socket is refused, and the server goes on", arguments: [480, 600, 5000])
    func nestedOnTheSocket(depth: Int) throws {
        let (socket, path) = try Self.started()
        defer { socket.stop() }
        let answer = try UnixHTTP.request(socket: path, method: "POST", target: "/mcp", body: Self.nested(depth),
                                          timeout: 10)
        #expect(answer.status == 200)
        let parsed = try JSONSerialization.jsonObject(with: answer.body) as? [String: Any]
        #expect((parsed?["error"] as? [String: Any])?["code"] as? Int == -32600)
        #expect(parsed?["id"] is NSNull)
        #expect(Self.answers(path))
    }

    @Test("Must-fix 2: nesting is counted outside strings only; up to 64 deep is fine")
    func nestingLimit() throws {
        let server = MCPServer(name: "t", version: "0")
        func code(_ data: Data) throws -> Int? {
            let answer = try JSONSerialization.jsonObject(with: try #require(server.handle(json: data))) as? [String: Any]
            return (answer?["error"] as? [String: Any])?["code"] as? Int
        }
        // The message itself and its params are two levels: 62 more make 64.
        #expect(try code(Self.nested(62)) == nil)
        #expect(try code(Self.nested(63)) == -32600)
        let brackets = String(repeating: "{[", count: 5000) + #"\"}"#
        let inString = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":"\#(brackets)"}}"#.utf8)
        #expect(try code(inString) == nil)
        #expect(try code(Data((String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)).utf8))
                == -32600)
        #expect(try code(Data("{not json".utf8)) == -32700)
    }
}
