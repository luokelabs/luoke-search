import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import LuokeSearchKit

// Holding up on a real Mac (10-21): a watchdog for reads that run away, long files read a step at a time,
// dataset-like folders passed over. Synthetic files only.

extension Drawn {
    /// A PDF of `pages` text pages (enough characters each not to be taken for a scan); `special` puts a word on a page.
    static func longPDF(pages: Int, special: [Int: String] = [:]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for page in 1...pages {
            context.beginPDFPage(nil)
            var lines = (0..<4).map { _ in "这是一本很长的手册里的一页，讲的是日常的事情和一些说明，内容没有什么特别的地方。" }
            lines.insert("第 \(page) 页", at: 0)
            if let word = special[page] { lines.append("这一页提到了\(word)。") }
            draw(lines, in: context, top: 780, size: 14)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A small JPEG that says which camera took it (EXIF), as a phone's or a camera's photos do.
    static func cameraJPEG() -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        let camera: [CFString: Any] = [kCGImagePropertyTIFFMake: "Synthetic", kCGImagePropertyTIFFModel: "Test 1"]
        CGImageDestinationAddImage(destination, picture(["相机"], width: 64, height: 48, size: 12),
                                   [kCGImagePropertyTIFFDictionary: camera] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A text long enough to be read in steps (more than 40 chunks); `special` is in it near the end.
    static func longText(special: String = "蝾螈") -> String {
        var text = ""
        for index in 0..<4000 {
            text += "这是一份很长的笔记里的一段话，记的是日常的事情。" + (index == 3500 ? "这里提到了\(special)。" : "") + "\n"
        }
        return text
    }
}

/// Where an item's segments of `kind` are (pages or chunk numbers), in order.
func places(_ store: IndexStore, _ path: String, kind: String) throws -> [Int] {
    var out: [Int] = []
    try store.db.query("""
        SELECT s.loc FROM segments s JOIN items i ON i.id = s.item WHERE i.path = ? AND s.kind = ? ORDER BY s.loc
        """, [.text(path), .text(kind)]) { out.append(Int($0.double(0))) }
    return out
}

struct WatchdogTests {
    @Test("Watchdog: every read is watched while it lasts")
    func readsAreWatched() throws {
        let scratch = try Scratch()
        try scratch.write("files/a.md", "# 甲\n内容。")
        let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        let store = try IndexStore(directory: data, home: scratch.path)
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        _ = try indexer.sync([scratch.path + "/files"])
        let watchdog = ReadWatchdog(directory: data, timeLimit: 0)
        indexer.watchdog = watchdog
        var watched: [String] = []
        indexer.read = { item, _, _ in
            watched.append(watchdog.check()?.path ?? "not watched")
            return Reading()
        }
        try indexer.readPending()
        #expect(watched == [scratch.path + "/files/a.md"])
        #expect(watchdog.check() == nil)   // over once it's stored
    }

    @Test("Watchdog: a read past the time limit or the memory limit is stopped, the file noted")
    func limits() throws {
        let scratch = try Scratch()
        let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        let slow = ReadWatchdog(directory: data, memoryLimit: 1 << 40, timeLimit: 0)
        #expect(slow.check() == nil)   // nothing being read: nothing to stop
        slow.begin("/x/书.pdf")
        Thread.sleep(forTimeInterval: 0.05)
        #expect(slow.check() == ReadWatchdog.Stopped(path: "/x/书.pdf", why: "reading it took more than 0 seconds"))
        slow.end()
        #expect(slow.check() == nil)
        let big = ReadWatchdog(directory: data, memoryLimit: 4 << 30, timeLimit: 3600)
        var memory: UInt64 = 1 << 30
        big.footprint = { memory }
        big.begin("/x/大.pdf")
        memory = 5 << 30
        #expect(big.check()?.why == "reading it needed more than 4 GB of memory")
        #expect(ReadWatchdog.defaultMemoryLimit >= 4 << 30 && ReadWatchdog.defaultMemoryLimit <= 8 << 30)
    }

    @Test("Watchdog: it writes the file down and stops; the next run marks it unreadable until it changes")
    func stoppedFileIsNoted() throws {
        let scratch = try Scratch()
        let file = try scratch.write("files/卡住.md", "# 卡住\n读它会卡住。")
        let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        let store = try IndexStore(directory: data, home: scratch.path)
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        _ = try indexer.sync([scratch.path + "/files"])
        // The process reading it: the watchdog sees the read run past its limit and stops it.
        let watchdog = ReadWatchdog(directory: data, timeLimit: 0.2, checkEvery: 0.05)
        let stopped = NSLockedCounter()
        watchdog.onStop = { _ in stopped.add() }
        watchdog.start()
        let item = try #require(try store.item(path: file.path))
        try store.startReading(item.id)   // as the real read began
        watchdog.begin(item.path)
        #expect(eventually(5) { stopped.value == 1 })
        #expect(FileManager.default.fileExists(atPath: ReadWatchdog.location(data).path))
        // The next run: the note marks the file, once.
        let next = Indexer(store: store, crawler: Crawler(home: scratch.path))
        try next.noteStopped(data)
        let marked = try #require(try store.item(path: file.path))
        #expect(marked.state == "failed")
        #expect(!FileManager.default.fileExists(atPath: ReadWatchdog.location(data).path))
        #expect(try store.pending(limit: 10).isEmpty)
        // Changed: read again.
        try scratch.write("files/卡住.md", "# 好了\n这次读得完。")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        _ = try next.sync([scratch.path + "/files"])
        #expect(try store.item(path: file.path)?.state == "pending")
    }
}

extension ReadsPictures {
    struct LongFileTests {
        @Test("Long PDF: the first 30 pages with the first pass, the rest 30 at a time after it")
        func longPDF() throws {
            let scratch = try Scratch()
            let pdf = try scratch.write("files/手册.pdf", data: Drawn.longPDF(pages: 120, special: [100: "鸭嘴兽"]))
            let store = try scratch.store()
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([scratch.path + "/files"])
            try indexer.readPending()
            #expect(try places(store, pdf.path, kind: "page") == Array(1...30))
            #expect(try store.item(path: pdf.path)?.state == "partial")
            #expect(try store.counts().waitingForRest == 1 && store.counts().waitingToRead == 0)
            let searcher = Searcher(store: store)
            #expect(try searcher.search("鸭嘴兽").hits.isEmpty)
            // Stopped after one step: it goes on from there next time.
            var steps = 0
            try indexer.readRest(shouldStop: { steps >= 1 }, progress: { _ in steps += 1 })
            #expect(try store.info(of: try #require(try store.item(path: pdf.path)).id)["read_to"] == "60")
            #expect(try indexer.readRest() == 2)
            #expect(try places(store, pdf.path, kind: "page") == Array(1...120))
            #expect(try store.item(path: pdf.path)?.state == "done")
            #expect(try store.counts().waitingForRest == 0)
            #expect(try searcher.search("鸭嘴兽").hits.first?.where?.page == 100)
            // A new edition: read from the start again.
            try scratch.write("files/手册.pdf", data: Drawn.longPDF(pages: 60))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: pdf.path)
            _ = try indexer.sync([scratch.path + "/files"])
            try indexer.readPending()
            #expect(try places(store, pdf.path, kind: "page") == Array(1...30))
            try indexer.readRest()
            #expect(try places(store, pdf.path, kind: "page") == Array(1...60))
        }

        @Test("Long document: 40 chunks with the first pass, the rest after; a short one whole")
        func longDocument() throws {
            let scratch = try Scratch()
            let paragraph = "这是一份很长的笔记里的一段话，记的是日常的事情。"
            var text = ""
            for index in 0..<4000 { text += paragraph + (index == 3500 ? "这里提到了蝾螈。" : "") + "\n" }
            let file = try scratch.write("files/长笔记.txt", text)
            try scratch.write("files/短笔记.txt", "短短的一份笔记。")
            let store = try scratch.store()
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([scratch.path + "/files"])
            try indexer.readPending()
            #expect(try places(store, file.path, kind: "text") == Array(1...40))
            #expect(try store.item(path: scratch.path + "/files/短笔记.txt")?.state == "done")
            let total = Int(try store.info(of: try #require(try store.item(path: file.path)).id)["chunks"] ?? "") ?? 0
            #expect(total > 40)
            try indexer.readRest()
            #expect(try places(store, file.path, kind: "text") == Array(1...total))
            #expect(try Searcher(store: store).search("蝾螈").hits.first?.title == "长笔记.txt")
        }

        @Test("First pass: the rest of long files once every file has been read once")
        func firstPassFinishesLongFiles() throws {
            let scratch = try Scratch()
            let pdf = try scratch.write("files/手册.pdf", data: Drawn.longPDF(pages: 70))
            let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
            var settings = Settings()
            settings.folders = [scratch.path + "/files"]
            try settings.save(data)
            let store = try IndexStore(directory: data, home: scratch.path)
            let report = try FirstPass(directory: data, store: store, hub: nil).run()
            #expect(report.read == 1 && report.restSteps == 2)
            #expect(try places(store, pdf.path, kind: "page") == Array(1...70))
            #expect(ToolState.load(data).firstPassDone != nil)
        }
    }
}

struct DatasetTests {
    @Test("Machine-made names, and camera names that only look like them")
    func machineNames() {
        for name in ["000123", "frame_0042", "clip-000123", "3f9a1c0e", "3f9a1c0e-4b2d-11ee", "sample.0001"] {
            #expect(Rules.looksMachineNamed(name), "\(name)")
        }
        for name in ["IMG_1234", "DSC01234", "PXL_20231011_123456", "MVIMG_20230101_120000", "假期", "holiday photos",
                     "Screenshot 2026-10-01 at 10.00.00", "VID_20260918"] {
            #expect(!Rules.looksMachineNamed(name), "\(name)")
        }
    }

    @Test("A folder of hundreds of machine-named pictures is passed over and reported; a camera roll and a chosen folder are not")
    func datasetFolders() throws {
        let scratch = try Scratch()
        for index in 0..<320 {
            try scratch.write("files/data/frames/\(String(format: "%06d", index)).jpg", data: Data([0xFF]))
            try scratch.write("files/data/相机/IMG_\(String(format: "%04d", index)).jpg", data: Data([0xFF]))
            try scratch.write("chosen/\(String(format: "%06d", index)).png", data: Data([0x89]))
        }
        try scratch.write("files/data/frames/说明.md", "这些帧是从视频里导出来的。")
        let store = try scratch.store()
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        let report = try indexer.sync([scratch.path + "/files", scratch.path + "/chosen"])
        let frames = scratch.path + "/files/data/frames"
        #expect(report.datasets == [frames: 320])
        #expect(report.skipped["dataset-like folder"] == 320)
        #expect(try store.items(under: [frames]).map { ($0.path as NSString).lastPathComponent } == ["说明.md"])
        #expect(try store.items(under: [scratch.path + "/files/data/相机"]).count == 320)
        #expect(try store.items(under: [scratch.path + "/chosen"]).count == 320)
        #expect(try store.datasetFolders() == [frames: 320])
        // A frame that changed later is passed over too.
        try scratch.write("files/data/frames/000999.jpg", data: Data([0xFF]))
        let changed = try indexer.sync([scratch.path + "/files"], changed: [frames + "/000999.jpg"])
        #expect(changed.added == 0)
        // And search_status says so.
        let service = try SearchService(directory: DataDirectory(url: scratch.url.appendingPathComponent("data")),
                                        hub: nil, opener: Opened().opener, home: scratch.path)
        let status = try service.status()
        #expect((status["dataset_folders"] as? [[String: Any]])?.first?["files"] as? Int == 320)
    }
}

/// The review of the robustness branch (D-1 … D-11): each a case that went wrong before.
extension ReadsPictures {
    struct RobustnessReviewTests {
        /// A long text read with the first pass, its rest waiting. (The folder lives as long as this does.)
        struct HalfRead {
            let scratch: Scratch
            let store: IndexStore
            let indexer: Indexer
            let file: URL

            init() throws {
                scratch = try Scratch()
                file = try scratch.write("files/长笔记.txt", Drawn.longText())
                store = try scratch.store()
                indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
                _ = try indexer.sync([scratch.path + "/files"])
                try indexer.readPending()
                #expect(try store.item(path: file.path)?.state == "partial")
            }
        }

        func detail(_ store: IndexStore, _ path: String) throws -> String? {
            var out: String?
            try store.db.query("SELECT detail FROM items WHERE path = ?", [.text(path)]) { out = $0.text(0) }
            return out
        }

        @Test("D-1: a step of a long file that ended the process twice (nothing noted) is given up on; one stored starts the count again")
        func restThatEndsTheProcess() throws {
            let half = try HalfRead()
            let (store, indexer, file) = (half.store, half.indexer, half.file)
            let item = try #require(try store.item(path: file.path))
            try store.startReading(item.id)   // a step begun, and the process ended (a crash: no note)
            try indexer.readRest(shouldStop: { false }, progress: { _ in })
            #expect(try store.item(path: file.path)?.state == "done")
            #expect(try store.item(path: file.path)?.attempts == 0)
            // Again, with a file that ends it twice: what was read stays, the rest waits until the file changes.
            let half2 = try HalfRead()
            let (store2, indexer2, file2) = (half2.store, half2.indexer, half2.file)
            let item2 = try #require(try store2.item(path: file2.path))
            try store2.startReading(item2.id)
            try store2.startReading(item2.id)
            var read = 0
            indexer2.read = { _, _, _ in read += 1; return Reading() }
            #expect(try indexer2.readRest() == 0)
            #expect(read == 0)
            #expect(try store2.item(path: file2.path)?.state == "done")
            #expect(try detail(store2, file2.path) == "the rest couldn't be read: reading it ended the process")
            #expect(try places(store2, file2.path, kind: "text") == Array(1...40))
        }

        @Test("D-1, D-7: the note stays until it's in the index; a version changed since isn't blamed")
        func noteIsKeptAndVersioned() throws {
            let scratch = try Scratch()
            let file = try scratch.write("files/卡住.md", "# 卡住\n读它会卡住。")
            let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
            let store = try IndexStore(directory: data, home: scratch.path)
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([scratch.path + "/files"])
            let item = try #require(try store.item(path: file.path))
            let old = ReadWatchdog.Stopped(path: item.path, why: "reading it took more than 15 minutes",
                                           mtime: item.mtime - 60, size: item.size)
            try FileManager.default.createDirectory(at: ReadWatchdog.location(data).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(old).write(to: ReadWatchdog.location(data))
            #expect(ReadWatchdog.stopped(data) == old)
            #expect(ReadWatchdog.stopped(data) == old)   // looking leaves it
            try indexer.noteStopped(data)
            #expect(try store.item(path: file.path)?.state == "pending")   // another version: read like any other
            #expect(ReadWatchdog.stopped(data) == nil)
        }

        @Test("D-2: time the Mac sleeps isn't time a read took")
        func sleepDoesNotCount() throws {
            let scratch = try Scratch()
            let watchdog = ReadWatchdog(directory: DataDirectory(url: scratch.url), memoryLimit: 1 << 40, timeLimit: 60)
            var awake: UInt64 = 0
            watchdog.awake = { awake }
            watchdog.begin("/x/书.pdf")
            awake = 59_000_000_000   // a night asleep and 59 s awake
            #expect(watchdog.check() == nil)
            awake = 61_000_000_000
            #expect(watchdog.check()?.why == "reading it took more than 60 seconds")
        }

        @Test("D-8: memory the process held before a read began isn't blamed on that file")
        func memoryHeldBefore() throws {
            let scratch = try Scratch()
            let watchdog = ReadWatchdog(directory: DataDirectory(url: scratch.url), memoryLimit: 4 << 30, timeLimit: 3600)
            var memory: UInt64 = (4 << 30) + (512 << 20)
            watchdog.footprint = { memory }
            watchdog.begin("/x/下一个.pdf")
            memory = 5 << 30
            #expect(watchdog.check() == nil)
            memory = 7 << 30   // this read grew it by 2.5 GB
            #expect(watchdog.check()?.path == "/x/下一个.pdf")
        }

        @Test("D-4: a step two processes both read is stored once")
        func stepStoredOnce() throws {
            let half = try HalfRead()
            let (store, file) = (half.store, half.file)
            let item = try #require(try store.item(path: file.path))
            let step = Reader.read(file, kind: .doc, from: 41)
            let end = try #require(step.pieces.last?.loc.map { Int($0) })
            #expect(end > 41)
            #expect(try store.storeMore(step, for: item, from: 41))
            #expect(try !store.storeMore(step, for: item, from: 41))
            #expect(try places(store, file.path, kind: "text") == Array(1...end))
        }

        @Test("D-11: what a step says adds up (scanned pages), and an empty step doesn't call the file empty")
        func stepInfo() throws {
            let half = try HalfRead()
            let (store, file) = (half.store, half.file)
            let item = try #require(try store.item(path: file.path))
            var first = Reading()
            first.info = ["scanned_pages": "3"]
            first.readTo = 45
            #expect(try store.storeMore(first, for: item, from: 41))
            var last = Reading()
            last.info = ["scanned_pages": "2", "empty": "1"]
            #expect(try store.storeMore(last, for: item, from: 46))
            let info = try store.info(of: item.id)
            #expect(info["scanned_pages"] == "5" && info["empty"] == nil && info["read_to"] == nil)
            #expect(try store.item(path: file.path)?.state == "done")
        }

        @Test("D-5: a search says when long files aren't read to the end yet")
        func searchSaysLongFilesWait() throws {
            let half = try HalfRead()
            let (store, indexer) = (half.store, half.indexer)
            let answer = try Searcher(store: store).search("蝾螈")
            #expect(answer.hits.isEmpty)
            #expect(answer.partial && answer.partialReason == "还有 1 个长文件没读完，结果可能不全")
            try indexer.readRest()
            #expect(try Searcher(store: store).search("蝾螈").partialReason == "这次只按字词搜")
        }

        @Test("D-6: the rest of a file on an unplugged drive, or moved off to iCloud, waits; it isn't read as gone")
        func restOfFilesAway() throws {
            let half = try HalfRead()
            let (scratch, store, indexer, file) = (half.scratch, half.store, half.indexer, half.file)
            let away = scratch.url.appendingPathComponent("拔掉的盘.txt")
            try FileManager.default.moveItem(at: file, to: away)
            #expect(try indexer.readRest() == 0)
            #expect(try store.item(path: file.path)?.state == "partial")
            try FileManager.default.moveItem(at: away, to: file)
            indexer.crawler.isDataless = { _ in true }
            var read = 0
            #expect(try indexer.readRest(progress: { _ in read += 1 }) == 0)
            #expect(try store.item(path: file.path)?.state == "partial")
            indexer.crawler.isDataless = { _ in false }
            #expect(try indexer.readRest() > 0)
            #expect(try store.item(path: file.path)?.state == "done")
        }
    }
}

extension DatasetTests {
    @Test("D-3: names cameras, phones and apps give aren't machine-made")
    func cameraNames() {
        for name in ["20231015_143022", "P1010001", "PA150001", "C0001", "MVI_1234", "GH010001", "GX010001", "100_0001",
                     "Voice 001", "signal-2023-10-15-143022", "Wedding_0001", "Scan 0001"] {
            #expect(!Rules.looksMachineNamed(name), "\(name)")
        }
    }

    @Test("D-3: hundreds of pictures with numbers for names that say which camera took them are a camera's")
    func cameraFolder() throws {
        let scratch = try Scratch()
        let photo = Drawn.cameraJPEG()
        for index in 0..<320 { try scratch.write("files/导出/\(String(format: "%06d", index)).jpg", data: photo) }
        let store = try scratch.store()
        let report = try Indexer(store: store, crawler: Crawler(home: scratch.path)).sync([scratch.path + "/files"])
        #expect(report.datasets.isEmpty)
        #expect(try store.items(under: [scratch.path + "/files/导出"]).count == 320)
    }

    @Test("D-9: the ._ files macOS leaves on other drives don't count")
    func appleDouble() throws {
        let scratch = try Scratch()
        for index in 0..<300 {
            let name = String(format: "%06d", index)
            try scratch.write("files/盘/frames/\(name).jpg", data: Data([0xFF]))
            try scratch.write("files/盘/frames/._\(name).jpg", data: Data([0x00]))
        }
        let report = try Indexer(store: try scratch.store(), crawler: Crawler(home: scratch.path)).sync([scratch.path + "/files"])
        #expect(report.datasets == [scratch.path + "/files/盘/frames": 300])
    }

    @Test("D-10: a folder the user chose isn't listed as a dataset; folders outside a walk keep their entry")
    func datasetList() throws {
        let scratch = try Scratch()
        for index in 0..<300 { try scratch.write("files/frames/\(String(format: "%06d", index)).jpg", data: Data([0xFF])) }
        try scratch.write("other/说明.md", "别的文件夹。")
        let store = try scratch.store()
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        let frames = scratch.path + "/files/frames"
        let nested = try indexer.sync([scratch.path + "/files", frames])
        #expect(try nested.datasets.isEmpty && store.datasetFolders().isEmpty)
        #expect(try store.items(under: [frames]).count == 300)
        _ = try indexer.sync([scratch.path + "/files"])
        #expect(try store.datasetFolders() == [frames: 300])
        _ = try indexer.sync([scratch.path + "/other"])
        #expect(try store.datasetFolders() == [frames: 300])
    }
}
