import Foundation
import Testing
@testable import LuokeSearchKit

// 10-26: once installed, Luoke Search searched nowhere (no folder chosen) and nobody told the user. Until
// something is chosen the outbox offers the usual places (`needs-setup`), ticked, the Photos library not; and the app
// as it ships takes `settings` typed by hand. Synthetic folders in a scratch home only.

/// A home folder of its own with the usual places in it, as the app as it ships would see one.
final class SetupHome {
    let scratch: Scratch
    let directory: DataDirectory
    let service: SearchService
    let server: MCPServer
    var home: String { scratch.path + "/home" }
    var ids = 0

    /// `places`: which of Desktop, Documents and Downloads are there.
    init(places: [String] = ["Desktop", "Documents", "Downloads"]) throws {
        scratch = try Scratch()
        for place in places { try FileManager.default.createDirectory(atPath: scratch.path + "/home/" + place,
                                                                       withIntermediateDirectories: true) }
        directory = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        service = try SearchService(directory: directory, hub: nil, opener: Opened().opener, home: scratch.path + "/home")
        service.restrictFolders = true   // the app as it ships
        service.judgesAccess = true   // its resident's socket
        service.folderAccess = FolderAccess(patience: 30)   // a busy test run: the answer, not a timeout
        server = AgentTools.server(service)
    }

    var items: [[String: Any]] { service.outbox()["items"] as? [[String: Any]] ?? [] }
    var setup: [String: Any]? { items.first { $0["kind"] as? String == "needs-setup" } }

    /// The plan on the `needs-setup` card: what its [好] sends.
    func planID(_ item: [String: Any]?) throws -> String {
        let surface = try #require(Self.surfaceID(item?["card"]))
        return String(surface.dropFirst(2))   // "s-<plan id>"
    }

    static func surfaceID(_ card: Any?) -> String? {
        ((card as? [[String: Any]])?.first?["createSurface"] as? [String: Any])?["surfaceId"] as? String
    }

    /// `tools/call` of `search_settings_apply` as the agent makes it when [好] is tapped on that card.
    func tap(_ plan: String, checks: [String: Any]? = nil, surface: String? = nil) -> [String: Any] {
        ids += 1
        var arguments: [String: Any] = ["plan_id": plan]
        if let checks { arguments["checks"] = checks }
        let meta: [String: Any] = ["io.modelcontextprotocol/protocolVersion": "2026-07-28",
                                   "ai.luoke/user-action": ["surfaceId": surface ?? "s-" + plan, "componentId": "b1",
                                                            "at": "2026-10-26T10:00:00+08:00"]]
        let call = server.handle(["jsonrpc": "2.0", "id": ids, "method": "tools/call", "params": [
            "name": "search_settings_apply", "arguments": arguments, "_meta": meta,
        ]])
        return call?["result"] as? [String: Any] ?? [:]
    }

    static func code(_ result: [String: Any]) -> String? { (result["structuredContent"] as? [String: Any])?["code"] as? String }

    /// Every component of a card's messages, and its data model.
    static func components(_ card: Any?) -> [[String: Any]] {
        (card as? [[String: Any]] ?? []).flatMap {
            (($0["updateComponents"] as? [String: Any])?["components"] as? [[String: Any]]) ?? []
        }
    }

    static func checks(_ card: Any?) -> [String: Bool] {
        for message in card as? [[String: Any]] ?? [] {
            if let model = (message["updateDataModel"] as? [String: Any])?["value"] as? [String: Any] {
                return model["checks"] as? [String: Bool] ?? [:]
            }
        }
        return [:]
    }
}

