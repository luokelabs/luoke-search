import Foundation
import Testing
@testable import LuokeSearchKit

/// Records what would have been opened, instead of opening it.
final class Opened: @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    var log: [String] { lock.withLock { _log } }
    /// What the recorded reveal answers: false is Finder not showing it.
    var revealWorks = true

    var opener: Opener {
        Opener(open: { [self] path, _, location in
                   lock.withLock { _log.append("open \((path as NSString).lastPathComponent) \(location?.page ?? -1)") }
               },
               reveal: { [self] path in
                   lock.withLock { _log.append("reveal \((path as NSString).lastPathComponent)") }
                   return revealWorks
               },
               openURL: { [self] url in lock.withLock { _log.append("url \(url.absoluteString)") } })
    }
}

/// The library, its service and MCP server, as the agent sees them.
final class Agent {
    let library: Library
    let opened = Opened()
    let service: SearchService
    let server: MCPServer
    var ids = 0

    init(photos: PhotoSource? = nil) throws {
        library = try Library()
        _ = try library.index()
        service = try SearchService(directory: DataDirectory(url: library.scratch.url.appendingPathComponent("data")),
                                    hub: nil, opener: opened.opener, photos: photos, home: library.scratch.path)
        service.judgesAccess = true   // the resident's socket
        service.folderAccess = FolderAccess(patience: 30)   // a busy test run: the answer, not a timeout
        server = AgentTools.server(service)
    }

    var directory: DataDirectory { service.directory }

    func request(_ method: String, _ params: [String: Any] = [:], meta: [String: Any] = [:]) -> [String: Any] {
        ids += 1
        var params = params
        params["_meta"] = ["io.modelcontextprotocol/protocolVersion": "2026-07-28"].merging(meta) { $1 }
        return server.handle(["jsonrpc": "2.0", "id": ids, "method": method, "params": params]) ?? [:]
    }

    /// `tools/call`'s result.
    func call(_ name: String, _ arguments: [String: Any] = [:], tapped surface: String? = nil) -> [String: Any] {
        let meta: [String: Any] = surface.map {
            ["ai.luoke/user-action": ["surfaceId": $0, "componentId": "b1", "at": "2026-10-20T10:00:00+08:00"]]
        } ?? [:]
        return request("tools/call", ["name": name, "arguments": arguments], meta: meta)["result"] as? [String: Any] ?? [:]
    }
}

