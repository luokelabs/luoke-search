import Foundation
import Testing
@testable import LuokeSearchKit

// The pre-release security review (10-23), should-fix 10 and 11. A client that never read its answer held its
// connection: 32 of them, with unknown method names of 900 KB echoed back, and every new request got 503 for as long
// as they liked. The tools that need no tap let anyone grow `state.json` without end: a plan kept for each
// `search_settings`, any list of any folders, any text at all kept by `outbox_ack`, word for word.
struct ReleaseReviewLimitsTests {
    static func call(_ server: MCPServer, _ method: String, _ params: [String: Any] = [:], id: Any = 1) -> [String: Any] {
        server.handle(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) ?? [:]
    }

    static func change(add: [String] = [], remove: [String] = [], skip: [String] = []) -> SearchService.Change {
        var change = SearchService.Change()
        change.addFolders = add
        change.removeFolders = remove
        change.skipFolders = skip
        return change
    }

    static func message(_ answer: [String: Any]) -> String {
        (answer["error"] as? [String: Any])?["message"] as? String ?? ""
    }

    @Test("Should-fix 10: a client that never reads its answer is let go at the deadline; others get in again")
    func unreadAnswer() throws {
        let server = MCPServer(name: "t", version: "0")
        let big = String(repeating: "长", count: 2_000_000)   // 6 MB: more than the socket holds
        server.add(MCPServer.Tool(name: "big", title: "big", description: "", schema: ["type": "object"]) { _, _ in
            (big, [:])
        })
        let path = "/tmp/lsag-\(UUID().uuidString.prefix(8)).sock"
        let socket = AgentSocket(path: path, server: server)
        socket.maxConnections = 1
        socket.answerDeadline = 1
        try socket.start()
        defer { socket.stop() }
        let fd = rawConnect(path)
        defer { close(fd) }
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"big"}}"#.utf8)
        var request = Data("POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        request.append(body)
        _ = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        // Held while its answer waits to be taken…
        Thread.sleep(forTimeInterval: 0.3)
        let ping = ReleaseReviewSocketTests.ping
        #expect((try? UnixHTTP.request(socket: path, method: "POST", target: "/mcp", body: ping, timeout: 2).status) == 503)
        // …and let go once the deadline is past, though the client is still there, not reading.
        #expect(ReleaseReviewSocketTests.answers(path))
    }

    @Test("Should-fix 10: a client reading slowly but steadily gets the whole answer within the deadline")
    func slowReader() throws {
        let server = MCPServer(name: "t", version: "0")
        let big = String(repeating: "长", count: 2_000_000)
        server.add(MCPServer.Tool(name: "big", title: "big", description: "", schema: ["type": "object"]) { _, _ in
            (big, [:])
        })
        let path = "/tmp/lsag-\(UUID().uuidString.prefix(8)).sock"
        let socket = AgentSocket(path: path, server: server)
        socket.answerDeadline = 10
        try socket.start()
        defer { socket.stop() }
        let fd = rawConnect(path)
        defer { close(fd) }
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"big"}}"#.utf8)
        var request = Data("POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        request.append(body)
        _ = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        var got = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            got.append(buffer, count: count)
            Thread.sleep(forTimeInterval: 0.005)
        }
        let end = try #require(got.firstRange(of: Data("\r\n\r\n".utf8)))
        let answer = try JSONSerialization.jsonObject(with: got[end.upperBound...]) as? [String: Any]
        let content = ((answer?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(content == big)
    }

    @Test("Should-fix 10: a socket's wait is never 0 (no limit at all) and at most 10 s")
    func waits() {
        for left in [-1, 0, 0.000_000_1, 0.000_9] {
            let wait = AgentSocket.timeout(left)
            #expect(wait.tv_sec == 0 && wait.tv_usec == 1000)
        }
        #expect(AgentSocket.timeout(2.5).tv_sec == 2 && AgentSocket.timeout(2.5).tv_usec == 500_000)
        #expect(AgentSocket.timeout(25).tv_sec == 10 && AgentSocket.timeout(25).tv_usec == 0)
    }

    @Test("Should-fix 10: names a request gives come back cut to 100 characters; an id that long isn't taken")
    func echoesCut() throws {
        let server = MCPServer(name: "t", version: "0")
        let long = String(repeating: "长", count: 300_000)
        // One letter with 300 000 accents on it is one character: cut by code points (review of this change).
        let accents = "a" + String(repeating: "\u{0301}", count: 300_000)
        for answer in [Self.call(server, long), Self.call(server, "tools/call", ["name": long]), Self.call(server, accents)] {
            let message = Self.message(answer)
            #expect(message.utf8.count < 500 && message.hasSuffix("…"))
            #expect((MCPServer.encode(answer)?.count ?? .max) < 1000)
        }
        // A request that isn't JSON-RPC 2.0 doesn't have its id echoed unchecked either.
        for id in [long as Any, [String](repeating: "x", count: 50_000) as Any] {
            let answer = MCPServer(name: "t", version: "0").handle(["jsonrpc": "1.0", "id": id])
            #expect(answer?["id"] is NSNull)
            #expect((MCPServer.encode(answer ?? [:])?.count ?? .max) < 1000)
        }
        #expect(server.handle(["jsonrpc": "1.0", "id": 7])?["id"] as? Int == 7)
        let resource = Self.call(server, "resources/read", ["uri": long])
        let data = (resource["error"] as? [String: Any])?["data"] as? [String: Any]
        #expect((data?["uri"] as? String)?.count == MCPServer.maxShown + 1)
        // Short ones whole, as before.
        #expect(Self.message(Self.call(server, "nope")) == "没有这个方法：nope")
        // The id is repeated whole (JSON-RPC), so a string id is at most 256 long.
        let taken = Self.call(server, "ping", id: String(repeating: "i", count: 256))
        #expect(taken["result"] != nil)
        let refused = Self.call(server, "ping", id: String(repeating: "i", count: 257))
        #expect((refused["error"] as? [String: Any])?["code"] as? Int == -32600 && refused["id"] is NSNull)
        // A date it can't read.
        #expect(throws: ToolFailure.self) { try AgentTools.date(long, endOfDay: false) }
        do {
            _ = try AgentTools.date(long, endOfDay: false)
        } catch let failure as ToolFailure {
            #expect(failure.message.utf8.count < 500)
        }
    }

    @Test("Should-fix 11: search_settings keeps at most 20 plans not carried out, the newest; the setup card's stays")
    func plansKept() throws {
        let setup = try SetupHome()
        let offered = try setup.planID(setup.setup)
        var made: [String] = []
        for _ in 0..<30 {
            let (plan, _) = try setup.service.plan(Self.change(add: ["desktop"]))
            made.append(plan.id)
        }
        let plans = ToolState.load(setup.directory).plans
        #expect(plans.filter { $0.choices == nil }.map(\.id) == Array(made.suffix(SearchService.maxPlans)))
        #expect(plans.contains { $0.id == offered })
        // The newest still carried out with a tap; one of the oldest is gone.
        #expect(SetupHome.code(setup.tap(made[0])) == "stale")
        #expect((setup.tap(made[29])["structuredContent"] as? [String: Any])?["done"] as? Bool == true)
    }

    @Test("Should-fix 11: a change names at most 50 folders, each at most 1024 bytes")
    func changeLimits() throws {
        let setup = try SetupHome()
        let many = (0...SearchService.maxFoldersInChange).map { "~/Desktop/\($0)" }
        for change in [Self.change(add: many), Self.change(remove: many), Self.change(skip: many)] {
            #expect(throws: ToolFailure.self) { try setup.service.plan(change) }
        }
        let long = "~/Desktop/" + String(repeating: "长", count: 400)
        do {
            _ = try setup.service.plan(Self.change(skip: [long]))
            Issue.record("a folder of 1210 bytes was taken")
        } catch let failure as ToolFailure {
            #expect(failure.code == "invalid" && failure.message.utf8.count < 500)
        }
        #expect(ToolState.load(setup.directory).plans.allSatisfy { $0.choices != nil })   // nothing kept
        // 50 is fine.
        let fifty = Array(many.prefix(SearchService.maxFoldersInChange))
        _ = try setup.service.plan(Self.change(add: ["desktop"], skip: fifty))
    }

    @Test("Should-fix 11: outbox_ack keeps only an id the outbox could hold; others are refused, old ones let go")
    func acksKept() throws {
        let setup = try SetupHome()
        let secret = "密码是 AckPw99"
        #expect(throws: ToolFailure.self) { try setup.service.acknowledge(secret, state: "dismissed") }
        #expect(throws: ToolFailure.self) {
            try setup.service.acknowledge(SearchService.folderID(setup.home + "/Desktop", 1), state: "answered")
        }
        let text = (try? String(contentsOf: setup.directory.stateFile, encoding: .utf8)) ?? ""
        #expect(!text.contains("AckPw99"))
        #expect(ToolState.load(setup.directory).closed.isEmpty)
        // Through MCP, as the agent sends it: a tool error, nothing kept.
        let answer = Self.call(setup.server, "tools/call", ["name": "outbox_ack", "arguments": ["id": secret, "state": "dismissed"]])
        let result = answer["result"] as? [String: Any] ?? [:]
        #expect(result["isError"] as? Bool == true && SetupHome.code(result) == "invalid")
        // What's in the outbox is kept as before; what a bloated file from before held is let go.
        var state = ToolState.load(setup.directory)
        // Photos: only the latest item (review of PR #42).
        state.photosItem = 3
        state.closed = (0..<1000).map { "垃圾-\($0)" } + ["needs-access/photos/2", "needs-access/photos/3"]
        try state.save(setup.directory)
        try setup.service.acknowledge("needs-setup", state: "dismissed")
        #expect(ToolState.load(setup.directory).closed == ["needs-access/photos/3", "needs-setup"])
        #expect(setup.setup == nil)
        // A searched folder's needs-access, while macOS won't let it be read (its latest item only), and the first
        // pass's index-ready.
        _ = try ShippedSettingsTests.run(["--add-folder", "documents"], setup)
        #expect(setup.items.isEmpty)   // readable: nothing to answer
        chmod(setup.home + "/Documents", 0o000)
        defer { chmod(setup.home + "/Documents", 0o755) }
        let documents = try #require(setup.items.first?["id"] as? String)
        #expect(documents.hasPrefix("needs-access/" + setup.home + "/Documents/"))
        #expect(throws: ToolFailure.self) {
            try setup.service.acknowledge(SearchService.folderID(setup.home + "/Documents", 1), state: "answered")
        }
        try setup.service.acknowledge(documents, state: "answered")
        #expect(ToolState.load(setup.directory).closed.contains(documents))
        // "shown" of an id it couldn't hold is refused too; of one it could, nothing to keep.
        #expect(throws: ToolFailure.self) { try setup.service.acknowledge(secret, state: "shown") }
        try setup.service.acknowledge("needs-access/photos/3", state: "shown")
        // The first pass's index-ready: its own time only.
        var done = ToolState.load(setup.directory)
        done.firstPassDone = 1_793_000_000
        try done.save(setup.directory)
        #expect(throws: ToolFailure.self) { try setup.service.acknowledge("index-ready/1", state: "dismissed") }
        try setup.service.acknowledge("index-ready/1793000000", state: "dismissed")
        #expect(ToolState.load(setup.directory).closed.contains("index-ready/1793000000"))
        // Settings that can't be read (a newer version's, edited by hand) aren't "no folders": nothing is let go.
        try Data("{ not json".utf8).write(to: setup.directory.settingsFile)
        try setup.service.acknowledge("needs-access/photos/3", state: "dismissed")
        #expect(ToolState.load(setup.directory).closed.contains(documents))
    }

    @Test("Should-fix 11: a folder's item number is kept only while it's searched and can't be read; old ones let go")
    func folderItemsKept() throws {
        let setup = try SetupHome()
        _ = try ShippedSettingsTests.run(["--add-folder", "documents"], setup)
        let documents = setup.home + "/Documents"
        chmod(documents, 0o000)
        defer { chmod(documents, 0o755) }
        // What a bloated file from before held is let go at the next look; the folder still needing the user keeps its
        // number.
        var state = ToolState.load(setup.directory)
        state.folderItems = Dictionary(uniqueKeysWithValues: (0..<1000).map { ("/垃圾/\($0)", $0) })
        state.folderItems[documents] = 7
        // The last number given, ahead of the clock (set back since): the next is still one more.
        let last = Int(Date().timeIntervalSince1970) + 1_000_000
        state.folderItem = last
        try state.save(setup.directory)
        #expect(setup.items.map { $0["id"] as? String } == [SearchService.folderID(documents, 7)])
        #expect(ToolState.load(setup.directory).folderItems == [documents: 7])
        // Taken out (by the command line, which judges no folder): let go. Chosen again (a plan adds only a folder it
        // can read), then not readable: a number never given before.
        _ = try ShippedSettingsTests.run(["--remove-folder", "documents"], setup)
        #expect(ToolState.load(setup.directory).folderItems.isEmpty)
        chmod(documents, 0o755)
        _ = try ShippedSettingsTests.run(["--add-folder", "documents"], setup)
        #expect(setup.items.isEmpty && ToolState.load(setup.directory).folderItems.isEmpty)
        chmod(documents, 0o000)
        #expect(setup.items.map { $0["id"] as? String } == [SearchService.folderID(documents, last + 1)])
    }
}