struct SetupPlanTests {
    @Test("A plan's ticks: only its own choices, the rest as they started; a plan without choices takes none")
    func ticked() throws {
        var plan = SettingsPlan(id: "plan-x", made: 0, basis: Settings())
        plan.addFolders = ["/h/Desktop", "/h/Documents"]
        plan.choices = ["folder0": true, "folder1": true, "photos": false]
        let asOffered = try #require(plan.ticked([:]))
        #expect(asOffered.addFolders == ["/h/Desktop", "/h/Documents"] && asOffered.photos == nil && asOffered.choices == nil)
        // A version that knows no choices carries it out as it started: no Photos library.
        #expect(plan.photos == nil)
        let changed = try #require(plan.ticked(["folder0": false, "photos": true]))
        #expect(changed.addFolders == ["/h/Documents"] && changed.photos == true)
        #expect(plan.ticked(["folder2": true]) == nil)   // not on the card
        #expect(try #require(plan.ticked(["folder0": false, "folder1": false])).isEmpty)
        var plain = SettingsPlan(id: "plan-y", made: 0, basis: Settings())
        plain.addFolders = ["/h/notes"]
        #expect(plain.ticked([:]) == plain)
        #expect(plain.ticked(["photos": true]) == nil)
    }

    @Test("A plan with choices kept in state.json reads back; one written before choices existed has none")
    func storedChoices() throws {
        let scratch = try Scratch()
        let directory = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        var plan = SettingsPlan(id: "plan-x", made: 1, basis: Settings())
        plan.choices = ["folder0": true]
        try ToolState.update(directory) { $0.plans = [plan]; $0.foldersChosen = 5 }
        let state = ToolState.load(directory)
        #expect(state.plans == [plan] && state.foldersChosen == 5)
        // As builds before plan choices wrote it.
        try Data(#"{"closed": [], "plans": [{"add_folders": ["/h/a"], "basis": {"folders": [], "on_battery": true, "photos": false, "skip_folders": []}, "id": "plan-old", "made": 1, "remove_folders": [], "skip_folders": []}]}"#.utf8)
            .write(to: directory.stateFile)
        let old = ToolState.load(directory)
        #expect(old.plans.first?.choices == nil && old.plans.first?.addFolders == ["/h/a"] && old.foldersChosen == nil)
    }
}

extension SetupPlanTests {
    @Test("The manifest lists the new report (ManifestTests checks it against luoke-accessory.json)")
    func manifest() throws {
        let reports = (AgentTools.manifestCapabilities["reports"] as? [[String: Any]])?.compactMap { $0["kind"] as? String }
        #expect(reports == ["needs-setup", "needs-access", "index-ready"])
    }
}

struct ShippedSettingsTests {
    static func run(_ arguments: [String], shipped: Bool = true, _ setup: SetupHome) throws -> String {
        var parsed = try CommandArguments(ArraySlice(arguments))
        parsed.shipped = shipped
        return try SettingsCommand.run(parsed, directory: setup.directory, home: setup.home)
    }

    static func refused(_ arguments: [String], shipped: Bool = true, _ setup: SetupHome) -> String? {
        do {
            _ = try run(arguments, shipped: shipped, setup)
            return nil
        } catch {
            return "\(error)"
        }
    }

    @Test("The app as it ships runs settings; its other switches are still refused")
    func shippedTakesSettings() throws {
        func refusal(_ arguments: [String], _ environment: [String: String] = [:]) throws -> String? {
            try CommandArguments(ArraySlice(arguments)).shippedRefusal(command: "settings", environment: environment)
        }
        #expect(try refusal(["--add-folder", "/home/someone/Documents"]) == nil)
        #expect(try refusal(["--index", "/x", "--add-folder", "documents"])?.contains("--index") == true)
        #expect(try refusal(["--photos", "on"], ["LUOKE_SEARCH_HOME": "/z"])?.contains("LUOKE_SEARCH_HOME") == true)
        #expect(try refusal([], ["CFFIXED_USER_HOME": ""])?.contains("CFFIXED_USER_HOME") == true)
    }

