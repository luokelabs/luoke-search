import Foundation
import Testing
@testable import LuokeSearchKit

// The whole-branch review of 11bc2ca: walking, settings and the resident service, each finding reproduced by number.

struct ReviewWalkTests {
    /// Two notes in `files/`, one in `files/sub/`, read.
    func library() throws -> (Scratch, IndexStore, Indexer) {
        let scratch = try Scratch()
        try scratch.write("files/old.md", "# 旧笔记\n几个月没打开过。")
        try scratch.write("files/new.md", "# 新笔记\n刚写的。")
        try scratch.write("files/sub/inside.md", "# 里面\n子文件夹里的笔记。")
        let store = try scratch.store()
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        _ = try indexer.sync([scratch.path + "/files"])
        try indexer.readPending()
        return (scratch, store, indexer)
    }

    @Test("A-04: a file iCloud moved off this Mac stays in the index as it was read")
    func evictedFiles() throws {
        let (scratch, store, indexer) = try library()
        indexer.crawler.isDataless = { _ in false }
        let old = scratch.path + "/files/old.md"
        indexer.crawler.isDataless = { [old] info in
            var mine = stat()
            return lstat(old, &mine) == 0 && mine.st_ino == info.st_ino
        }
        let report = try indexer.sync([scratch.path + "/files"])
        #expect(report.removed == 0)
        #expect(try store.item(path: old)?.state == "done")
        #expect(try Searcher(store: store).search("旧笔记").hits.first?.title == "old.md")
    }

    @Test("A-12: a subfolder that can't be listed any more keeps its items")
    func unreadableSubfolder() throws {
        let (scratch, store, indexer) = try library()
        let sub = scratch.path + "/files/sub"
        chmod(sub, 0o000)
        defer { chmod(sub, 0o755) }
        #expect(try indexer.sync([scratch.path + "/files"]).removed == 0)
        #expect(try indexer.sync([scratch.path + "/files"], changed: [sub]).removed == 0)
        #expect(try store.item(path: sub + "/inside.md") != nil)
    }

    @Test("A-21: a walk asked to stop ends, and removes nothing")
    func stoppedWalk() throws {
        let (scratch, store, indexer) = try library()
        try FileManager.default.removeItem(atPath: scratch.path + "/files/new.md")
        indexer.crawler.shouldStop = { true }
        #expect(throws: CancellationError.self) { try indexer.sync([scratch.path + "/files"]) }
        #expect(try store.item(path: scratch.path + "/files/new.md") != nil)
    }

    @Test("A-06: credential names written together, exports, mnemonic words, and folders named for them")
    func credentialNames() {
        for name in ["MyPasswords.txt", "WiFiPassword.txt", "银行password.txt", "1PasswordExport-2026.csv", "logins.csv",
                     "bitwarden_export_20261001.csv", "mnemonic.txt", "seed words.txt", "钱包助记词.md"] {
            #expect(Rules.isCredentialFile(name), "\(name)")
        }
        for name in ["Key dates.md", "Token economics.pdf", "secretary notes.md", "passport scan.pdf", "会议纪要.md"] {
            #expect(!Rules.isCredentialFile(name), "\(name)")
        }
        let home = "/home/x"
        #expect(Rules.skipReason(folder: URL(fileURLWithPath: "/home/x/密码"), home: home, excluded: []) == "credential folder")
        #expect(Rules.skipReason(folder: URL(fileURLWithPath: "/home/x/Passwords"), home: home, excluded: []) == "credential folder")
        #expect(Rules.skipReason(folder: URL(fileURLWithPath: "/home/x/Projects"), home: home, excluded: []) == nil)
    }

    @Test("A-08: a small workbook whose string is used thousands of times can't make gigabytes of text")
    func amplifiedWorkbook() throws {
        let scratch = try Scratch()
        let big = String(repeating: "很长的单元格", count: 20_000)   // 120 000 characters, cut to 32 767
        let rows = (0..<400).map { _ in ["s:0", "s:0", "s:0"] }
        let file = try scratch.write("放大.xlsx", data: ZipWriter.xlsx(sheet: "表", shared: [big], rows: rows))
        let reading = Reader.read(file, kind: .doc)
        #expect(reading.outcome == .done)
        #expect(reading.pieces.count <= Reader.maxChunks)
        #expect(reading.pieces.reduce(0) { $0 + $1.text.count } <= Reader.maxText + Reader.maxChunks * 200)
        #expect(reading.pieces.allSatisfy { $0.text.count <= 1800 })
    }

