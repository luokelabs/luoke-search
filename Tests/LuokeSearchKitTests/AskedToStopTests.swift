import Foundation
import Testing
@testable import LuokeSearchKit

/// luoke-search#65: luoke-core gives a quitting accessory 15 s, then kills it; a long read (a scanned PDF's step, a
/// long video) can take longer. Killed that way, the read's attempt was counted as the file ending the process, and
/// a file killed twice so was given up on until it changed. Now the file in hand is written down as soon as the quit
/// is asked for (`ReadWatchdog.noteAskedToStop`), and the next run takes that attempt back (`Indexer.noteStopped`).
struct AskedToStopTests {
    struct Folder {
        let scratch: Scratch
        let data: DataDirectory
        let store: IndexStore
        let file: URL

        init(_ name: String = "files/扫描件.md", _ text: String = "# 扫描件\n读得很慢。") throws {
            scratch = try Scratch()
            file = try scratch.write(name, text)
            data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
            store = try IndexStore(directory: data, home: scratch.path)
            _ = try indexer().sync([scratch.path + "/files"])
        }

        /// A run's indexer (the next run's, after a quit).
        func indexer() -> Indexer { Indexer(store: store, crawler: Crawler(home: scratch.path)) }

        func item() throws -> ItemRecord { try #require(try store.item(path: file.path)) }
    }

    @Test("#65: asked to quit while reading a file, and killed before it's read: twice, and the file is still read")
    func killedAfterAQuitIsNotTheFiles() throws {
        let folder = try Folder()
        let item = try folder.item()
        for _ in 0..<2 {
            // A run reading it: asked to quit, then killed 15 s on, the read not done (nothing more happens here).
            let watchdog = ReadWatchdog(directory: folder.data)
            watchdog.begin(item.path, mtime: item.mtime, size: item.size)
            try folder.store.startReading(item.id)
            watchdog.noteAskedToStop()
            #expect(ReadWatchdog.askedToStop(folder.data)?.path == item.path)
            // The next run.
            try folder.indexer().noteStopped(folder.data)
            #expect(try folder.item().attempts == 0)
            #expect(ReadWatchdog.askedToStop(folder.data) == nil)
        }
        #expect(try folder.indexer().readPending() == 1)
        #expect(try folder.item().state == "done")
    }

    @Test("#65: the note is the file being read; one finished before the kill keeps no attempt and loses none")
    func noteIsTheFileInHand() throws {
        let folder = try Folder()
        let indexer = folder.indexer()
        let watchdog = ReadWatchdog(directory: folder.data)
        indexer.watchdog = watchdog
        var attemptsWhileRead: Int?
        indexer.read = { item, _, _ in
            watchdog.noteAskedToStop()   // SIGTERM, while it's read: its attempt already noted
            attemptsWhileRead = try? folder.store.item(path: item.path)?.attempts
            return Reading()
        }
        #expect(try indexer.readPending() == 1)
        #expect(attemptsWhileRead == 1)
        let asked = try #require(ReadWatchdog.askedToStop(folder.data))
        let item = try folder.item()
        #expect(asked == ReadWatchdog.Stopped(path: item.path, why: "asked to stop", mtime: item.mtime, size: item.size))
        #expect(item.state == "done" && item.attempts == 0)
        try folder.indexer().noteStopped(folder.data)
        #expect(try folder.item().attempts == 0)   // nothing taken below nothing
        #expect(try folder.item().state == "done")
        #expect(ReadWatchdog.askedToStop(folder.data) == nil)
    }

    @Test("#65: an earlier crash still counts; only the attempt the quit cut short is taken back")
    func earlierCrashStillCounts() throws {
        let folder = try Folder()
        let item = try folder.item()
        try folder.store.startReading(item.id)   // a crash: no note
        let watchdog = ReadWatchdog(directory: folder.data)
        watchdog.begin(item.path, mtime: item.mtime, size: item.size)
        try folder.store.startReading(item.id)
        watchdog.noteAskedToStop()
        try folder.indexer().noteStopped(folder.data)
        #expect(try folder.item().attempts == 1)
        // One more crash: given up on, as before.
        try folder.store.startReading(item.id)
        #expect(try folder.indexer().readPending() == 1)
        #expect(try folder.item().state == "failed")
    }