    @Test("Shipped: settings --add-folder ~/Documents changes them; a hidden folder or one in ~/Library is refused")
    func addFolders() throws {
        let setup = try SetupHome()
        for folder in ["notes/.git", ".ssh", "Library/Messages", "Library/Mobile Documents/com~apple~CloudDocs/工作"] {
            try FileManager.default.createDirectory(atPath: setup.home + "/" + folder, withIntermediateDirectories: true)
        }
        let said = try Self.run(["--add-folder", "~/Documents"], setup)
        #expect(said.hasPrefix("好了，设置改好了。") && said.contains("要搜的文件夹：\(setup.home)/Documents"), "\(said)")
        #expect(Settings.load(setup.directory).folders == [setup.home + "/Documents"])
        for folder in ["~/.ssh", setup.home + "/notes/.git", "~/Library/Messages", "~/Library", "/etc", "~/.not-there"] {
            let why = try #require(Self.refused(["--add-folder", folder], setup), "\(folder)")
            #expect(why.contains("螺壳搜索不搜") && why.contains("只搜你的个人文件夹和外接磁盘里不隐藏的文件夹"), "\(why)")
        }
        // iCloud Drive is the one place in ~/Library it takes; the usual places by name too.
        _ = try Self.run(["--add-folder", "~/Library/Mobile Documents/com~apple~CloudDocs/工作", "--add-folder", "desktop"], setup)
        #expect(Settings.load(setup.directory).folders == [setup.home + "/Documents",
                                                          setup.home + "/Library/Mobile Documents/com~apple~CloudDocs/工作",
                                                          setup.home + "/Desktop"])
        // A development run takes any folder, as before.
        #expect(Self.refused(["--add-folder", "~/.ssh"], shipped: false, setup) == nil)
    }

    @Test("Shipped: --skip-folder only inside a folder searched (one added in the same command counts)")
    func skipFolders() throws {
        let setup = try SetupHome()
        for folder in ["Documents/old", "Downloads/tmp", "elsewhere"] {
            try FileManager.default.createDirectory(atPath: setup.home + "/" + folder, withIntermediateDirectories: true)
        }
        let why = try #require(Self.refused(["--skip-folder", "~/elsewhere"], setup))
        #expect(why.contains("只能跳过要搜的文件夹里面的"), "\(why)")
        _ = try Self.run(["--add-folder", "documents", "--skip-folder", "~/Documents/old"], setup)
        #expect(Settings.load(setup.directory).skipFolders == [setup.home + "/Documents/old"])
        #expect(Self.refused(["--skip-folder", "~/Downloads/tmp"], setup) != nil)   // Downloads isn't searched
        #expect(Self.refused(["--skip-folder", "~/Documents"], setup) != nil)       // the folder itself isn't inside
        // Taken out in the same command: what's inside it isn't searched either.
        #expect(Self.refused(["--remove-folder", "documents", "--skip-folder", "~/Documents/new"], setup) != nil)
        #expect(Self.refused(["--skip-folder", "~/elsewhere"], shipped: false, setup) == nil)
        // Documents a link elsewhere (to a synced folder): chosen by name, skipped by path, the same place.
        let linked = try SetupHome(places: [])
        try FileManager.default.createDirectory(atPath: linked.home + "/Sync/文稿/old", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linked.home + "/Documents", withDestinationPath: linked.home + "/Sync/文稿")
        _ = try Self.run(["--add-folder", "documents", "--skip-folder", "~/Documents/old"], linked)
        #expect(Settings.load(linked.directory).skipFolders == [linked.home + "/Sync/文稿/old"])
    }
}

