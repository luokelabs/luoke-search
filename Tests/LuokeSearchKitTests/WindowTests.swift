import Foundation
import Testing
@testable import LuokeSearchKit

/// What the window shows besides cards (agent tool protocol §1a, luoke-agent#3): the manifest's `service`,
/// `permissions` and `listing`, the `summary` and `permissions` resources.
extension ReadsPictures {
    struct WindowTests {
        static func code(_ result: [String: Any]) -> String? {
            (result["structuredContent"] as? [String: Any])?["code"] as? String
        }

        static func text(_ result: [String: Any]) -> String {
            (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        }

        /// The surface an outbox item's card is drawn on (what a tap on it carries).
        static func surface(_ item: [String: Any]?) -> String? {
            ((item?["card"] as? [[String: Any]])?.first?["createSurface"] as? [String: Any])?["surfaceId"] as? String
        }

        /// A resource as the agent reads it: by relative id, `contents[0].text` as JSON.
        static func read(_ agent: Agent, _ uri: String) throws -> Any {
            let result = try #require(agent.request("resources/read", ["uri": uri])["result"] as? [String: Any])
            let text = try #require((result["contents"] as? [[String: Any]])?.first?["text"] as? String)
            return try JSONSerialization.jsonObject(with: Data(text.utf8))
        }

        /// The agent's own card checker (`scripts/agent/a2ui.py`, luoke-agent's, unmodified): what's wrong with the
        /// card, and what its buttons send.
        static let agentDraws = """
            import json, sys
            sys.path.insert(0, sys.argv[1])
            import a2ui
            card = json.load(open(sys.argv[2]))
            surface = a2ui.build(card)
            buttons = [c["id"] for c in surface.components.values() if c.get("component") == "Button"]
            print(json.dumps({"problems": a2ui.validate(card),
                              "events": [surface.button_event(button)[0] for button in buttons]}))
            """

        /// Nil where the checker isn't (`agentScripts`).
        static func asTheAgentDrawsIt(_ agent: Agent, _ card: Any) throws -> [String: Any]? {
            guard let scripts = agentScripts else { return nil }
            let file = try agent.library.scratch.write("card.json", data: try JSONSerialization.data(withJSONObject: card))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", "-c", agentDraws, scripts, file.path]
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            let said = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            return try #require(try JSONSerialization.jsonObject(with: said) as? [String: Any])
        }

        /// What the agent's checker makes of the page: its problems and what each button sends.
        static let agentReadsThePage = """
            import json, sys
            sys.path.insert(0, sys.argv[1])
            import a2ui
            page = json.load(open(sys.argv[2]))
            surface = a2ui.build(page)
            buttons = {}
            for c in surface.components.values():
                if c.get("component") == "Button":
                    name, declared = surface.button_event(c["id"])
                    label = surface.components[c["child"]]["text"]
                    buttons[label] = {"name": name, "arguments": a2ui.merge_context(declared, {}, surface.data)}
            print(json.dumps({"problems": a2ui.validate(page), "buttons": buttons}))
            """

        /// Nil where the checker isn't (`agentScripts`).
        static func asTheAgentReadsThePage(_ agent: Agent, _ page: Any) throws -> [String: Any]? {
            guard let scripts = agentScripts else { return nil }
            let file = try agent.library.scratch.write("page.json", data: try JSONSerialization.data(withJSONObject: page))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", "-c", agentReadsThePage, scripts, file.path]
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            let said = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            return try #require(try JSONSerialization.jsonObject(with: said) as? [String: Any])
        }

        static func pageTexts(_ page: Any) -> [String] {
            ((page as? [[String: Any]]) ?? []).flatMap {
                (($0["updateComponents"] as? [String: Any])?["components"] as? [[String: Any]]) ?? []
            }.compactMap { $0["text"] as? String }
        }

        @Test("The page says how far, what's searched and what was read, in numbers: no file's name")
        func thePageTellsNoFileNames() throws {
            let agent = try Agent()
            #expect(try agent.service.store.lastRead() != nil)
            let texts = Self.pageTexts(try Self.read(agent, "page/overview"))
            #expect(texts.contains("还没选") && texts.contains("关"))
            #expect(texts.contains("最近读入") && !texts.contains("还没有"))
            #expect(!texts.contains { $0.contains("合同") || $0.contains("疫苗") || $0.contains("running") })
        }

        @Test("Last read: nothing before anything was read")
        func lastReadIsATime() throws {
            let agent = try Agent()
            #expect(try agent.service.store.lastRead() != nil)
            let scratch = try Scratch()
            #expect(try withExtendedLifetime(scratch) { try $0.store().lastRead() } == nil)
        }

        @Test("Under way, a line holds a bar and the count")
        func theLineWithABar() throws {
            let page = Cards.overview(exact: .progress(1, of: 4), semantic: SearchState("可用"), note: nil, folders: [],
                                      photos: "off", lastRead: nil, changeable: false)
            let components = page.flatMap { (($0["updateComponents"] as? [String: Any])?["components"] as? [[String: Any]]) ?? [] }
            let bar = try #require(components.first { $0["component"] as? String == "ProgressBar" })
            #expect(bar["value"] as? Double == 0.25)
            #expect(Self.pageTexts(page).contains("1 / 4"))
            if let drawn = try Self.asTheAgentReadsThePage(try Agent(), page) {
                #expect((drawn["problems"] as? [Any])?.isEmpty == true)
            }
        }

        @Test("Each line is a name on the left and a value on the right; nothing to add leaves no sentence on top")
        func thePageIsAList() throws {
            let page = Cards.overview(exact: SearchState("可用"), semantic: SearchState("可用"), note: nil, folders: [(name: "资料", id: "a1")], photos: "off", lastRead: nil, changeable: true)
            let components = page.flatMap { (($0["updateComponents"] as? [String: Any])?["components"] as? [[String: Any]]) ?? [] }
            // The two ways of searching, the folders' count, the folder, the photos switch, what was read lately.
            #expect(components.filter { $0["justify"] as? String == "spaceBetween" }.count == 6)
            let toggle = try #require(components.first { $0["variant"] as? String == "switch" })
            #expect(toggle["component"] as? String == "Button" && toggle["on"] as? Bool == false)
            let event = (toggle["action"] as? [String: Any])?["event"] as? [String: Any]
            #expect((event?["context"] as? [String: Any])?["needs"] as? String == "photos", "turning it on needs the permission first")
            #expect(Self.pageTexts(page).prefix(4) == ["精确搜索", "可用", "语义搜索", "可用"])

            let noted = Cards.overview(exact: SearchState("可用"), semantic: SearchState("可用"), note: "在用电池。", folders: [], photos: "off",
                                       lastRead: nil, changeable: false)
            #expect(Self.pageTexts(noted)[4] == "在用电池。")
        }

        @Test("Each way of searching says it's ready, how far it is, or why it can't be used")
        func thePageSaysHowFar() throws {
            let service = try Agent().service
            let ready = service.pageStatus(["items": ["doc": 3], "vectors_ready": 7])
            #expect(ready.exact == SearchState("可用") && ready.semantic == SearchState("可用") && ready.note == nil)
            let going = service.pageStatus(["items": ["doc": 120], "waiting": ["read": 220, "vectors": 30], "vectors_ready": 10])
            #expect(going.exact.text == "120 / 340" && going.exact.progress == 120.0 / 340)
            #expect(going.semantic.text == "10 / 40" && going.semantic.progress == 0.25)
            let noEngine = service.pageStatus(["items": ["doc": 3], "waiting": ["vectors": 7], "hub": ["state": "downloading"]])
            #expect(noEngine.semantic == SearchState("等待下载"))
            #expect(service.pageStatus(["items": ["doc": 3], "hub": ["state": "not_running"]]).semantic.text == "未连接")
            #expect(service.pageStatus(["items": ["doc": 3], "hub": ["state": "available"]]).semantic.text == "可用")
            #expect(service.pageStatus([:]).exact.text == "还没有内容" && service.pageStatus([:]).semantic.text == "还没有内容")

            let held: [String: Any] = ["reasons": ["battery"], "by": "luoke", "reading": true, "vectors": true]
            let note = try #require(service.pageStatus(["paused": held, "waiting": ["not_on_this_mac": 2]]).note)
            #expect(note == "螺壳的后台已暂停（在用电池），等着的文件先不读，新存的文件照样读。2 个文件不在这台 Mac 上，回来后接着读。")
            // The sentence for the agent's model stays as it was.
            #expect(service.statusSentence(["items": ["doc": 3], "waiting": ["vectors": 7]]) == "已索引 3 个，7 段在等螺壳算向量。")
        }

        /// A button on the page by its label: the event it sends and what with.
        static func pageButton(_ page: Any, _ label: String) -> (name: String, context: [String: Any])? {
            let components = ((page as? [[String: Any]]) ?? []).flatMap {
                (($0["updateComponents"] as? [String: Any])?["components"] as? [[String: Any]]) ?? []
            }
            guard let text = components.first(where: { $0["text"] as? String == label })?["id"] as? String,
                  let button = components.first(where: { $0["child"] as? String == text }),
                  let event = (button["action"] as? [String: Any])?["event"] as? [String: Any],
                  let name = event["name"] as? String else { return nil }
            return (name, event["context"] as? [String: Any] ?? [:])
        }

        @Test("Photos chosen, never asked: 允许 is marked for luoke's own window, and asks nothing here")
        func thePageWithPhotosNotAsked() throws {
            let photos = FakePhotos([], access: .notAsked)
            let agent = try Agent(photos: photos)
            try Self.choose(agent, agent.library.root + "/notes")
            #expect(Self.code(agent.call("search_settings_apply", ["photos": true, "needs": "photos"], tapped: "overview")) == nil)
            let page = try Self.read(agent, "page/overview")
            #expect(Self.pageTexts(page).contains("不再搜照片"))
            let allow = try #require(Self.pageButton(page, "允许"))
            #expect(allow.name == "search_open_system_settings" && allow.context["pane"] as? String == "photos")
            #expect(allow.context["permission"] as? String == "photos")
            // Allowed in luoke's window: the next read has only the switch.
            photos.access = .allowed
            let after = Self.pageTexts(try Self.read(agent, "page/overview"))
            #expect(!after.contains("允许") && !after.contains("去系统设置") && after.contains("不再搜照片"))
        }

        @Test("Photos chosen, refused: macOS won't ask again, so the same button says where to allow it")
        func thePageWithPhotosRefused() throws {
            let agent = try Agent(photos: FakePhotos([], access: .denied))
            try Self.choose(agent, agent.library.root + "/notes")
            #expect(Self.code(agent.call("search_settings_apply", ["photos": true], tapped: "overview")) == nil)
            let page = try Self.read(agent, "page/overview")
            #expect(!Self.pageTexts(page).contains("允许"))
            let open = try #require(Self.pageButton(page, "去系统设置"))
            #expect(open.name == "search_open_system_settings" && open.context["pane"] as? String == "photos")
            #expect(open.context["permission"] as? String == "photos")
        }

        @Test("No folders chosen yet, so no switch: photos on and not allowed still say what to do")
        func thePageWithoutTheSwitch() {
            let page = Cards.overview(exact: SearchState("可用"), semantic: SearchState("可用"), note: nil, folders: [],
                                      photos: "needs_access", lastRead: nil, changeable: false)
            #expect(Self.pageButton(page, "允许") != nil)
            #expect(!Self.pageTexts(page).contains("开"))
        }

        /// Chooses a folder as a card's plan would.
        static func choose(_ agent: Agent, _ folder: String) throws {
            var change = SearchService.Change()
            change.addFolders = [folder]
            _ = try agent.service.apply(planID: try agent.service.plan(change).0.id, surfaceID: nil)
        }

        @Test("Folders go by their last part, a credential in one masked: no path")
        func thePageNamesFolders() throws {
            let agent = try Agent()
            try agent.library.scratch.write("files/身份证 110101199003070017 资料/a.txt", "一段话")
            try Self.choose(agent, agent.library.root + "/身份证 110101199003070017 资料")
            try Self.choose(agent, agent.library.root + "/notes")
            let texts = Self.pageTexts(try Self.read(agent, "page/overview"))
            #expect(texts.contains { $0.contains("notes") })
            #expect(!texts.contains { $0.contains("110101199003070017") || $0.contains(agent.library.root) })
        }

        @Test("Nothing chosen yet: no switch, and the setup card stays (the page can't choose folders)")
        func noSwitchBeforeSetup() throws {
            let agent = try Agent()
            #expect(!Self.pageTexts(try Self.read(agent, "page/overview")).contains("也搜照片"))
            #expect(Self.code(agent.call("search_settings_apply", ["photos": true], tapped: "overview")) == "needs_setup")
            #expect(Settings.load(agent.directory).photos == false)
            #expect(ToolState.load(agent.directory).foldersChosen == nil)
        }

        @Test("Settings that can't be read: the page says so, and offers no switch")
        func thePageWithUnreadableSettings() throws {
            let agent = try Agent()
            try agent.directory.prepare()
            try Data("不是 JSON".utf8).write(to: agent.directory.settingsFile)
            let texts = Self.pageTexts(try Self.read(agent, "page/overview"))
            #expect(texts.contains(Settings.unreadable))
            #expect(!texts.contains("也搜照片"))
        }

        @Test("The page's switches: the agent's checker passes them, and only a tap on the page carries them out")
        func theSwitchesNeedATapOnThePage() throws {
            let agent = try Agent()
            try Self.choose(agent, agent.library.root + "/notes")
            if let drawn = try Self.asTheAgentReadsThePage(agent, try Self.read(agent, "page/overview")) {
                #expect((drawn["problems"] as? [Any])?.isEmpty == true)
                let buttons = try #require(drawn["buttons"] as? [String: [String: Any]])
                #expect(buttons["也搜照片"]?["name"] as? String == "search_settings_apply")
                let arguments = buttons["也搜照片"]?["arguments"] as? [String: Any]
                #expect(arguments?["photos"] as? Bool == true && arguments?["needs"] as? String == "photos")
            }
            // Not tapped, or tapped on some card: nothing changes.
            #expect(Self.code(agent.call("search_settings_apply", ["photos": true])) == "needs_user_action")
            #expect(Self.code(agent.call("search_settings_apply", ["photos": true], tapped: "s-plan-x")) == "needs_user_action")
            #expect(Settings.load(agent.directory).photos == false)
            // On the page.
            #expect(Self.code(agent.call("search_settings_apply", ["photos": true], tapped: "overview")) == nil)
            #expect(Settings.load(agent.directory).photos == true)
            let on = Self.pageTexts(try Self.read(agent, "page/overview"))
            #expect(on.contains("不再搜照片"))
            // Tapped twice, before the page was drawn again: nothing more to do, and no plan left behind.
            #expect(Self.code(agent.call("search_settings_apply", ["photos": true], tapped: "overview")) == nil)
            #expect(ToolState.load(agent.directory).plans.isEmpty)
            // And off again.
            #expect(Self.code(agent.call("search_settings_apply", ["photos": false], tapped: "overview")) == nil)
            #expect(Settings.load(agent.directory).photos == false)
            // Neither a plan nor a switch, and not one that says on or off.
            #expect(Self.code(agent.call("search_settings_apply", [:], tapped: "overview")) == "invalid")
            #expect(Self.code(agent.call("search_settings_apply", ["photos": "on"], tapped: "overview")) == "invalid")
        }

        @Test func theManifestSaysWhatTheWindowShows() throws {
            let capabilities = AgentTools.manifestCapabilities
            // A summary, one base page, and what the window's global search calls: no window of its own.
            let service = try #require(capabilities["service"] as? [String: Any])
            #expect(service.keys.sorted() == ["ask", "pages", "summary"] && service["summary"] as? Bool == true)
            #expect(service["pages"] as? [[String: String]] == [["id": "overview", "title": "概览"]])
            let permissions = try #require(capabilities["permissions"] as? [[String: Any]])
            #expect(permissions.map { $0["id"] as? String } == ["photos", "folders", "quicktime"])
            let photos = try #require(permissions.first)
            #expect(photos["kind"] as? String == "system" && photos["tcc"] as? String == "Photos")
            #expect(photos["without"] as? String == "degrade")
            #expect(((photos["facts"] as? [String]) ?? []).isEmpty == false)
            // luoke's, and luoke's own program asks: nothing for the agent to call here.
            #expect(photos["owner"] as? String == "luoke" && photos["request"] == nil)
            let listing = try #require(capabilities["listing"] as? [String: String])
            #expect(listing.keys.sorted() == ["category", "tagline"])
            #expect(listing.values.allSatisfy { !$0.isEmpty })
        }

        @Test func resourcesByRelativeID() throws {
            let agent = try Agent()
            let listed = try #require((agent.request("resources/list")["result"] as? [String: Any])?["resources"]
                                      as? [[String: Any]])
            #expect(Set(listed.compactMap { $0["uri"] as? String })
                    == [AgentTools.outboxURI, "outbox", "summary", "permissions", "page/overview"])
            // The outbox under both ids, the same.
            let relative = try #require(try Self.read(agent, "outbox") as? [String: Any])
            let full = try #require(try Self.read(agent, AgentTools.outboxURI) as? [String: Any])
            #expect(NSDictionary(dictionary: relative).isEqual(to: full))
            let summary = try #require(try Self.read(agent, "summary") as? [String: Any])
            #expect(summary["count"] as? Int == 0 && summary["text"] is String)
            // This process can't read a Photos library at all (no `photos`): denied, not guessed.
            #expect(try Self.read(agent, "permissions") as? [String: String] == ["photos": "denied"])
        }