extension ReadsPictures {
    struct AgentTests {
        @Test func discoverAndTheToolList() throws {
            let agent = try Agent()
            let discover = try #require(agent.request("server/discover")["result"] as? [String: Any])
            #expect(discover["supportedVersions"] as? [String] == ["2026-07-28"])
            #expect((discover["capabilities"] as? [String: Any])?.keys.sorted() == ["resources", "tools"])
            let tools = try #require((agent.request("tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
            #expect(tools.map { $0["name"] as? String } == ["search_query", "search_similar", "search_open", "search_status",
                                                            "search_settings",
                                                            "search_settings_apply", "search_open_system_settings",
                                                            "outbox_ack"])
            let open = try #require(tools.first { $0["name"] as? String == "search_open" })
            #expect((open["_meta"] as? [String: String])?["ai.luoke/where"] == "mac")
            // What needs a tap is exactly what the manifest's actions list (§5).
            let actions = Set((AgentTools.manifestCapabilities["actions"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
            #expect(actions == ["search_settings_apply", "search_open"])
            for tool in tools {
                let writes = actions.contains(tool["name"] as? String ?? "")
                #expect((tool["annotations"] as? [String: Bool])?["readOnlyHint"] == !writes)
            }
        }

        @Test func protocolEdges() throws {
            let agent = try Agent()
            #expect(agent.server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
            #expect((agent.request("nothing/here")["error"] as? [String: Any])?["code"] as? Int == -32601)
            let old = agent.server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list",
                                           "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2020-01-01"]]])
            #expect((old?["error"] as? [String: Any])?["code"] as? Int == -32602)
            let classic = try #require(agent.server.handle(["jsonrpc": "2.0", "id": 2, "method": "initialize",
                                                            "params": ["protocolVersion": "2025-06-18"]])?["result"]
                                       as? [String: Any])
            #expect(classic["protocolVersion"] as? String == MCPServer.protocolVersion)   // only the one spoken here
            #expect(agent.server.handle(json: Data("not json".utf8)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["error"] != nil)
        }

        @Test func searchGivesHitsAndANewCard() throws {
            let agent = try Agent()
            let result = agent.call("search_query", ["query": "团队版怎么收费"])
            #expect(result["isError"] as? Bool == false)
            let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            #expect(text.contains("发布会.pptx"))
            let structured = try #require(result["structuredContent"] as? [String: Any])
            let hits = try #require(structured["hits"] as? [[String: Any]])
            #expect(hits.first?["title"] as? String == "发布会.pptx")
            #expect((hits.first?["where"] as? [String: Int])?["page"] == 2)
            #expect(structured.keys.contains("partial_reason") && structured.keys.contains("confident"))
            let card = try #require(structured["card"] as? [[String: Any]])
            let create = try #require(card.first?["createSurface"] as? [String: String])
            #expect(create["catalogId"] == "ai.luoke/a2ui/agent/1")
            let again = agent.call("search_query", ["query": "团队版"])
            let second = ((again["structuredContent"] as? [String: Any])?["card"] as? [[String: Any]])?
                .first?["createSurface"] as? [String: String]
            #expect(second?["surfaceId"] != create["surfaceId"])   // a new card each time
        }

        @Test func searchFilters() throws {
            let agent = try Agent()
            let none = agent.call("search_query", ["query": "押金", "kinds": ["pdf"]])
            #expect(((none["structuredContent"] as? [String: Any])?["hits"] as? [Any])?.isEmpty == true)
            let later = agent.call("search_query", ["query": "押金", "since": "2099-01-01"])
            #expect(((later["structuredContent"] as? [String: Any])?["hits"] as? [Any])?.isEmpty == true)
            let bad = agent.call("search_query", ["query": "押金", "since": "去年"])
            #expect(bad["isError"] as? Bool == true)
            #expect(agent.call("search_query", [:])["isError"] as? Bool == true)   // query is required
        }

        @Test func openAndReveal() throws {
            let agent = try Agent()
            let hits = try #require((agent.call("search_query", ["query": "团队版"])["structuredContent"]
                                     as? [String: Any])?["hits"] as? [[String: Any]])
            let id = try #require(hits.first?["id"] as? String)
            // Not without the user's tap: the default app may go online (luoke-audit#25 §8).
            let untapped = agent.call("search_open", ["id": id])
            #expect((untapped["structuredContent"] as? [String: Any])?["code"] as? String == "needs_user_action")
            #expect(agent.opened.log.isEmpty)
            let opened = agent.call("search_open", ["id": id], tapped: "q-1")
            #expect(((opened["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("第 2 页") == true)
            _ = agent.call("search_open", ["id": id, "reveal": true], tapped: "q-1")
            #expect(agent.opened.log == ["open 发布会.pptx 2", "reveal 发布会.pptx"])
            let gone = agent.call("search_open", ["id": "999999"], tapped: "q-1")
            #expect((gone["structuredContent"] as? [String: Any])?["code"] as? String == "stale")
        }

        /// Finder not showing it is said, not covered by "已在访达中显示" (luoke-search#99).
        @Test func revealThatDidntHappenSaysSo() throws {
            let agent = try Agent()
            let hits = try #require((agent.call("search_query", ["query": "团队版"])["structuredContent"]
                                     as? [String: Any])?["hits"] as? [[String: Any]])
            let id = try #require(hits.first?["id"] as? String)
            agent.opened.revealWorks = false
            let answer = agent.call("search_open", ["id": id, "reveal": true], tapped: "q-1")
            #expect(answer["isError"] as? Bool == true)
            #expect((answer["structuredContent"] as? [String: Any])?["code"] as? String == "failed")
            let text = (answer["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            #expect(text.contains("没能在访达中显示"), "\(text)")
            #expect(!text.contains("已在访达中显示"), "\(text)")
        }

        @Test func settingsChangeOnlyWithATapOnTheToolsOwnPlan() throws {
            let agent = try Agent()
            let notes = agent.library.root + "/notes"
            let proposed = agent.call("search_settings", ["change": ["add_folders": [notes]]])
            let structured = try #require(proposed["structuredContent"] as? [String: Any])
            let plan = try #require(structured["plan_id"] as? String)
            #expect((structured["changes"] as? [String])?.first?.hasPrefix("搜「notes」：") == true)
            #expect((structured["changes"] as? [String])?.first?.contains("个文件") == true)
            // On the card: the folder by its name, its full path in the small print.
            let texts = Self.texts(structured["card"])
            #expect(texts.contains { $0.text.hasPrefix("搜「notes」") && $0.variant == nil })
            #expect(texts.contains { $0.text == notes && $0.variant == "caption" })
            #expect(Settings.load(agent.directory).folders.isEmpty)
            // Without the user's tap: refused.
            let untapped = agent.call("search_settings_apply", ["plan_id": plan])
            #expect((untapped["structuredContent"] as? [String: Any])?["code"] as? String == "needs_user_action")
            // A plan it never made: stale.
            let forged = agent.call("search_settings_apply", ["plan_id": "plan-forged"], tapped: "s-plan-forged")
            #expect((forged["structuredContent"] as? [String: Any])?["code"] as? String == "stale")
            // A tap on another card is no say-so for this plan (review C-16).
            let elsewhere = agent.call("search_settings_apply", ["plan_id": plan], tapped: "s-x")
            #expect((elsewhere["structuredContent"] as? [String: Any])?["code"] as? String == "needs_user_action")
            // Tapped, even after a restart (plans are kept in the data directory).
            let restarted = AgentTools.server(try SearchService(directory: agent.directory, hub: nil,
                                                               opener: agent.opened.opener, home: agent.library.scratch.path))
            let tapped = restarted.handle(["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": [
                "name": "search_settings_apply", "arguments": ["plan_id": plan],
                "_meta": ["ai.luoke/user-action": ["surfaceId": "s-\(plan)", "componentId": "b1", "at": "now"]],
            ]])
            let result = try #require(tapped?["result"] as? [String: Any])
            #expect((result["structuredContent"] as? [String: Any])?["done"] as? Bool == true)
            let card = (result["structuredContent"] as? [String: Any])?["card"] as? [[String: Any]]
            #expect((card?.first?["updateComponents"] as? [String: Any])?["surfaceId"] as? String == "s-\(plan)")
            #expect(Settings.load(agent.directory).folders == [notes])
            // The same plan again: it's gone.
            let twice = agent.call("search_settings_apply", ["plan_id": plan], tapped: "s-\(plan)")
            #expect((twice["structuredContent"] as? [String: Any])?["code"] as? String == "stale")
        }

        @Test func aFolderMacOSWontLetUsReadNeedsTheUser() throws {
            let agent = try Agent()
            let locked = agent.library.scratch.path + "/locked"
            try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
            chmod(locked, 0o000)
            defer { chmod(locked, 0o755) }
            let plan = try #require((agent.call("search_settings", ["change": ["add_folders": [locked]]])["structuredContent"]
                                     as? [String: Any])?["plan_id"] as? String)
            let applied = agent.call("search_settings_apply", ["plan_id": plan], tapped: "s-\(plan)")
            let structured = try #require(applied["structuredContent"] as? [String: Any])
            #expect(structured["code"] as? String == "needs_setup")
            // The plan's card drawn again in place: what to allow first, the way there, and its [好] (review C-13).
            let texts = ReviewCardTexts.texts(structured["card"])
            #expect(texts.contains { $0.text.contains("在系统设置里允许以后") })
            let card = String(decoding: try JSONSerialization.data(withJSONObject: structured["card"] ?? []), as: UTF8.self)
            #expect(card.contains("search_settings_apply") && card.contains("search_open_system_settings"))
            #expect(card.contains("updateComponents") && !card.contains("createSurface"))
            // Once it's in the settings anyway (the user typed it), the outbox says what to do.
            var settings = Settings()
            settings.folders = [locked]
            try settings.save(agent.directory)
            let outbox = try #require(agent.service.outbox()["items"] as? [[String: Any]])
            #expect(outbox.map { $0["kind"] as? String } == ["needs-access"])
            let number = try #require(ToolState.load(agent.directory).folderItems[locked])
            #expect(outbox.first?["id"] as? String == SearchService.folderID(locked, number))
            #expect(SetupHome.surfaceID(outbox.first?["card"]) == SearchService.folderSurface(locked, number))
            #expect((outbox.first?["title"] as? String)?.contains("locked") == true)
            // A folder is chosen in the settings, not a permission of the manifest's (§1a).
            #expect(outbox.first?["urgency"] as? String == "low" && outbox.first?["permission"] == nil)
            _ = agent.call("outbox_ack", ["id": outbox.first?["id"] as? String ?? "", "state": "dismissed"])
            #expect((agent.service.outbox()["items"] as? [Any])?.isEmpty == true)
        }

        /// macOS's prompt for a folder waits for the user, and the outbox is read with the tool server's lock held: it
        /// answers without waiting, a folder's card stays as it was, and the answer counts once it comes.
        @Test func aPromptNobodyAnsweredDoesNotStopTheOutbox() throws {
            let agent = try Agent()
            let waiting = agent.library.scratch.path + "/waiting"
            let noted = agent.library.scratch.path + "/noted"
            for folder in [waiting, noted] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
            var settings = Settings()
            settings.folders = [waiting, noted]
            try settings.save(agent.directory)
            try ToolState.update(agent.directory) { $0.folderItems[noted] = 7 }
            let answer = DispatchSemaphore(value: 0)
            agent.service.folderAccess = FolderAccess(patience: 0.05) { folder in
                answer.wait()
                answer.signal()      // answered: for every folder, from now on
                return folder != waiting
            }
            func ids() -> [String] { (agent.service.outbox()["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
            let started = Date()
            #expect(ids() == [SearchService.folderID(noted, 7)])
            #expect(ids() == [SearchService.folderID(noted, 7)])
            #expect(Date().timeIntervalSince(started) < 2)
            answer.signal()
            _ = ids()
            let number = try #require(ToolState.load(agent.directory).folderItems[waiting])
            #expect(ids() == [SearchService.folderID(waiting, number)])
        }

        /// Each time a folder needs the user again (it could be read for a while, or was taken out of the settings and
        /// chosen again), a new item, as for Photos: the agent never shows an id again once it's gone (withdrawn), so the
        /// user was never told again. On a card of its own: the agent keys cards by surface.
        @Test func aNewItemEachTimeAFolderNeedsTheUserAgain() throws {
            let agent = try Agent()
            let locked = agent.library.scratch.path + "/locked"
            try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
            defer { chmod(locked, 0o755) }
            func items() -> [[String: Any]] { agent.service.outbox()["items"] as? [[String: Any]] ?? [] }
            func ids() -> [String] { items().compactMap { $0["id"] as? String } }
            var settings = Settings()
            settings.folders = [locked]
            try settings.save(agent.directory)
            #expect(ids().isEmpty)   // readable: nothing to tell
            let before = Int(Date().timeIntervalSince1970)
            chmod(locked, 0o000)
            let first = try #require(items().first)
            let firstID = try #require(first["id"] as? String)
            #expect(ids() == [firstID])   // the same while it can't be read
            // Numbered by the time, as the Photos item: a state file lost doesn't bring back an id the agent holds.
            let number = try #require(ToolState.load(agent.directory).folderItems[locked])
            #expect(number >= before && firstID == SearchService.folderID(locked, number))
            // Readable again: withdrawn. Taken back: a new item, on a new card.
            chmod(locked, 0o755)
            #expect(ids().isEmpty)
            chmod(locked, 0o000)
            let second = try #require(items().first)
            #expect(second["id"] as? String != firstID)
            #expect(SetupHome.surfaceID(second["card"]) != SetupHome.surfaceID(first["card"]))
            // Taken out of the settings and chosen again: a new item.
            settings.folders = []
            try settings.save(agent.directory)
            #expect(ids().isEmpty)
            settings.folders = [locked]
            try settings.save(agent.directory)
            let third = try #require(ids().first)
            #expect(third != second["id"] as? String && third != firstID)
            // Taken out by a plan and put back by hand (a plan won't add a folder it can't read), the outbox not looked
            // at in between: a new item too.
            var change = SearchService.Change()
            change.removeFolders = [locked]
            _ = try agent.service.apply(planID: try agent.service.plan(change).0.id, surfaceID: nil)
            try settings.save(agent.directory)
            let fourth = try #require(ids().first)
            #expect(fourth != third)
            // Only the latest is kept: an earlier one isn't the outbox's any more.
            #expect(WindowTests.code(agent.call("outbox_ack", ["id": firstID, "state": "dismissed"])) == "invalid")
            _ = agent.call("outbox_ack", ["id": fourth, "state": "dismissed"])
            #expect(ToolState.load(agent.directory).closed == [fourth])
        }

        /// Only the resident judges what macOS lets it read (third review of PR #44): the command line (`settings`, `mcp`
        /// in a terminal) has the terminal's access, often Full Disk Access. Changing the settings or reading the outbox
        /// there keeps the items, and their numbers, as they are.
        @Test func onlyTheResidentRenumbersAFolder() throws {
            let agent = try Agent()
            let locked = agent.library.scratch.path + "/locked"
            try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
            chmod(locked, 0o000)
            defer { chmod(locked, 0o755) }
            var settings = Settings()
            settings.folders = [locked]
            try settings.save(agent.directory)
            func ids(_ service: SearchService) -> [String] {
                (service.outbox()["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            }
            let id = try #require(ids(agent.service).first)
            let noted = ToolState.load(agent.directory).folderItems
            // Another process on the same data directory, as the command line makes it (no library, no judging).
            let terminal = try SearchService(directory: agent.directory, hub: nil, opener: .dry, home: agent.library.scratch.path)
            var change = SearchService.Change()
            change.onBattery = true
            _ = try terminal.apply(planID: try terminal.plan(change).0.id, surfaceID: nil)
            #expect(ToolState.load(agent.directory).folderItems == noted)
            // The terminal can read the folder: it still reports the resident's item, and notes nothing.
            chmod(locked, 0o755)
            #expect(ids(terminal) == [id])
            #expect(ToolState.load(agent.directory).folderItems == noted)
            // The resident, still not let in, sees the same item.
            chmod(locked, 0o000)
            #expect(ids(agent.service) == [id])
        }

        @Test func firstPassReportAndStatus() throws {
            let agent = try Agent()
            var settings = Settings()
            settings.folders = [agent.library.root]
            try settings.save(agent.directory)
            try agent.service.noteFirstPassIfDone()
            let read = try #require(agent.request("resources/read", ["uri": AgentTools.outboxURI])["result"] as? [String: Any])
            let text = try #require((read["contents"] as? [[String: Any]])?.first?["text"] as? String)
            let items = try #require((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["items"]
                                     as? [[String: Any]])
            #expect(items.map { $0["kind"] as? String } == ["index-ready"])
            #expect(items.first?["urgency"] as? String == "low")
            #expect(items.first?["expires"] is String)
            let status = try #require(agent.call("search_status")["structuredContent"] as? [String: Any])
            #expect((status["items"] as? [String: Int])?["doc"] == 5)
            #expect(status["first_pass_done"] as? Bool == true)
            #expect((status["hub"] as? [String: Any])?["state"] as? String == "not_connected")
        }

        @Test func aDryRunSaysSo() throws {
            let agent = try Agent()
            let hits = try #require((agent.call("search_query", ["query": "团队版"])["structuredContent"]
                                     as? [String: Any])?["hits"] as? [[String: Any]])
            let id = try #require(hits.first?["id"] as? String)
            let dry = try SearchService(directory: agent.directory, hub: nil, opener: .dry, home: agent.library.scratch.path)
            #expect(try dry.open(id, reveal: false) == "已打开 发布会.pptx，要找的在第 2 页。（演习）")
            #expect(try dry.open(id, reveal: true).hasSuffix("（演习）"))
            #expect(try agent.service.open(id, reveal: false).hasSuffix("页。"))   // the real one doesn't
        }

        /// Every Text component in a card's messages: its text and variant.
        static func texts(_ card: Any?) -> [(text: String, variant: String?)] {
            if let component = card as? [String: Any] {
                if component["component"] as? String == "Text", let text = component["text"] as? String {
                    return [(text, component["variant"] as? String)]
                }
                return component.values.flatMap { texts($0) }
            }
            return (card as? [Any])?.flatMap { texts($0) } ?? []
        }

        @Test func systemSettingsOpenAtThePrivacyPane() throws {
            let agent = try Agent()
            _ = agent.call("search_open_system_settings", ["pane": "photos"])
            #expect(agent.opened.log == ["url x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"])
        }
    }
}

struct AgentSocketTests {
    @Test func answersOnItsSocketAndCleansUp() throws {
        let path = "/tmp/lsag-\(UUID().uuidString.prefix(8)).sock"
        let server = MCPServer(name: "t", version: "0")
        let socket = AgentSocket(path: path, server: server)
        try socket.start()
        var info = stat()
        lstat(path, &info)
        #expect(info.st_mode & 0o777 == 0o600)
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{}}"#.utf8)
        let answer = try UnixHTTP.request(socket: path, method: "POST", target: "/mcp", body: body, timeout: 5)
        #expect(answer.status == 200)
        #expect(String(decoding: answer.body, as: UTF8.self).contains("2026-07-28"))
        #expect(try UnixHTTP.request(socket: path, method: "GET", target: "/mcp", timeout: 5).status == 405)
        #expect(try UnixHTTP.request(socket: path, method: "POST", target: "/other", body: body, timeout: 5).status == 404)
        let note = Data(#"{"jsonrpc":"2.0","method":"notifications/x"}"#.utf8)
        #expect(try UnixHTTP.request(socket: path, method: "POST", target: "/mcp", body: note, timeout: 5).status == 202)
        // A second server on the same socket is refused while the first answers.
        #expect(throws: AgentSocket.Failure.self) { try AgentSocket(path: path, server: server).start() }
        socket.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func aSocketLeftBehindIsReplaced() throws {
        let path = "/tmp/lsag-\(UUID().uuidString.prefix(8)).sock"
        // A socket file nobody listens on any more, as a crashed process leaves it.
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8))
            raw[path.utf8.count] = 0
        }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        #expect(FileManager.default.fileExists(atPath: path))
        let socket = AgentSocket(path: path, server: MCPServer(name: "t", version: "0"))
        try socket.start()
        let answer = try UnixHTTP.request(socket: path, method: "POST", target: "/mcp",
                                          body: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8), timeout: 5)
        #expect(answer.status == 200)
        socket.stop()
    }
}