    @Test("C-21: a folder named relative to home, with a trailing slash, is the same folder")
    func relativeFolders() {
        #expect(Settings.folder(named: "Documents/工作/", home: "/home/x") == "/home/x/Documents/工作")
    }
}

struct ReviewSettingsTests {
    @Test("A-05: a settings file missing a key is read; one that can't be read is never taken for 'nothing chosen'")
    func unreadableSettings() throws {
        let scratch = try Scratch()
        let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        try data.prepare()
        try Data(#"{"folders": ["/tmp/a"]}"#.utf8).write(to: data.settingsFile)
        let partial = try #require(Settings.read(data))
        #expect(partial.folders == ["/tmp/a"] && partial.photos == false && partial.onBattery == false)
        try Data("{not json".utf8).write(to: data.settingsFile)
        #expect(Settings.read(data) == nil)
        try Data(#"{"plans": [], "first_pass_done": 5}"#.utf8).write(to: data.stateFile)
        #expect(ToolState.load(data).firstPassDone == 5)   // "closed" missing: still read
        // With an index already built, a first pass and the resident leave it alone.
        try scratch.write("files/a.md", "# 甲\n内容。")
        let store = try IndexStore(directory: data, home: scratch.path)
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        _ = try indexer.sync([scratch.path + "/files"])
        try indexer.readPending()
        let report = try FirstPass(directory: data, store: store, hub: nil).run()
        #expect(report.unreadableSettings)
        #expect(try store.counts().items["doc"] == 1)
        // Plans can't be made or carried out on it either: they'd write the defaults over it.
        let service = try SearchService(directory: data, hub: nil, opener: Opened().opener, home: scratch.path)
        #expect(throws: ToolFailure.self) { try service.plan(SearchService.Change()) }
    }
}

extension ReadsPictures {
    struct ReviewResidentTests {
        /// A data directory whose settings search `files/` (two notes).
        func folder() throws -> (Scratch, DataDirectory) {
            let scratch = try Scratch()
            try scratch.write("files/甲.md", "# 甲\n第一份。")
            try scratch.write("files/乙.md", "# 乙\n第二份。")
            let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
            var settings = Settings()
            settings.folders = [scratch.path + "/files"]
            try settings.save(data)
            return (scratch, data)
        }

        @Test("B-01: vectors luoke-core couldn't give at first are filled in later, with nothing changed")
        func vectorsLater() throws {
            let (scratch, data) = try folder()
            let fake = try FakeHub()
            fake.status = "downloading"
            let resident = try Resident(directory: data, hub: Hub(socket: fake.path, environment: [:]))
            resident.readsBacklog = false
            resident.vectorsEvery = 0.5
            resident.start()
            defer { resident.stop() }
            let store = try IndexStore(directory: data, home: scratch.path)
            #expect(eventually { (try? store.counts().items["doc"]) == 2 })
            #expect(try store.counts().vectors == 0)
            fake.status = "available"
            #expect(eventually { (try? store.counts().waitingForVectors) == 0 })
            #expect(try store.counts().vectors > 0)
        }

        @Test("C-04: a small folder read right away still counts as the first pass done")
        func firstPassNoted() throws {
            let (scratch, data) = try folder()
            let resident = try Resident(directory: data, hub: nil)
            resident.backlogEvery = 3600   // only the reading of new files can note it
            resident.start()
            defer { resident.stop() }
            #expect(eventually { ToolState.load(data).firstPassDone != nil })
            withExtendedLifetime(scratch) {}
        }

        @Test("C-20: settings changed by another process (the command line) are followed")
        func settingsFromElsewhere() throws {
            let (scratch, data) = try folder()
            try scratch.write("more/丙.md", "# 丙\n灯笼节的笔记。")
            let resident = try Resident(directory: data, hub: nil)
            resident.readsBacklog = false
            resident.backlogEvery = 0.5
            resident.start()
            defer { resident.stop() }
            let store = try IndexStore(directory: data, home: scratch.path)
            #expect(eventually { (try? store.counts().items["doc"]) == 2 })
            var settings = Settings.load(data)
            settings.folders.append(scratch.path + "/more")
            try settings.save(data)   // as `luoke-search settings --add-folder` in another process
            #expect(eventually { (try? Searcher(store: store).search("灯笼节").hits.first?.title) == "丙.md" })
        }

        @Test("C-05: Photos allowed in System Settings after a refusal is noticed without a restart")
        func accessGrantedLater() throws {
            let scratch = try Scratch()
            let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
            var settings = Settings()
            settings.photos = true
            try settings.save(data)
            let photos = FakePhotos([.photo("A1", "IMG_1001.HEIC")], access: .denied)
            let resident = try Resident(directory: data, hub: nil, photos: photos)
            resident.readsBacklog = false
            resident.backlogEvery = 0.5
            resident.start()
            defer { resident.stop() }
            let store = try IndexStore(directory: data, home: scratch.path)
            Thread.sleep(forTimeInterval: 1)
            #expect(try store.photoItems().isEmpty)
            photos.access = .allowed
            #expect(eventually { (try? store.item(path: "photos:A1"))??.state == "done" })
        }

        @Test("C-06: a burst of Photos changes is one look at the library")
        func photoBursts() throws {
            let scratch = try Scratch()
            let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
            var settings = Settings()
            settings.photos = true
            try settings.save(data)
            let photos = FakePhotos([.photo("A1", "IMG_1001.HEIC")])
            let resident = try Resident(directory: data, hub: nil, photos: photos)
            resident.readsBacklog = false
            resident.photosQuiet = 0.5
            resident.start()
            defer { resident.stop() }
            let store = try IndexStore(directory: data, home: scratch.path)
            #expect(eventually { (try? store.item(path: "photos:A1"))??.state == "done" })
            let before = photos.listed
            for index in 0..<50 { photos.change { $0.append(.photo("B\(index)", "IMG_\(index).HEIC")) } }
            #expect(eventually { (try? store.photoItems().count) == 51 })
            #expect(photos.listed - before <= 2)
        }

        @Test("A-07: changes that never stop are still handed over, and never-read places don't count")
        func busyFolders() throws {
            let scratch = try Scratch()
            let folder = scratch.path + "/busy"
            try FileManager.default.createDirectory(atPath: folder + "/node_modules/x", withIntermediateDirectories: true)
            let queue = DispatchQueue(label: "test.watch")
            let first = NSLockedCounter()
            let started = Date()
            let handedAt = NSLock()
            var handed: Date?
            let watcher = FolderWatcher(queue: queue, quiet: 0.75, maxWait: 1.5) { paths in
                first.add()
                handedAt.withLock { if handed == nil { handed = Date() } }
            }
            watcher.ignoring = Resident.ignored(skipping: [])
            watcher.watch([Crawler.canonical(folder)])
            defer { watcher.stop() }
            #expect(Resident.ignored(skipping: [])(folder + "/node_modules/x/a.js"))
            #expect(Resident.ignored(skipping: [])("/home/x/Pictures/Photos Library.photoslibrary/database/a"))
            #expect(!Resident.ignored(skipping: [])(folder + "/notes.md"))
            // A file written every 0.3 s for 4 s: never quiet for 0.75 s.
            for index in 0..<14 {
                try Data("\(index)".utf8).write(to: URL(fileURLWithPath: folder + "/log.txt"))
                try Data("\(index)".utf8).write(to: URL(fileURLWithPath: folder + "/node_modules/x/a.js"))
                Thread.sleep(forTimeInterval: 0.3)
            }
            let at = try #require(handedAt.withLock { handed })
            #expect(at.timeIntervalSince(started) < 3.5)   // before the writing stopped (4.2 s)
            #expect(first.value >= 2)
        }
    }
}
