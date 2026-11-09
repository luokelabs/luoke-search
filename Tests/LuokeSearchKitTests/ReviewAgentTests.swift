import Foundation
import Testing
@testable import LuokeSearchKit

// The whole-branch review of 11bc2ca (2026-10-20): each test reproduces one finding, named by its number.

/// A client connection that sends what the test says and nothing more.
func rawConnect(_ path: String) -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: Array(path.utf8))
        raw[path.utf8.count] = 0
    }
    _ = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

/// What the server sends back on `fd` until it closes (at most `seconds`).
func readAll(_ fd: Int32, seconds: Int = 5) -> String {
    var wait = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
    var out = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        out.append(buffer, count: count)
    }
    return String(decoding: out, as: UTF8.self)
}

struct ReviewProtocolTests {
    func answer(_ server: MCPServer, _ json: String) throws -> [String: Any] {
        let data = try #require(server.handle(json: Data(json.utf8)))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("C-01: an id or uri that is an infinite number doesn't crash the server")
    func infiniteIDs() throws {
        let server = MCPServer(name: "t", version: "0")
        server.add(MCPServer.Resource(uri: "ai.luoke.search://outbox", name: "outbox") { [:] })
        let ping = try answer(server, #"{"jsonrpc":"2.0","id":-1e400,"method":"ping"}"#)
        #expect((ping["error"] as? [String: Any])?["code"] as? Int == -32600)
        #expect(ping["id"] is NSNull)
        let read = try answer(server, #"{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":-1e400}}"#)
        #expect((read["error"] as? [String: Any])?["code"] as? Int == -32002)
        #expect(try answer(server, #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#)["id"] is NSNull)
        #expect(try answer(server, #"{"jsonrpc":"2.0","id":"a","method":"ping"}"#)["id"] as? String == "a")
    }

    @Test("C-22: initialize offers only the version spoken here; null params and arguments are empty")
    func versionsAndNulls() throws {
        let server = MCPServer(name: "t", version: "0")
        let initialize = try answer(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        #expect((initialize["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServer.protocolVersion)
        #expect(try answer(server, #"{"jsonrpc":"2.0","id":2,"method":"ping","params":null}"#)["result"] != nil)
        server.add(MCPServer.Tool(name: "echo", title: "echo", description: "", schema: ["type": "object"]) { arguments, _ in
            ("\(arguments.count)", [:])
        })
        let call = try answer(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":null,"_meta":null}}"#)
        let content = ((call["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(content == "0")
    }

    @Test("C-15: card text is cut by code points, as the agent counts")
    func clipByCodePoints() {
        let heavy = String(repeating: "e\u{301}\u{301}", count: 1500)   // 1500 characters, 4500 code points
        let clipped = Card.clip(heavy)
        #expect(clipped.unicodeScalars.count <= Card.maxText)
        #expect(clipped.hasSuffix("…"))
        #expect(Card.clip("短") == "短")
    }
}

struct ReviewSocketTests {
    @Test("C-03: past the connection limit a client is turned away, and the server still answers afterwards")
    func connectionLimit() throws {
        let path = "/tmp/lsag-\(UUID().uuidString.prefix(8)).sock"
        let socket = AgentSocket(path: path, server: MCPServer(name: "t", version: "0"))
        socket.maxConnections = 2
        try socket.start()
        defer { socket.stop() }
        let idle = (0..<6).map { _ in rawConnect(path) }   // connected, saying nothing
        Thread.sleep(forTimeInterval: 0.3)
        let ping = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let turnedAway = rawConnect(path)
        #expect(readAll(turnedAway).hasPrefix("HTTP/1.1 503"))
        close(turnedAway)
        idle.forEach { close($0) }
        #expect(eventually(5) {
            (try? UnixHTTP.request(socket: path, method: "POST", target: "/mcp", body: ping, timeout: 5).status) == 200
        })
    }

    @Test("C-10: a head that never ends, or a request that never finishes, is let go")
    func endlessRequests() throws {
        let path = "/tmp/lsag-\(UUID().uuidString.prefix(8)).sock"
        let socket = AgentSocket(path: path, server: MCPServer(name: "t", version: "0"))
        socket.requestDeadline = 1
        try socket.start()
        defer { socket.stop() }
        let long = rawConnect(path)
        let head = "POST /mcp HTTP/1.1\r\nX: " + String(repeating: "a", count: 20_000)
        _ = head.withCString { Darwin.write(long, $0, strlen($0)) }
        #expect(readAll(long).hasPrefix("HTTP/1.1 400"))
        close(long)
        let slow = rawConnect(path)
        let started = Date()
        _ = "POST /mcp HTTP/1.1\r\n".withCString { Darwin.write(slow, $0, strlen($0)) }
        #expect(readAll(slow).hasPrefix("HTTP/1.1 400"))
        #expect(Date().timeIntervalSince(started) < 4)
        close(slow)
    }
}

extension ReadsPictures {
    struct ReviewOpenTests {
        @Test("C-02: a result id with nan, inf or a huge place doesn't crash search_open")
        func strangePlaces() throws {
            let agent = try Agent()
            let hits = try #require((agent.call("search_query", ["query": "团队版"])["structuredContent"]
                                     as? [String: Any])?["hits"] as? [[String: Any]])
            let item = try #require((hits.first?["id"] as? String)?.split(separator: "#").first)
            for place in ["pnan", "p1e300", "tinf", "t-1e300", "p-3", "w1e19"] {
                let target = try #require(try agent.service.target("\(item)#\(place)"))
                #expect(target.location == nil)
                _ = try agent.service.open("\(item)#\(place)", reveal: false)
            }
            #expect(Searcher.clock(.infinity) == "0:00")
            #expect(Searcher.clock(.nan) == "0:00")
        }
    }
}

struct ReviewReadingTests {
    @Test("A-01: an odt's space count can't be negative or huge")
    func odtSpaces() throws {
        let scratch = try Scratch()
        let file = try scratch.write("坏.odt", data: ZipWriter.odt(paragraphs: [
            "a<text:s text:c=\"-1\"/>b", "c<text:s text:c=\"2000000000\"/>d", "e<text:s text:c=\"3\"/>f",
        ]))
        let reading = Reader.read(file, kind: .doc)
        #expect(reading.outcome == .done)
        // Runs of spaces are one space by the time they're stored; what matters is that reading survives.
        #expect(reading.pieces.map(\.text).joined() == "ab\nc d\ne f")
    }
}

/// Every Text component in a card's messages: its text and variant.
enum ReviewCardTexts {
    static func texts(_ card: Any?) -> [(text: String, variant: String?)] {
        if let component = card as? [String: Any] {
            if component["component"] as? String == "Text", let text = component["text"] as? String {
                return [(text, component["variant"] as? String)]
            }
            return component.values.flatMap { texts($0) }
        }
        return (card as? [Any])?.flatMap { texts($0) } ?? []
    }
}
