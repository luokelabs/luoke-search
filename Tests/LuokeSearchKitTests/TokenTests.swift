import Darwin
import Foundation
import Testing
@testable import LuokeSearchKit

// The token on the agent's socket: 螺壳 hands it over in its answer to hello (`FromApp.token(in:)`), and the app as
// it ships lets in only requests that carry it in `_meta` (`MCPServer.needsToken`).
struct TokenTests {
    private func server(needs: Bool, token: String?, seen: @escaping ([String: Any]) -> Void = { _ in }) -> MCPServer {
        let server = MCPServer(name: "t", version: "0")
        server.add(MCPServer.Tool(name: "look", title: "看", description: "", schema: ["type": "object"]) { _, meta in
            seen(meta)
            return ("看了", [:])
        })
        server.needsToken = needs
        server.token = token
        return server
    }

    private func ask(_ server: MCPServer, _ method: String = "tools/call", token: String?) -> [String: Any] {
        var meta: [String: Any] = ["io.modelcontextprotocol/protocolVersion": MCPServer.protocolVersion]
        if let token { meta["ai.luoke/token"] = token }
        var params: [String: Any] = ["_meta": meta]
        if method == "tools/call" { params["name"] = "look"; params["arguments"] = [String: Any]() }
        return server.handle(["jsonrpc": "2.0", "id": 1, "method": method, "params": params]) ?? [:]
    }

    private func code(_ answer: [String: Any]) -> Int? { (answer["error"] as? [String: Any])?["code"] as? Int }

    @Test func refusesEveryRequestWithoutTheRightToken() {
        let want = String(repeating: "ab", count: 32)
        var ran = 0
        let s = server(needs: true, token: want) { _ in ran += 1 }
        for method in ["tools/call", "tools/list", "server/discover", "resources/list", "ping", "initialize"] {
            #expect(code(ask(s, method, token: nil)) == MCPServer.badToken, "\(method) without a token")
            #expect(code(ask(s, method, token: "x" + want.dropFirst())) == MCPServer.badToken, "\(method) wrong token")
            #expect(code(ask(s, method, token: want + "00")) == MCPServer.badToken, "\(method) longer token")
        }
        #expect(ran == 0)
        #expect(ask(s, token: want)["result"] != nil)
        #expect(ran == 1)
    }

    @Test func noToolSeesTheToken() {
        var seen: [String: Any] = [:]
        let s = server(needs: true, token: "0123456789abcdef") { seen = $0 }
        #expect(ask(s, token: "0123456789abcdef")["result"] != nil)
        #expect(seen["ai.luoke/token"] == nil)
        #expect(seen["io.modelcontextprotocol/protocolVersion"] as? String == MCPServer.protocolVersion)
    }

    @Test func withNoTokenGivenNobodyGetsIn() {
        let s = server(needs: true, token: nil)
        #expect(code(ask(s, token: nil)) == MCPServer.badToken)
        #expect(code(ask(s, token: "")) == MCPServer.badToken)
        #expect(code(ask(s, token: "0123456789abcdef")) == MCPServer.badToken)
    }

    @Test func developmentNeedsNone() {
        let s = server(needs: false, token: nil)
        #expect(ask(s, token: nil)["result"] != nil)
        #expect(ask(s, token: "anything")["result"] != nil)
    }

    @Test func sameComparesWholeStrings() {
        #expect(MCPServer.same("abc", "abc"))
        #expect(!MCPServer.same("abc", "abd"))
        #expect(!MCPServer.same("abc", "abcd"))
        #expect(!MCPServer.same("", "a"))
    }

    @Test func tokenInTheAnswerToHello() {
        let t = String(repeating: "7f", count: 32)
        #expect(FromApp.token(in: Data(#"{"id":0,"result":{"status":"ok","token":"\#(t)"}}"#.utf8)) == t)
        #expect(FromApp.token(in: Data(#"{"id":0,"result":{"status":"ok"}}"#.utf8)) == nil)
        #expect(FromApp.token(in: Data(#"{"id":0,"result":{"status":"failed","why":"这一次不代办","token":"\#(t)"}}"#.utf8)) == nil)
        #expect(FromApp.token(in: Data(#"{"id":0,"result":{"status":"ok","token":"short"}}"#.utf8)) == nil)
        #expect(FromApp.token(in: Data("not json".utf8)) == nil)
    }

    /// The check hands over 螺壳's answer only when it passed.
    @Test func checkGivesTheAnswerOnlyWhenItPasses() throws {
        let main = "/Applications/螺壳.app/Contents/MacOS/LuokeCore"
        let me = getpid()
        let t = String(repeating: "c3", count: 32)
        for (program, passes) in [(main, true), ("/tmp/x.app/Contents/MacOS/LuokeCore", false)] {
            var fds: [Int32] = [-1, -1]
            #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
            fds.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }     // tests running alongside start processes too
            let body = fds[1]
            // The other end is closed only after the thread that reads it is done, so its number can't be reused under it.
            let done = DispatchSemaphore(value: 0)
            defer { done.wait(); close(fds[0]); close(body) }
            Thread {
                defer { done.signal() }
                if let line = FromApp.readLine(body, wait: passes ? 5 : 0.5),
                   let id = ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any])?["id"] as? String {
                    _ = FromApp.writeLine(body, Data(#"{"id":"\#(id)","result":{"status":"ok","token":"\#(t)"}}"#.utf8))
                }
            }.start()
            var answer: Data?
            let why = FromApp.check(descriptor: fds[0], parent: { me }, path: { $0 == me ? program : nil },
                                    allowed: [main], signed: { _ in nil }, wait: 5, answer: { answer = $0 })
            #expect((why == nil) == passes)
            #expect(answer.flatMap(FromApp.token(in:)) == (passes ? t : nil))
        }
    }
}