        @Test func theSummarySaysHowFarAndWhatWaits() throws {
            let agent = try Agent()
            #expect(agent.service.summary()["text"] as? String == "还没选要搜的地方")
            var settings = Settings()
            settings.folders = [agent.library.root]
            try settings.save(agent.directory)
            // Chosen, the first pass not noted yet: never "0 indexed".
            #expect((agent.service.summary()["text"] as? String)?.hasPrefix("正在建索引：已读 ") == true)
            try agent.service.noteFirstPassIfDone()
            let done = agent.service.summary()
            let text = try #require(done["text"] as? String)
            #expect(text.hasPrefix("已索引 ") && text.hasSuffix("个文件"), "\(text)")
            #expect(done["count"] as? Int == 0)   // index-ready only tells
            // A chosen folder macOS won't let it read: one thing waits for the user.
            let locked = agent.library.scratch.path + "/locked"
            try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
            chmod(locked, 0o000)
            defer { chmod(locked, 0o755) }
            settings.folders.append(locked)
            try settings.save(agent.directory)
            let waiting = agent.service.summary()
            #expect(waiting["count"] as? Int == 1)
            #expect((waiting["text"] as? String)?.hasSuffix("，1 件要你处理") == true)
            // Put down: no longer waiting.
            let number = try #require(ToolState.load(agent.directory).folderItems[locked])
            _ = agent.call("outbox_ack", ["id": SearchService.folderID(locked, number), "state": "dismissed"])
            #expect(agent.service.summary()["count"] as? Int == 0)
            // A settings file it can't read isn't "nothing chosen" (review A-05).
            try Data("{not json".utf8).write(to: agent.directory.settingsFile)
            #expect(agent.service.summary()["text"] as? String == "设置文件读不了")
        }

