import Foundation
import Testing
@testable import LuokeSearchKit

/// Runs `work` on a thread of its own, for a test that waits for it ("from another thread, as PhotoKit does", "another
/// connection holding the lock"). Not `DispatchQueue.global()`: that pool starts a new thread only while fewer of this
/// process's threads than cores are running at its priority or higher, and while the whole suite runs the threads running
/// the tests keep every core busy, so work handed to it waited 11.8 s to start (measured 11-09), longer than the tests
/// waited for it. A thread of its own starts at once.
func onAnotherThread(_ work: @escaping @Sendable () -> Void) {
    Thread.detachNewThread(work)
}

/// Polls `condition` for up to `seconds` (FSEvents and the resident queue work on their own time).
func eventually(_ seconds: Double = 10, _ condition: () throws -> Bool) rethrows -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if try condition() { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return try condition()
}

extension ReadsPictures {
    struct ResidentTests {
        @Test func onlyWhatChangedIsSynced() throws {
            let library = try Library()
            _ = try library.index()
            let root = library.root
            // New, renamed, removed, a new folder with files, and changes that must be ignored.
            try library.scratch.write("files/notes/新的.md", "# 新的\n一份新文件，提到了樱花季。")
            try FileManager.default.moveItem(atPath: root + "/notes/running.txt", toPath: root + "/notes/跑步.txt")
            try FileManager.default.removeItem(atPath: root + "/notes/行程.html")
            try library.scratch.write("files/trip/day1.md", "Day one in Kyoto.")
            try library.scratch.write("files/trip/day2.md", "Day two in Nara.")
            try library.scratch.write("files/app/node_modules/x/new.md", "dependency")
            try library.scratch.write("files/app/new-notes.md", "in a code project")
            try library.scratch.write("files/passwords.md", "secret")
            let changed = [root + "/notes/新的.md", root + "/notes/running.txt", root + "/notes/跑步.txt",
                           root + "/notes/行程.html", root + "/trip", root + "/app/node_modules/x/new.md",
                           root + "/app/new-notes.md", root + "/passwords.md"]
            let report = try library.indexer.sync([root], changed: changed)
            #expect(report.added == 3)    // 新的.md, day1, day2
            #expect(report.moved == 1)    // running.txt → 跑步.txt
            #expect(report.removed == 1)  // 行程.html
            #expect(try library.store.item(path: root + "/notes/跑步.txt")?.state == "done")
            #expect(try library.store.item(path: root + "/app/new-notes.md") == nil)
            #expect(try library.store.item(path: root + "/passwords.md") == nil)
            // A removed folder takes its items with it.
            try FileManager.default.removeItem(atPath: root + "/trip")
            #expect(try library.indexer.sync([root], changed: [root + "/trip"]).removed == 2)
        }

        @Test func residentFollowsTheFolders() throws {
            let library = try Library()
            let data = DataDirectory(url: library.scratch.url.appendingPathComponent("data"))
            var settings = Settings()
            settings.folders = [library.root]
            try settings.save(data)
            let resident = try Resident(directory: data, hub: nil)
            resident.readsBacklog = false
            resident.start()
            defer { resident.stop() }
            let searcher = Searcher(store: library.store)
            // The folders are walked at start; new files (up to 50) are read right away.
            #expect(try eventually { try searcher.search("押金").hits.first?.title == "租赁合同摘要.md" })
            // A file saved later is searchable a moment after.
            try library.scratch.write("files/notes/樱花.md", "# 樱花\n京都的樱花季在四月初。")
            #expect(try eventually { try searcher.search("樱花季").hits.first?.title == "樱花.md" })
            // Renamed: same item, new name.
            try FileManager.default.moveItem(atPath: library.root + "/notes/樱花.md",
                                             toPath: library.root + "/notes/京都.md")
            #expect(try eventually { try searcher.search("樱花季").hits.first?.title == "京都.md" })
            // Deleted: gone.
            try FileManager.default.removeItem(atPath: library.root + "/notes/京都.md")
            #expect(try eventually { try searcher.search("樱花季").hits.isEmpty })
        }

        @Test func residentWatchesNewSettings() throws {
            let library = try Library()
            let data = DataDirectory(url: library.scratch.url.appendingPathComponent("data"))
            let resident = try Resident(directory: data, hub: nil)
            resident.readsBacklog = false
            resident.start()
            defer { resident.stop() }
            let searcher = Searcher(store: library.store)
            try library.scratch.write("files/notes/later.md", "Lantern festival notes.")
            Thread.sleep(forTimeInterval: 1.5)
            #expect(try searcher.search("lantern").hits.isEmpty)   // nothing watched yet
            var settings = Settings()
            settings.folders = [library.root + "/notes"]
            try settings.save(data)
            resident.settingsChanged()
            #expect(try eventually { try searcher.search("lantern").hits.first?.title == "later.md" })
            #expect(try searcher.search("押金").hits.isEmpty)   // outside the folders searched
        }

        @Test func firstPassStopsAndGoesOn() throws {
            let library = try Library()
            let data = DataDirectory(url: library.scratch.url.appendingPathComponent("data"))
            var settings = Settings()
            settings.folders = [library.root]
            try settings.save(data)
            let pass = FirstPass(directory: data, store: library.store, hub: nil)
            let first = try pass.run(limit: 2)
            #expect(first.read == 2)
            #expect(ToolState.load(data).firstPassDone == nil)
            var asked = 0
            let stopped = try pass.run(shouldStop: { asked += 1; return asked > 2 })
            #expect(stopped.stopped)
            let rest = try pass.run()
            #expect(!rest.stopped)
            #expect(try library.store.counts().waitingToRead == 0)
            #expect(ToolState.load(data).firstPassDone != nil)   // the index-ready report can go out
        }
    }
}

