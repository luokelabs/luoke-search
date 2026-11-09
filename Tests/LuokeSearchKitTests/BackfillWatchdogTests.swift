import CoreGraphics
import Foundation
import Testing
@testable import LuokeSearchKit

// Filling in vectors is watched as reading is (10-22: the gap PR #14 left): a file whose pictures or sound
// can't be made again stops the process, written down; the next start gives up only its pictures and sound and goes
// on with the rest. Synthetic files only.
extension Drawn {
    /// A PDF of `pages` pages with next to no text: each is taken for a scan, and waits for its picture's vector.
    static func scanPDF(pages: Int) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for page in 1...pages {
            context.beginPDFPage(nil)
            draw(["第 \(page) 页"], in: context, top: 150, size: 20)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}

extension ReadsPictures {
    struct BackfillWatchdogTests {
        @Test("Backfill watchdog: the step is watched, its stage and why say so, awake time only")
        func limits() throws {
            let scratch = try Scratch()
            let watchdog = ReadWatchdog(directory: DataDirectory(url: scratch.url), memoryLimit: 4 << 30, timeLimit: 60)
            var awake: UInt64 = 0
            watchdog.awake = { awake }
            watchdog.begin("/x/视频.mp4", stage: ReadWatchdog.media)
            awake = 59_000_000_000   // a night asleep and 59 s awake
            #expect(watchdog.check() == nil)
            awake = 61_000_000_000
            let stopped = watchdog.check()
            #expect(stopped?.why == "making its pictures and sound for vectors took more than 60 seconds")
            #expect(stopped?.stage == ReadWatchdog.media)
            var memory: UInt64 = 1 << 30
            watchdog.footprint = { memory }
            watchdog.begin("/x/扫描件.pdf", stage: ReadWatchdog.media)
            memory = 5 << 30
            #expect(watchdog.check()?.why == "making its pictures and sound for vectors needed more than 4 GB of memory")
            watchdog.end()
            #expect(watchdog.check() == nil)
            // A note from before stages were written down reads as one from reading.
            let old = try JSONDecoder().decode(ReadWatchdog.Stopped.self,
                                               from: Data(#"{"path": "/x/书.pdf", "why": "reading it took more than 15 minutes"}"#.utf8))
            #expect(old.stage == nil)
        }

        @Test("Backfill watchdog: paused while pictures are sent, a step's time at a time, the file's memory from its start")
        func pausesAndSteps() throws {
            let scratch = try Scratch()
            let watchdog = ReadWatchdog(directory: DataDirectory(url: scratch.url), memoryLimit: 4 << 30, timeLimit: 60)
            var awake: UInt64 = 0, memory: UInt64 = 1 << 30
            watchdog.awake = { awake }
            watchdog.footprint = { memory }
            watchdog.begin("/x/扫描件.pdf", stage: ReadWatchdog.media)
            awake = 40_000_000_000
            watchdog.pause()                     // sending: an hour waiting on luoke-core isn't the file's
            awake += 3_600_000_000_000
            #expect(watchdog.check() == nil)
            watchdog.resume()
            awake += 15_000_000_000              // 40 + 15 s working
            #expect(watchdog.check() == nil)
            awake += 10_000_000_000              // 65 s working
            #expect(watchdog.check()?.why == "making its pictures and sound for vectors took more than 60 seconds")
            watchdog.newStep()                   // the next step's time starts again
            #expect(watchdog.check() == nil)
            // Memory: each picture adds a little, none half the limit; the file's growth adds up and is caught.
            var caught: ReadWatchdog.Stopped?
            for _ in 0..<10 where caught == nil {
                watchdog.resume()
                memory += 600 << 20
                watchdog.pause()
                caught = watchdog.check()            // sending, or between pictures: still the file's memory
            }
            #expect(caught?.why == "making its pictures and sound for vectors needed more than 4 GB of memory")
            // Reading a file is never paused: as before.
            watchdog.begin("/x/书.pdf")
            awake += 61_000_000_000
            #expect(watchdog.check()?.why == "reading it took more than 60 seconds")
        }

        @Test("Backfill watchdog: given up on, a long file's later steps don't wait for pictures either")
        func longFiles() throws {
            let scratch = try Scratch()
            let given = try scratch.write("files/长扫描件.pdf", data: Drawn.scanPDF(pages: 60))
            let other = try scratch.write("files/另一本.pdf", data: Drawn.scanPDF(pages: 60))
            let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
            let store = try IndexStore(directory: data, home: scratch.path)
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([scratch.path + "/files"])
            try indexer.readPending()
            func waiting(_ path: String) throws -> Int {
                try Int(store.db.scalarInt("""
                    SELECT count(*) FROM segments s JOIN items i ON i.id = s.item WHERE i.path = ? AND s.todo = 'media'
                    """, [.text(path)]))
            }
            func detail(_ path: String) throws -> String? {
                var out: String?
                try store.db.query("SELECT detail FROM items WHERE path = ?", [.text(path)]) { out = $0.text(0) }
                return out
            }
            let item = try #require(try store.item(path: given.path))
            #expect(item.state == "partial")
            #expect(try waiting(given.path) == Reader.pdfStep)   // the first step's page pictures
            // A process stopped making its pictures; the next start gives them up.
            let why = "making its pictures and sound for vectors took more than 15 minutes"
            try FileManager.default.createDirectory(at: ReadWatchdog.location(data).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(ReadWatchdog.Stopped(path: item.path, why: why, mtime: item.mtime, size: item.size,
                                                          stage: ReadWatchdog.media)).write(to: ReadWatchdog.location(data))
            try indexer.noteStopped(data)
            #expect(try waiting(given.path) == 0)
            // The rest read: its pages are searchable, their pictures don't wait; the other file's do.
            try indexer.readRest()
            #expect(try store.item(path: given.path)?.state == "done")
            #expect(try places(store, given.path, kind: "page").count == 60)
            #expect(try waiting(given.path) == 0)
            #expect(try detail(given.path) == "its pictures and sound get no vectors: " + why)
            #expect(try waiting(other.path) == 60)
            withExtendedLifetime(scratch) {}
        }

        @Test("Backfill watchdog: a file whose pictures each add a little memory is caught, though none adds half the limit")
        func memoryAcrossPictures() throws {
            let scratch = try Scratch()
            let file = try scratch.write("files/越读越大.pdf", data: Drawn.scanPDF(pages: 12))
            let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
            let store = try IndexStore(directory: data, home: scratch.path)
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([scratch.path + "/files"])
            try indexer.readPending()
            let fake = try FakeHub()
            fake.takesMedia = true
            let memory = NSLockedCounter()       // GB/2: each page made adds half a GB
            let watchdog = ReadWatchdog(directory: data, memoryLimit: 4 << 30, timeLimit: 3600, checkEvery: 0.02)
            watchdog.footprint = { UInt64(1 << 30) + UInt64(memory.value) * (512 << 20) }
            let stopped = NSLockedCounter()
            watchdog.onStop = { _ in stopped.add() }
            watchdog.start()
            let filler = VectorFiller(store: store, hub: Hub(socket: fake.path, environment: [:]))
            filler.watchdog = watchdog
            filler.next = { source in
                memory.add()
                Thread.sleep(forTimeInterval: 0.05)
                return source.next()
            }
            _ = filler.run(wait: false, shouldStop: { stopped.value > 0 })
            #expect(stopped.value == 1)
            let note = try #require(ReadWatchdog.stopped(data))
            #expect(note.path == file.path)
            #expect(note.why == "making its pictures and sound for vectors needed more than 4 GB of memory")
            withExtendedLifetime(fake) {}
        }

        @Test("Backfill crashes: a file whose pictures ended the process twice (nothing written down) is given up on; the rest go on")
        func crashedTwice() throws {
            let scratch = try Scratch()
            let crashing = try scratch.write("files/崩溃的扫描件.pdf", data: Drawn.scanPDF(pages: 3))
            let fine = try scratch.write("files/好好的扫描件.pdf", data: Drawn.scanPDF(pages: 3))
            let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
            let store = try IndexStore(directory: data, home: scratch.path)
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([scratch.path + "/files"])
            try indexer.readPending()
            func waiting(_ path: String) throws -> Int {
                try Int(store.db.scalarInt("""
                    SELECT count(*) FROM segments s JOIN items i ON i.id = s.item WHERE i.path = ? AND s.todo = 'media'
                    """, [.text(path)]))
            }
            func info(_ path: String) throws -> [String: String] { try store.info(of: try #require(try store.item(path: path)).id) }
            let item = try #require(try store.item(path: crashing.path))
            // Two runs began making its pictures and the process died each time: the count stays, no note.
            #expect(try store.startMedia(item.id) == 0)
            #expect(try store.startMedia(item.id) == 1)
            #expect(ReadWatchdog.stopped(data) == nil)
            let fake = try FakeHub()
            fake.takesMedia = true
            let filler = VectorFiller(store: store, hub: Hub(socket: fake.path, environment: [:]))
            var opened: [String] = []
            filler.next = { source in opened.append(source.path); return source.next() }
            let report = filler.run(wait: false)
            #expect(!opened.contains(crashing.path))           // not tried a third time
            #expect(try waiting(crashing.path) == 0)
            #expect(try store.item(path: crashing.path)?.state == "done")
            var detail: String?
            try store.db.query("SELECT detail FROM items WHERE path = ?", [.text(crashing.path)]) { detail = $0.text(0) }
            #expect(detail == "its pictures and sound get no vectors: making them ended the process 2 times")
            #expect(try info(crashing.path)[IndexStore.mediaTries] == nil)
            #expect(report.embeddedMedia == 3)                 // the other file's three pages
            #expect(try waiting(fine.path) == 0)
            #expect(try info(fine.path)[IndexStore.mediaTries] == nil)   // done: cleared
            withExtendedLifetime(fake) {}
        }

        @Test("Backfill crashes: a run that stops between pictures, or once died, isn't counted against the file")
        func stoppedIsNotCrashed() throws {
            let scratch = try Scratch()
            let file = try scratch.write("files/扫描件.pdf", data: Drawn.scanPDF(pages: 10))
            let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
            let store = try IndexStore(directory: data, home: scratch.path)
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([scratch.path + "/files"])
            try indexer.readPending()
            let item = try #require(try store.item(path: file.path))
            let fake = try FakeHub()
            fake.takesMedia = true
            let hub = Hub(socket: fake.path, environment: [:])
            // Asked to stop after three pictures (a file changed, the slice is up): over, not crashed.
            let first = VectorFiller(store: store, hub: hub)
            var made = 0, countedWhileMaking: [String?] = []
            first.next = { source in
                made += 1
                countedWhileMaking.append(try? store.info(of: item.id)[IndexStore.mediaTries])   // what a crash would leave
                return source.next()
            }
            _ = first.run(wait: false, shouldStop: { made >= 3 })
            #expect(countedWhileMaking == ["1", "1", "1"])
            #expect(try store.info(of: item.id)[IndexStore.mediaTries] == nil)
            // One run died in it: the next one goes on as usual, and clears the count.
            try store.startMedia(item.id)
            let report = VectorFiller(store: store, hub: hub).run(wait: false)
            #expect(report.embeddedMedia == 10)
            #expect(try store.info(of: item.id)[IndexStore.mediaTries] == nil)
            withExtendedLifetime(fake) {}
        }

        @Test("Backfill crashes: a file that crashed twice and waits to be read again is passed over until it is")
        func crashedAndChanged() throws {
            let scratch = try Scratch()
            let file = try scratch.write("files/改过的扫描件.pdf", data: Drawn.scanPDF(pages: 3))
            let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
            let store = try IndexStore(directory: data, home: scratch.path)
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([scratch.path + "/files"])
            try indexer.readPending()
            let id = try #require(try store.item(path: file.path)).id
            try store.startMedia(id)
            try store.startMedia(id)
            // Changed since: it waits to be read again, its old pages still waiting for pictures.
            try scratch.write("files/改过的扫描件.pdf", data: Drawn.scanPDF(pages: 4))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
            _ = try indexer.sync([scratch.path + "/files"])
            #expect(try store.item(path: file.path)?.state == "pending")
            let fake = try FakeHub()
            fake.takesMedia = true
            let hub = Hub(socket: fake.path, environment: [:])
            for _ in 0..<2 {                      // not opened, and still passed over the next time
                let filler = VectorFiller(store: store, hub: hub)
                var opened = 0
                filler.next = { source in opened += 1; return source.next() }
                let report = filler.run(wait: false)
                #expect(opened == 0)
                #expect(report.mediaFailed == 0)  // nothing given up on: it starts afresh once read
            }
            // Read again: a new version, counted afresh, its pictures made.
            try indexer.readPending()
            #expect(try store.info(of: id)[IndexStore.mediaTries] == nil)
            #expect(VectorFiller(store: store, hub: hub).run(wait: false).embeddedMedia == 4)
            withExtendedLifetime(fake) {}
        }

        @Test("Backfill crashes: an item this tier takes none of is passed over without writing anything")
        func nothingTaken() throws {
            let scratch = try Scratch()
            let file = try scratch.write("files/扫描件.pdf", data: Drawn.scanPDF(pages: 2))
            let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
            let store = try IndexStore(directory: data, home: scratch.path)
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([scratch.path + "/files"])
            try indexer.readPending()
            let id = try #require(try store.item(path: file.path)).id
            try store.startMedia(id)              // one crash before: a count that a write would change
            let fake = try FakeHub()
            fake.takesMedia = true
            fake.imageBudgets = [70, 140]         // too small for a page's picture: nothing of it is taken
            let filler = VectorFiller(store: store, hub: Hub(socket: fake.path, environment: [:]))
            var opened = 0
            filler.next = { source in opened += 1; return source.next() }
            _ = filler.run(wait: false)
            #expect(opened == 0)
            #expect(try store.info(of: id)[IndexStore.mediaTries] == "1")   // untouched
            withExtendedLifetime(fake) {}
        }

        @Test("Backfill watchdog: a slow luoke-core isn't blamed on the file")
        func slowHub() throws {
            let scratch = try Scratch()
            // Ten pages: a request's worth (eight) goes out while the file is still being worked on.
            try scratch.write("files/扫描件.pdf", data: Drawn.scanPDF(pages: 10))
            let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
            let store = try IndexStore(directory: data, home: scratch.path)
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([scratch.path + "/files"])
            try indexer.readPending()
            let fake = try FakeHub()
            fake.takesMedia = true
            // Each request takes longer than the watchdog's limit; making a page's picture, well under it (also
            // when the tests run slower, with coverage counted).
            fake.delay = 1.6
            let watchdog = ReadWatchdog(directory: data, timeLimit: 1.0, checkEvery: 0.05)
            let stopped = NSLockedCounter()
            watchdog.onStop = { _ in stopped.add() }
            watchdog.start()
            let filler = VectorFiller(store: store, hub: Hub(socket: fake.path, environment: [:]))
            filler.watchdog = watchdog
            let report = filler.run(wait: false)
            #expect(report.embeddedMedia == 10)
            #expect(fake.inputRequests.count == 2)   // eight while the file was open, then the last two
            #expect(stopped.value == 0)
            withExtendedLifetime(fake) {}
        }

        @Test("Backfill watchdog: a PDF stuck making its page pictures is written down; the next start gives up only its pictures and goes on")
        func stuckFile() throws {
            let scratch = try Scratch()
            let stuck = try scratch.write("files/卡住的合同.pdf",
                                          data: Drawn.pdf(textPage: ["租赁合同的正文", "押金两个月"], scannedPage: ["签字页"]))
            try scratch.write("files/Screenshot 2026-10-22 at 10.00.00.png", data: Drawn.png(Drawn.picture(["付款失败：余额不足"])))
            let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
            let store = try IndexStore(directory: data, home: scratch.path)
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([scratch.path + "/files"])
            try indexer.readPending()
            func waiting(_ path: String) throws -> Int {
                try Int(store.db.scalarInt("""
                    SELECT count(*) FROM segments s JOIN items i ON i.id = s.item WHERE i.path = ? AND s.todo = 'media'
                    """, [.text(path)]))
            }
            func detail() throws -> String? {
                var out: String?
                try store.db.query("SELECT detail FROM items WHERE path = ?", [.text(stuck.path)]) { out = $0.text(0) }
                return out
            }
            #expect(try waiting(stuck.path) == 2)   // each page's picture
            #expect(try store.counts().waitingForMedia == 2)

            let fake = try FakeHub()
            fake.takesMedia = true
            let hub = Hub(socket: fake.path, environment: [:])
            // The process filling vectors: making the PDF's page pictures again never returns, so the watchdog stops it.
            let watchdog = ReadWatchdog(directory: data, timeLimit: 0.3, checkEvery: 0.05)
            let stopped = NSLockedCounter()
            let processEnded = DispatchSemaphore(value: 0)
            watchdog.onStop = { _ in stopped.add(); processEnded.signal() }
            watchdog.start()
            let filler = VectorFiller(store: store, hub: hub)
            filler.watchdog = watchdog
            filler.next = { source in
                guard source.path == stuck.path else { return source.next() }
                _ = processEnded.wait(timeout: .now() + 10)   // stuck until the watchdog ends "the process"
                return nil
            }
            _ = filler.run(wait: false, shouldStop: { stopped.value > 0 })
            #expect(stopped.value == 1)
            let note = try #require(ReadWatchdog.stopped(data))
            #expect(note.path == stuck.path)
            #expect(note.stage == ReadWatchdog.media)
            #expect(note.why == "making its pictures and sound for vectors took more than 0 seconds")

            // The next start: the note gives up the PDF's pictures, once; what was read stays.
            try Indexer(store: store, crawler: Crawler(home: scratch.path)).noteStopped(data)
            #expect(ReadWatchdog.stopped(data) == nil)
            #expect(try waiting(stuck.path) == 0)
            let item = try #require(try store.item(path: stuck.path))
            #expect(item.state == "done")
            #expect(try detail() == "its pictures and sound get no vectors: " + note.why)
            #expect(try Searcher(store: store).search("租赁合同").hits.first?.title == "卡住的合同.pdf")
            // …and filling goes on with the rest, the PDF not opened again.
            let again = VectorFiller(store: store, hub: hub)
            again.watchdog = watchdog
            var opened: [String] = []
            again.next = { source in opened.append(source.path); return source.next() }
            let report = again.run(wait: false)
            #expect(report.embeddedMedia == 1)
            #expect(!opened.contains(stuck.path))
            #expect(try store.counts().waitingForMedia == 0)

            // Changed, it's read again and its pictures wait again.
            try scratch.write("files/卡住的合同.pdf",
                              data: Drawn.pdf(textPage: ["租赁合同的正文", "押金一个月"], scannedPage: ["新的签字页"]))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: stuck.path)
            _ = try indexer.sync([scratch.path + "/files"])
            try indexer.readPending()
            #expect(try waiting(stuck.path) == 2)
            #expect(try detail() == nil)
            withExtendedLifetime(fake) {}
        }
    }
}