extension ReadsPictures {
    struct SetupReportTests {
        @Test("Nothing chosen: the outbox offers the usual places that are there and searchable, ticked; Photos not")
        func offered() throws {
            let setup = try SetupHome(places: ["Desktop", "Documents"])
            // Downloads is there, but a link into ~/Library: not offered.
            try FileManager.default.createDirectory(atPath: setup.home + "/Library/Messages", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: setup.home + "/Downloads",
                                                       withDestinationPath: setup.home + "/Library/Messages")
            let items = setup.items
            #expect(items.map { $0["kind"] as? String } == ["needs-setup"])
            let item = try #require(items.first)
            #expect(item["id"] as? String == "needs-setup" && item["urgency"] as? String == "normal")
            #expect((item["title"] as? String) == "螺壳搜索还没选要搜的地方")
            // Named as Finder names them, without asking Finder (it may look inside, and macOS would ask first).
            #expect((item["summary"] as? String)?.contains("「桌面」、「文稿」") == true)
            let components = SetupHome.components(item["card"])
            let boxes = components.filter { $0["component"] as? String == "CheckBox" }
            #expect(boxes.map { $0["label"] as? String } == ["桌面", "文稿", "照片图库里的照片和视频（要你允许读照片）"])
            #expect(SetupHome.checks(item["card"]) == ["folder0": true, "folder1": true, "photos": false])
            let apply = try #require(components.first {
                (($0["action"] as? [String: Any])?["event"] as? [String: Any])?["name"] as? String == "search_settings_apply"
            })
            let context = ((apply["action"] as? [String: Any])?["event"] as? [String: Any])?["context"] as? [String: Any]
            #expect(context?["plan_id"] as? String == (try setup.planID(item)))
            #expect((context?["checks"] as? [String: String]) == ["path": "/checks"])
            // The same plan on every read while nothing changes; nothing chosen yet.
            #expect(try setup.planID(setup.setup) == (try setup.planID(item)))
            #expect(ToolState.load(setup.directory).plans.count == 1)
            #expect(Settings.load(setup.directory).folders.isEmpty)
            // A place made since: the card is made again, the old plan dropped.
            try FileManager.default.removeItem(atPath: setup.home + "/Downloads")
            try FileManager.default.createDirectory(atPath: setup.home + "/Downloads", withIntermediateDirectories: true)
            let again = try #require(setup.setup)
            #expect(try setup.planID(again) != (try setup.planID(item)))
            #expect(SetupHome.checks(again["card"]).count == 4)
            #expect(ToolState.load(setup.directory).plans.map(\.id) == [try setup.planID(again)])
            #expect(SetupHome.code(setup.tap(try setup.planID(item))) == "stale")
        }

        @Test("Not offered: in a development run, with none of the places there, with the settings unreadable")
        func notOffered() throws {
            let development = try SetupHome()
            development.service.restrictFolders = false
            #expect(development.items.isEmpty)
            #expect(try SetupHome(places: []).items.isEmpty)
            let unreadable = try SetupHome()
            try unreadable.directory.prepare()
            try Data("{ not json".utf8).write(to: unreadable.directory.settingsFile)
            #expect(unreadable.items.isEmpty)
        }

        @Test("Tapped: what's ticked is chosen; after that it isn't offered, even once everything's taken out again")
        func chosen() throws {
            let setup = try SetupHome()
            let plan = try setup.planID(setup.setup)
            // Without the user's tap, with a choice not on the card, with nothing ticked: nothing changes.
            let untapped = setup.server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
                "name": "search_settings_apply", "arguments": ["plan_id": plan],
            ]])
            #expect(((untapped?["result"] as? [String: Any]).map(SetupHome.code)) == "needs_user_action")
            #expect(SetupHome.code(setup.tap(plan, checks: ["folder9": true])) == "invalid")
            #expect(SetupHome.code(setup.tap(plan, checks: ["photos": "yes"])) == "invalid")
            #expect(SetupHome.code(setup.tap(plan, checks: ["folder0": false, "folder1": false, "folder2": false])) == "invalid")
            #expect(SetupHome.code(setup.tap(plan, surface: "s-other")) == "needs_user_action")
            #expect(Settings.load(setup.directory).folders.isEmpty)
            // Downloads unticked, Photos ticked.
            let done = setup.tap(plan, checks: ["folder0": true, "folder1": true, "folder2": false, "photos": true])
            #expect((done["structuredContent"] as? [String: Any])?["done"] as? Bool == true)
            let settings = Settings.load(setup.directory)
            #expect(settings.folders == [setup.home + "/Desktop", setup.home + "/Documents"] && settings.photos)
            #expect(setup.setup == nil)
            #expect(ToolState.load(setup.directory).foldersChosen != nil)
            // All taken out again (the user's own doing): not offered again.
            var change = SearchService.Change()
            change.removeFolders = ["desktop", "documents"]
            change.photos = false
            _ = try setup.service.apply(planID: try setup.service.plan(change).0.id, surfaceID: nil)
            #expect(Settings.load(setup.directory).folders.isEmpty && !Settings.load(setup.directory).photos)
            #expect(setup.setup == nil)
        }

        @Test("Put down ([算了]), or chosen some other way before: not offered")
        func putDownOrChosenBefore() throws {
            let dismissed = try SetupHome()
            #expect(dismissed.setup != nil)
            try dismissed.service.acknowledge("needs-setup", state: "dismissed")
            #expect(dismissed.setup == nil)
            // Folders chosen by an earlier version or by hand, taken out since: noted on the read before.
            let earlier = try SetupHome()
            var settings = Settings()
            settings.folders = [earlier.home + "/Documents"]
            try settings.save(earlier.directory)
            #expect(earlier.setup == nil)
            try Settings().save(earlier.directory)
            #expect(earlier.setup == nil)
        }

        @Test("A card from before, still in the conversation, doesn't bring the usual places back")
        func oldCardAfterChoosing() throws {
            // Chosen with the command line meanwhile, then all taken out again: the settings are as the card's basis.
            let setup = try SetupHome()
            let plan = try setup.planID(setup.setup)
            _ = try ShippedSettingsTests.run(["--add-folder", "documents"], setup)
            #expect(!ToolState.load(setup.directory).plans.contains { $0.id == plan })   // its plan went with it
            _ = try ShippedSettingsTests.run(["--remove-folder", "documents"], setup)
            #expect(Settings.load(setup.directory) == Settings())
            let tapped = setup.tap(plan)
            #expect(SetupHome.code(tapped) == "stale")
            #expect(Settings.load(setup.directory).folders.isEmpty)
            // Put down: its plan goes, a tap on it is stale.
            let dismissed = try SetupHome()
            let other = try dismissed.planID(dismissed.setup)
            try dismissed.service.acknowledge("needs-setup", state: "dismissed")
            #expect(ToolState.load(dismissed.directory).plans.isEmpty)
            #expect(SetupHome.code(dismissed.tap(other)) == "stale")
            // The plan kept even so (made by a version before this rule): refused all the same.
            let kept = try SetupHome()
            let third = try kept.planID(kept.setup)
            let saved = ToolState.load(kept.directory).plans
            try kept.service.acknowledge("needs-setup", state: "dismissed")
            try ToolState.update(kept.directory) { $0.plans = saved }
            #expect(SetupHome.code(kept.tap(third)) == "stale")
            #expect(Settings.load(kept.directory).folders.isEmpty)
        }

        @Test("Folders an earlier version chose that the app as it ships doesn't search: nothing's searched, so offered")
        func onlyRefusedFoldersChosen() throws {
            let setup = try SetupHome()
            try FileManager.default.createDirectory(atPath: setup.home + "/Library/Messages", withIntermediateDirectories: true)
            var settings = Settings()
            settings.folders = [setup.home + "/Library/Messages"]
            try settings.save(setup.directory)
            #expect(setup.setup != nil)
            #expect(ToolState.load(setup.directory).foldersChosen == nil)
            #expect((setup.tap(try setup.planID(setup.setup))["structuredContent"] as? [String: Any])?["done"] as? Bool == true)
            #expect(try setup.service.status()["folders"] as? [String] == [setup.home + "/Desktop", setup.home + "/Documents",
                                                                       setup.home + "/Downloads"])
        }

        @Test("A folder macOS won't let it read: the card drawn again with the ticks left as they are")
        func notReadable() throws {
            let setup = try SetupHome()
            chmod(setup.home + "/Documents", 0o000)
            defer { chmod(setup.home + "/Documents", 0o755) }
            let plan = try setup.planID(setup.setup)
            let result = setup.tap(plan, checks: ["folder2": false])
            #expect(SetupHome.code(result) == "needs_setup")
            let card = (result["structuredContent"] as? [String: Any])?["card"]
            #expect(SetupHome.surfaceID(card) == nil)   // the same card, in place
            #expect(SetupHome.checks(card).isEmpty)     // its ticks untouched
            let components = SetupHome.components(card)
            #expect(components.filter { $0["component"] as? String == "CheckBox" }.count == 4)
            #expect(components.contains { ($0["text"] as? String)?.contains("「文稿」：在系统设置里允许以后") == true })
            #expect(components.contains {
                (($0["action"] as? [String: Any])?["event"] as? [String: Any])?["name"] as? String == "search_open_system_settings"
            })
            // Desktop alone goes through, the plan's still there to tap.
            #expect((setup.tap(plan, checks: ["folder1": false, "folder2": false])["structuredContent"]
                     as? [String: Any])?["done"] as? Bool == true)
            #expect(Settings.load(setup.directory).folders == [setup.home + "/Desktop"])
        }

        /// The agent's own card checker (`scripts/agent/a2ui.py`, luoke-agent's, unmodified): draws the card, then
        /// what [好] sends once the user has ticked `ticked` (the client's data model, as the agent merges it).
        static let agentTap = """
            import json, sys
            sys.path.insert(0, sys.argv[1])
            import a2ui
            card, ticked = json.load(open(sys.argv[2])), json.loads(sys.argv[3])
            surface = a2ui.build(card)
            button = next(c["id"] for c in surface.components.values() if c.get("component") == "Button"
                          and c["action"]["event"]["name"] == "search_settings_apply")
            name, declared = surface.button_event(button)
            print(json.dumps({"name": name, "arguments": a2ui.merge_context(declared, {"checks": ticked}, surface.data),
                              "untouched": a2ui.merge_context(declared, {}, surface.data)}))
            """

        @Test("The agent draws the card with its own checker; [好] sends the plan and what's ticked",
              .enabled(if: agentScripts != nil))
        func asTheAgentDrawsIt() throws {
            let setup = try SetupHome()
            let item = try #require(setup.setup)
            let card = try setup.scratch.write("card.json", data: try JSONSerialization.data(withJSONObject: item["card"] ?? []))
            let scripts = try #require(agentScripts)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", "-c", Self.agentTap, scripts, card.path,
                                 #"{"folder0": true, "folder1": false, "folder2": true, "photos": true}"#]
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            let said = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let tap = try #require(try JSONSerialization.jsonObject(with: said) as? [String: Any])
            #expect(tap["name"] as? String == "search_settings_apply")
            let untouched = try #require(tap["untouched"] as? [String: Any])
            #expect(untouched["checks"] as? [String: Bool] == ["folder0": true, "folder1": true, "folder2": true, "photos": false])
            let arguments = try #require(tap["arguments"] as? [String: Any])
            let plan = try #require(arguments["plan_id"] as? String)
            let done = setup.tap(plan, checks: arguments["checks"] as? [String: Any])
            #expect((done["structuredContent"] as? [String: Any])?["done"] as? Bool == true)
            let settings = Settings.load(setup.directory)
            #expect(settings.folders == [setup.home + "/Desktop", setup.home + "/Downloads"] && settings.photos)
        }

        @Test("Tapped [好]: the folders ticked start being indexed")
        func startsIndexing() throws {
            let setup = try SetupHome()
            try setup.scratch.write("home/Documents/搬家清单.md", "# 搬家\n周六上午九点搬家公司到楼下。")
            try setup.scratch.write("home/Downloads/发票.txt", "十月的电费发票")
            // The resident loop as `serve` runs it, minus the folder rule: it judges with this account's home, and the
            // scratch home is elsewhere (the rule at walks has its own tests).
            let resident = try Resident(directory: setup.directory, hub: nil)
            resident.readsBacklog = false
            setup.service.onSettingsChanged = { resident.settingsChanged() }
            resident.start()
            defer { resident.stop() }
            let searcher = Searcher(store: setup.service.store)
            Thread.sleep(forTimeInterval: 1)
            #expect(try searcher.search("搬家公司").hits.isEmpty)   // nothing chosen, nothing read
            let plan = try setup.planID(setup.setup)
            _ = setup.tap(plan, checks: ["folder2": false])
            #expect(try eventually { try searcher.search("搬家公司").hits.first?.title == "搬家清单.md" })
            #expect(try searcher.search("电费发票").hits.isEmpty)   // Downloads unticked
        }
    }
}