struct SchemaTests {
    @Test func schemaTwoGetsTheQueueTime() throws {
        let scratch = try Scratch()
        let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        do {
            let store = try IndexStore(directory: data, home: scratch.path)
            try store.db.execute("""
                ALTER TABLE items DROP COLUMN queued_at; ALTER TABLE items DROP COLUMN attempts;
                ALTER TABLE segments DROP COLUMN tries; DROP INDEX segments_vec_seq; DROP INDEX segments_vec_unsequenced;
                ALTER TABLE segments DROP COLUMN vec_seq;
                PRAGMA user_version = 2
                """)
        }
        let store = try IndexStore(directory: data, home: scratch.path)
        #expect(try store.db.scalarInt("PRAGMA user_version") == IndexStore.schemaVersion)
        try store.db.query("SELECT queued_at, attempts FROM items LIMIT 1")   // the columns are back
        try store.db.query("SELECT tries, vec_seq FROM segments LIMIT 1")
    }

    @Test("Schema 5 → 6: a page of items waiting for pictures and sound starts where the last ended (review of #51)")
    func schemaSixPagesTheMediaThatWaits() throws {
        let scratch = try Scratch()
        let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        do {
            let store = try IndexStore(directory: data, home: scratch.path)
            try store.db.execute("DROP INDEX segments_todo_item; PRAGMA user_version = 5")
        }
        let store = try IndexStore(directory: data, home: scratch.path)
        #expect(try store.db.scalarInt("PRAGMA user_version") == IndexStore.schemaVersion)
        var plan: [String] = []
        try store.db.query("EXPLAIN QUERY PLAN " + IndexStore.mediaTodosQuery("'image', 'audio'"), [.int(0), .int(8)]) {
            plan.append($0.text(3) ?? "")
        }
        #expect(plan.contains { $0.contains("segments_todo_item (todo=? AND item>?)") }, "\(plan)")
    }
}

struct ManifestTests {
    static let manifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/luoke-accessory.json")

    @Test func manifestMatchesTheCode() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.manifest)) as? [String: Any])
        #expect(json["accessory"] as? String == LuokeSearch.accessory)
        #expect(json["bundle_id"] as? String == "ai.luoke.search")
        #expect(json["version"] as? String == LuokeSearch.version)
        #expect(json["min_macos"] as? String == "26.2")
        #expect((json["tasks"] as? [[String: Any]])?.first?["name"] as? String == "luoke-search.embed")
        #expect(json["data"] as? [String] == ["~/.luoke-search"])
        let written = try JSONSerialization.data(withJSONObject: json["capabilities"] ?? [:], options: [.sortedKeys])
        let code = try JSONSerialization.data(withJSONObject: AgentTools.manifestCapabilities, options: [.sortedKeys])
        #expect(written == code)
        #expect(json["jobs"] == nil)   // until luoke-core can launch a Swift accessory's job
    }

    /// When the code changed and the version didn't, luoke-core's release ships the previous version's package: the
    /// version is bumped in `LuokeSearch.version`, the manifest and Info.plist together (`build_app.sh` stamps the
    /// built app's from the code).
    @Test func versionsAgree() throws {
        let resources = Self.manifest.deletingLastPathComponent()
        let plist = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: resources.appendingPathComponent("Info.plist")), format: nil) as? [String: Any])
        #expect(plist["CFBundleShortVersionString"] as? String == LuokeSearch.version)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.manifest)) as? [String: Any])
        #expect(json["version"] as? String == LuokeSearch.version)
        #expect(LuokeSearch.version == "0.1.21")
    }

    /// Info.plist names the icon `build_app.sh` makes, from a 1024-pixel square PNG in Resources.
    @Test func iconIsThere() throws {
        let resources = Self.manifest.deletingLastPathComponent()
        let plist = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: resources.appendingPathComponent("Info.plist")), format: nil) as? [String: Any])
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
        let png = try Data(contentsOf: resources.appendingPathComponent("AppIcon.png"))
        try #require(png.count >= 24)
        #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(png[12..<16] == Data("IHDR".utf8))
        // IHDR's width and height, big-endian, right after the signature and the chunk's length and type
        func word(_ at: Int) -> UInt32 { png[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        #expect(word(16) == 1024 && word(20) == 1024)
    }

    /// The name people see (2026-11-04: 螺壳搜索) is the same in Info.plist, the manifest and the app `build_app.sh` makes.
    @Test func namesAgree() throws {
        let resources = Self.manifest.deletingLastPathComponent()
        let plist = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: resources.appendingPathComponent("Info.plist")), format: nil) as? [String: Any])
        #expect(plist["CFBundleName"] as? String == "螺壳搜索")
        #expect(plist["CFBundleDisplayName"] as? String == "螺壳搜索")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.manifest)) as? [String: Any])
        #expect(json["name"] as? String == "螺壳搜索")
        let script = try String(contentsOf: resources.deletingLastPathComponent()
            .appendingPathComponent("scripts/build_app.sh"), encoding: .utf8)
        #expect(script.contains("app=\"build.noindex/螺壳搜索.app\""))
    }
}