        @Test func photosCountOnlyWhenRead() throws {
            let photos = FakePhotos([], access: .allowed)
            let agent = try Agent(photos: photos)
            var settings = Settings()
            settings.folders = [agent.library.root]
            settings.photos = true
            try settings.save(agent.directory)
            try agent.service.noteFirstPassIfDone()
            #expect((agent.service.summary()["text"] as? String)?.hasSuffix("个文件和照片") == true)
            photos.access = .denied   // on, but not read
            #expect((agent.service.summary()["text"] as? String)?.contains("和照片") == false)
            // Only photos, not read: nothing is being indexed, not "已读 0 个".
            settings.folders = []
            try settings.save(agent.directory)
            #expect(agent.service.summary()["text"] as? String == "读不了照片，1 件要你处理")
            photos.access = .notAsked
            #expect(agent.service.summary()["text"] as? String == "要你允许读照片，1 件要你处理")
        }

        @Test func permissionStatesAsMacOSHasThem() throws {
            let photos = FakePhotos([], access: .allowed)
            let agent = try Agent(photos: photos)
            #expect(agent.service.permissionStates() == ["photos": "granted"])
            photos.access = .notAsked
            #expect(agent.service.permissionStates() == ["photos": "ask"])
            photos.access = .denied
            #expect(agent.service.permissionStates() == ["photos": "denied"])
        }