    @Test("#65: a version changed since isn't taken back; the watchdog's note of the same file wins")
    func otherVersionsAndTheWatchdog() throws {
        let folder = try Folder()
        let item = try folder.item()
        try folder.store.startReading(item.id)
        try FileManager.default.createDirectory(at: ReadWatchdog.askedLocation(folder.data).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let old = ReadWatchdog.Stopped(path: item.path, why: "asked to stop", mtime: item.mtime - 60, size: item.size)
        try JSONEncoder().encode(old).write(to: ReadWatchdog.askedLocation(folder.data))
        try folder.indexer().noteStopped(folder.data)
        #expect(try folder.item().attempts == 1)
        #expect(ReadWatchdog.askedToStop(folder.data) == nil)
        // The watchdog stopped it (it ran past its limit) after the quit was asked: it's the file's doing.
        let asked = ReadWatchdog.Stopped(path: item.path, why: "asked to stop", mtime: item.mtime, size: item.size)
        try JSONEncoder().encode(asked).write(to: ReadWatchdog.askedLocation(folder.data))
        let stopped = ReadWatchdog.Stopped(path: item.path, why: "reading it took more than 15 minutes",
                                           mtime: item.mtime, size: item.size)
        try JSONEncoder().encode(stopped).write(to: ReadWatchdog.location(folder.data))
        try folder.indexer().noteStopped(folder.data)
        #expect(try folder.item().state == "failed")
        #expect(ReadWatchdog.askedToStop(folder.data) == nil && ReadWatchdog.stopped(folder.data) == nil)
    }

    @Test("#65: the watchdog stopped it and the file's gone off this Mac: set aside, its attempt still counted")
    func watchdogAndAwayKeepsTheAttempt() throws {
        let folder = try Folder()
        let item = try folder.item()
        try folder.store.startReading(item.id)
        try FileManager.default.createDirectory(at: ReadWatchdog.askedLocation(folder.data).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let asked = ReadWatchdog.Stopped(path: item.path, why: "asked to stop", mtime: item.mtime, size: item.size)
        try JSONEncoder().encode(asked).write(to: ReadWatchdog.askedLocation(folder.data))
        let stopped = ReadWatchdog.Stopped(path: item.path, why: "reading it took more than 15 minutes",
                                           mtime: item.mtime, size: item.size)
        try JSONEncoder().encode(stopped).write(to: ReadWatchdog.location(folder.data))
        try FileManager.default.removeItem(at: folder.file)   // a share gone mid-read, maybe why it hung
        try folder.indexer().noteStopped(folder.data)
        #expect(try folder.item().attempts == 1)
        #expect(ReadWatchdog.askedToStop(folder.data) == nil && ReadWatchdog.stopped(folder.data) == nil)
    }

    @Test("#65: nothing in hand, or its pictures and sound being made again: no note")
    func nothingToNote() throws {
        let folder = try Folder()
        let watchdog = ReadWatchdog(directory: folder.data)
        watchdog.noteAskedToStop()
        #expect(ReadWatchdog.askedToStop(folder.data) == nil)
        watchdog.begin(folder.file.path, stage: ReadWatchdog.media)
        watchdog.noteAskedToStop()
        #expect(ReadWatchdog.askedToStop(folder.data) == nil)
        watchdog.end()
    }

    @Test("#65: a file begun after the quit was asked (the one in hand finished first) is the one noted")
    func begunAfterTheQuit() throws {
        let folder = try Folder()
        let item = try folder.item()
        let watchdog = ReadWatchdog(directory: folder.data)
        watchdog.begin("/elsewhere/读完了.md")
        watchdog.end()
        watchdog.noteAskedToStop()   // between two files
        #expect(ReadWatchdog.askedToStop(folder.data) == nil)
        watchdog.begin(item.path, mtime: item.mtime, size: item.size)
        #expect(ReadWatchdog.askedToStop(folder.data)?.path == item.path)
        watchdog.end()
        watchdog.begin(folder.file.path, stage: ReadWatchdog.media)   // pictures made again: not noted
        #expect(ReadWatchdog.askedToStop(folder.data)?.stage == nil)
        #expect(ReadWatchdog.askedToStop(folder.data)?.path == item.path)
        watchdog.end()
    }

    @Test("#65: a step of a long file, asked to quit while it's read, is noted the same way")
    func longFileStep() throws {
        let folder = try Folder("files/长笔记.txt", Drawn.longText())
        try folder.indexer().readPending()
        #expect(try folder.item().state == "partial")
        let indexer = folder.indexer()
        let watchdog = ReadWatchdog(directory: folder.data)
        indexer.watchdog = watchdog
        var noted: String?
        var attemptsWhileRead: Int?
        indexer.read = { item, _, _ in
            watchdog.noteAskedToStop()
            noted = ReadWatchdog.askedToStop(folder.data)?.path
            attemptsWhileRead = try? folder.store.item(path: item.path)?.attempts
            return Reading()
        }
        #expect(try indexer.readRest(shouldStop: { false }, progress: { _ in }) == 1)
        #expect(noted == folder.file.path)
        #expect(attemptsWhileRead == 1)
    }
}

extension ReadsPictures.CommandLineTests {
    @Test("index --job: SIGTERM, then killed before the file in hand is read: that read isn't held against the file")
    func jobKilledAfterSIGTERM() throws {
        let scratch = try Scratch()
        // Big screenshots, read with OCR: the job is almost always in the middle of one.
        let total = 30
        for index in 0..<total {
            let lines = (0..<18).map { "第 \(index) 张截图的第 \($0) 行：周三下午三点评审发布方案" }
            try scratch.write("files/Screenshot 2026-10-01 at 11.00.\(String(format: "%02d", index)).png",
                              data: Drawn.png(Drawn.picture(lines, width: 2400, height: 1800, size: 60)))
        }
        let (data, store) = try jobData(scratch, folder: scratch.path + "/files")
        // Killed mid-read: the noted file waits with its attempt counted, until the next run takes it back. A round
        // whose file finished within the moment before the kill shows nothing: tried again, a few times at most.
        var killedMidRead = false
        for _ in 0..<3 where !killedMidRead {
            let before = try readSoFar(store)
            let job = try CommandRun(["index", "--job", "--index", data.url.path], in: scratch)
            defer { job.stop() }
            try #require(try eventually(120) { try readSoFar(store) > before })
            job.signal(SIGTERM)
            Thread.sleep(forTimeInterval: 0.05)
            job.stop()   // SIGKILL, as luoke-core after its 15 s
            let asked = try #require(ReadWatchdog.askedToStop(data), "no note of the file in hand")
            #expect(asked.path.hasPrefix(scratch.path + "/files/Screenshot "))
            let noted = try #require(try store.item(path: asked.path))
            killedMidRead = noted.state == "pending" && noted.attempts == 1
            try Indexer(store: store, crawler: Crawler(home: scratch.path)).noteStopped(data)
            #expect(try store.pending(limit: total).allSatisfy { $0.attempts == 0 })
            #expect(ReadWatchdog.askedToStop(data) == nil)
        }
        #expect(killedMidRead)
    }
}