        /// The tool that asked macOS is gone: a card from before it went answers, and asks nothing.
        @Test func nothingHereAsksMacOS() throws {
            let agent = try Agent(photos: FakePhotos([], access: .notAsked))
            let tools = (agent.request("tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
            #expect(!tools.contains { $0["name"] as? String == "search_request_access" })
            let tapped = agent.request("tools/call", ["name": "search_request_access", "arguments": ["id": "photos"]])
            #expect(tapped["error"] != nil || (tapped["result"] as? [String: Any])?["isError"] as? Bool == true)
            #expect(agent.service.permissionStates() == ["photos": "ask"])
        }

        /// Photos turned on, never asked: the outbox says so, with the permission's id, so the agent can show a card;
        /// allowing it is in luoke's own window (the card has no button to ask with). Allowed, the item is done.
        @Test func neverAskedTheOutboxSaysSo() throws {
            let photos = FakePhotos([], access: .notAsked)
            let agent = try Agent(photos: photos)
            var settings = Settings()
            settings.photos = true
            try settings.save(agent.directory)
            let items = try #require(agent.service.outbox()["items"] as? [[String: Any]])
            let number = ToolState.load(agent.directory).photosItem
            #expect(items.map { $0["id"] as? String } == [SearchService.photosID(number)])
            #expect(Self.surface(items.first) == SearchService.photosSurface(number))
            #expect(items.first?["permission"] as? String == "photos" && items.first?["urgency"] as? String == "low")
            #expect((items.first?["title"] as? String)?.contains("要你允许") == true)
            let card = String(decoding: try JSONSerialization.data(withJSONObject: items.first?["card"] ?? []), as: UTF8.self)
            #expect(card.contains("允许") && card.contains("agent.dismiss"))
            #expect(!card.contains("search_request_access") && !card.contains("继续"))
            #expect(agent.service.summary()["count"] as? Int == 1)
            // As the agent's own checker draws it: valid; 「允许」 is the button luoke's window takes (`host_ask`).
            if let drawn = try Self.asTheAgentDrawsIt(agent, items.first?["card"] ?? []) {
                #expect(drawn["problems"] as? [String] == [])
                #expect(drawn["events"] as? [String] == ["search_open_system_settings", "agent.dismiss"])
            }
            photos.access = .allowed
            #expect((agent.service.outbox()["items"] as? [Any])?.isEmpty == true)
        }

        /// Each time asking is needed again (photos turned on again, access taken back), a new item: the agent never
        /// shows an id again once it's done or gone (review of PR #42, must-fix 1: after 「算了」 the user could never
        /// be asked again, and an app never asked isn't in System Settings to allow by hand).
        @Test func aNewItemEachTimeAskingIsNeededAgain() throws {
            let photos = FakePhotos([], access: .notAsked)
            let agent = try Agent(photos: photos)
            func ids() -> [String] {
                (agent.service.outbox()["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            }
            var settings = Settings()
            settings.photos = true
            try settings.save(agent.directory)
            let before = Int(Date().timeIntervalSince1970)
            let first = try #require(ids().first)
            #expect(ids() == [first])   // the same while it's needed
            // Numbered by the time: a state file lost doesn't bring back one the agent already holds as done.
            #expect(ToolState.load(agent.directory).photosItem >= before)
            // 「算了」: put down.
            _ = agent.call("outbox_ack", ["id": first, "state": "dismissed"])
            #expect(ids().isEmpty)
            // Settings changed from the command line, the outbox read by a process without the library (`mcp` in a
            // terminal): neither takes "nothing to ask" for an answer, the card put down stays put down (third review
            // of PR #42).
            let command = try SearchService(directory: agent.directory, hub: nil)
            var battery = SearchService.Change()
            battery.onBattery = true
            _ = try command.apply(planID: try command.plan(battery).0.id, surfaceID: nil)
            _ = command.outbox()
            #expect(ids().isEmpty)
            // Turned off and on again: a new item.
            settings.photos = false
            try settings.save(agent.directory)
            #expect(ids().isEmpty)
            settings.photos = true
            try settings.save(agent.directory)
            let second = try #require(ids().first)
            #expect(second != first)
            // Off and on by plans, the outbox not looked at in between, from the command line too: a new item, on a
            // card of its own (the agent keys cards by surface).
            let surfaceBefore = Self.surface((agent.service.outbox()["items"] as? [[String: Any]])?.first)
            for on in [false, true] {
                var change = SearchService.Change()
                change.photos = on
                _ = try command.apply(planID: try command.plan(change).0.id, surfaceID: nil)
            }
            let third = try #require(ids().first)
            #expect(third != second)
            #expect(Self.surface((agent.service.outbox()["items"] as? [[String: Any]])?.first) != surfaceBefore)
            // Allowed: gone. Taken back in System Settings: a new item, pointing there.
            photos.access = .allowed
            #expect(ids().isEmpty)
            photos.access = .denied
            let refused = try #require((agent.service.outbox()["items"] as? [[String: Any]])?.first)
            let fourth = try #require(refused["id"] as? String)
            #expect(fourth != third && refused["title"] as? String == "螺壳搜索读不了「照片」")
            // Only the latest is kept: an earlier one isn't the outbox's any more.
            #expect(Self.code(agent.call("outbox_ack", ["id": first, "state": "dismissed"])) == "invalid")
            _ = agent.call("outbox_ack", ["id": fourth, "state": "dismissed"])
            #expect(ToolState.load(agent.directory).closed == [fourth])
        }

        /// The app's own program run in a terminal (`mcp`, `LuokeSearch.isApp`) has the library, but the terminal's
        /// answer for Photos: only the resident's decides the item, or a card put down comes back with a new number
        /// (noted when PR #44 was merged).
        @Test func onlyTheResidentRenumbersPhotos() throws {
            let agent = try Agent(photos: FakePhotos([], access: .notAsked))
            let terminalPhotos = FakePhotos([], access: .allowed)
            let terminal = try SearchService(directory: agent.directory, hub: nil, photos: terminalPhotos)
            func ids(_ service: SearchService) -> [String] {
                (service.outbox()["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            }
            var settings = Settings()
            settings.photos = true
            try settings.save(agent.directory)
            let first = try #require(ids(agent.service).first)
            let number = ToolState.load(agent.directory).photosItem
            // Allowed in the terminal: still the resident's item, and nothing noted in its place.
            #expect(ids(terminal) == [first])
            #expect(ToolState.load(agent.directory).photosNeeded)
            // 「算了」, then the terminal's answer each way: the card put down stays put down, under the same number.
            _ = agent.call("outbox_ack", ["id": first, "state": "dismissed"])
            for access in [PhotoAccess.allowed, .denied, .notAsked] {
                terminalPhotos.access = access
                #expect(ids(terminal).isEmpty)
                #expect(ids(agent.service).isEmpty)
                #expect(ToolState.load(agent.directory).photosItem == number)
            }
        }

        /// Refused: macOS won't ask again, so the card goes to System Settings, with 「算了」: or it stays for good.
        @Test func refusedTheOutboxSaysWhereToAllow() throws {
            let photos = FakePhotos([], access: .notAsked)
            let agent = try Agent(photos: photos)
            var settings = Settings()
            settings.photos = true
            try settings.save(agent.directory)
            let item = try #require((agent.service.outbox()["items"] as? [[String: Any]])?.first)
            let first = try #require(item["id"] as? String)
            photos.access = .denied
            // The same item, its card changed (the agent draws it again).
            let items = try #require(agent.service.outbox()["items"] as? [[String: Any]])
            #expect(items.map { $0["id"] as? String } == [first])
            #expect((items.first?["title"] as? String)?.contains("读不了") == true)
            let card = String(decoding: try JSONSerialization.data(withJSONObject: items.first?["card"] ?? []), as: UTF8.self)
            #expect(card.contains("search_open_system_settings") && card.contains("agent.dismiss"))
            #expect(Self.surface(items.first) == Self.surface(item))   // the same card, drawn again
        }

        /// A folder macOS won't let it read isn't one of the manifest's permissions: no `permission`, and its card
        /// goes to System Settings, as it always did.
        @Test func aFolderCardGoesToSystemSettings() throws {
            let agent = try Agent()
            let locked = agent.library.scratch.path + "/locked"
            try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
            chmod(locked, 0o000)
            defer { chmod(locked, 0o755) }
            var settings = Settings()
            settings.folders = [locked]
            try settings.save(agent.directory)
            let item = try #require((agent.service.outbox()["items"] as? [[String: Any]])?.first)
            #expect(item["kind"] as? String == "needs-access" && item["permission"] == nil)
            let card = String(decoding: try JSONSerialization.data(withJSONObject: item["card"] ?? []), as: UTF8.self)
            #expect(card.contains("search_open_system_settings") && card.contains("files"))
        }
    }
}
