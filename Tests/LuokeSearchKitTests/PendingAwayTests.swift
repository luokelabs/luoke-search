import Foundation
import Testing
@testable import LuokeSearchKit

// Files waiting to be read whose contents went off to iCloud since, or whose drive was unplugged: not opened (that
// would download them), not read as gone, not counted as waiting; read once a walk finds them here again (found in
// the third review of luoke-search#49, 11-02). Synthetic files only.

struct PendingAwayTests {
    /// Two notes in `files/`, the folder searched, listed and not read yet.
    func waiting() throws -> (Scratch, IndexStore, Indexer, DataDirectory) {
        let scratch = try Scratch()
        try scratch.write("files/云上.md", "# 云上的笔记\n写着蝾螈。")
        try scratch.write("files/本机.md", "# 本机的笔记\n写着水獭。")
        let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        var settings = Settings()
        settings.folders = [scratch.path + "/files"]
        try settings.save(data)
        let store = try scratch.store()
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        _ = try indexer.sync([scratch.path + "/files"])
        return (scratch, store, indexer, data)
    }

    /// Says the files at `paths` (as they are now) have their contents only in iCloud.
    static func onlyInICloud(_ paths: [String]) -> (stat) -> Bool {
        let inodes = Set(paths.compactMap { path -> UInt64? in
            var info = stat()
            return lstat(path, &info) == 0 ? UInt64(info.st_ino) : nil
        })
        return { inodes.contains(UInt64($0.st_ino)) }
    }

    /// What an item says of itself (`ItemRecord` doesn't carry it).
    static func detail(_ store: IndexStore, _ id: Int64) throws -> String? {
        var out: String?
        try store.db.query("SELECT detail FROM items WHERE id = ?", [.int(id)]) { out = $0.text(0) }
        return out
    }

    /// Reads what's waiting, as `Indexer.readPending`: fails, not hangs, if the same items are taken up again and
    /// again.
    @discardableResult
    func readPending(_ indexer: Indexer) throws -> Int {
        var asked = 0
        let read = try indexer.readPending(shouldStop: { asked += 1; return asked > 100 })
        #expect(asked <= 100, "the same items taken up again and again")
        return read
    }

    /// Notes each file the indexer opens to read.
    final class Opened {
        var paths: [String] = []

        init(_ indexer: Indexer) {
            let read = indexer.read
            indexer.read = { [unowned self] item, photos, from in
                paths.append(item.path)
                return read(item, photos, from)
            }
        }
    }

    @Test("a waiting file only in iCloud now isn't opened nor counted as waiting; read once a change finds it here")
    func waitingOnlyInICloud() throws {
        let (scratch, store, indexer, data) = try waiting()
        let cloud = scratch.path + "/files/云上.md", here = scratch.path + "/files/本机.md"
        indexer.crawler.isDataless = Self.onlyInICloud([cloud])
        let opened = Opened(indexer)
        #expect(try readPending(indexer) == 1)
        #expect(opened.paths == [here])
        #expect(try store.item(path: cloud)?.state == "pending")
        let counts = try store.counts()
        #expect(counts.waitingToRead == 0 && counts.notOnThisMac == 1)
        // Not waiting: the first pass is done, and a search doesn't say it's still being built. The status says.
        let service = try SearchService(directory: data, hub: nil, home: scratch.path)
        try service.noteFirstPassIfDone()
        #expect(ToolState.load(data).firstPassDone != nil)
        let status = try service.status()
        #expect((status["waiting"] as? [String: Int])?["read"] == 0)
        #expect((status["waiting"] as? [String: Int])?["not_on_this_mac"] == 1)
        #expect(service.statusSentence(status).contains("1 个不在这台 Mac 上"))
        #expect(try Searcher(store: store).search("水獭").partialReason == "这次只按字词搜")
        // Not looked at again, until a walk finds it here.
        #expect(try readPending(indexer) == 0)
        #expect(try indexer.sync([scratch.path + "/files"]).removed == 0)
        #expect(try readPending(indexer) == 0)
        #expect(opened.paths == [here])
        // Downloaded (opened in Finder, say): the change FSEvents sees queues it.
        indexer.crawler.isDataless = { _ in false }
        _ = try indexer.sync([scratch.path + "/files"], changed: [cloud])
        #expect(try store.counts().waitingToRead == 1)
        #expect(try readPending(indexer) == 1)
        #expect(opened.paths == [here, cloud])
        #expect(try store.item(path: cloud)?.state == "done")
        #expect(try Searcher(store: store).search("蝾螈").hits.first?.title == "云上.md")
    }

    @Test("the first pass's report says how many weren't on this Mac, until they're back and read")
    func reportSaysAway() throws {
        let (scratch, _, indexer, data) = try waiting()
        let cloud = scratch.path + "/files/云上.md"
        indexer.crawler.isDataless = Self.onlyInICloud([cloud])
        #expect(try readPending(indexer) == 1)
        let service = try SearchService(directory: data, hub: nil, home: scratch.path)
        try service.noteFirstPassIfDone()
        func report() throws -> String? {
            let items = try #require(service.outbox()["items"] as? [[String: Any]])
            return items.first { $0["kind"] as? String == "index-ready" }?["summary"] as? String
        }
        #expect(try report() == "已索引 1 个文件，可以在螺壳里让我帮你找了。另有 1 个文件不在这台 Mac 上（只在 iCloud、盘拔了这些），回到这台 Mac 上再读。")
        indexer.crawler.isDataless = { _ in false }
        _ = try indexer.sync([scratch.path + "/files"], changed: [cloud])
        #expect(try readPending(indexer) == 1)
        #expect(try report() == "已索引 2 个文件，可以在螺壳里让我帮你找了。")
    }

    @Test("one an older reader read, only in iCloud now, stays searchable as it was; a whole walk queues it again")
    func requeuedOnlyInICloud() throws {
        let (scratch, store, indexer, _) = try waiting()
        try readPending(indexer)
        let cloud = scratch.path + "/files/云上.md"
        try store.db.query("UPDATE items SET reader = 0 WHERE path = ?", [.text(cloud)])   // read by an older reader
        indexer.crawler.isDataless = Self.onlyInICloud([cloud])
        #expect(try indexer.sync([scratch.path + "/files"]).requeued == 1)
        let opened = Opened(indexer)
        #expect(try readPending(indexer) == 0)
        #expect(opened.paths.isEmpty)
        #expect(try store.counts().notOnThisMac == 1)
        #expect(try Searcher(store: store).search("蝾螈").hits.first?.title == "云上.md")
        indexer.crawler.isDataless = { _ in false }
        _ = try indexer.sync([scratch.path + "/files"])
        #expect(try readPending(indexer) == 1)
        #expect(opened.paths == [cloud])
        #expect(try store.item(path: cloud)?.reader == Reader.versions[.doc])
    }

    @Test("waiting files on a drive unplugged since aren't read as gone; read when it's back")
    func waitingOnADriveUnplugged() throws {
        let (scratch, store, indexer, _) = try waiting()
        let drive = scratch.url.appendingPathComponent("files"), unplugged = scratch.url.appendingPathComponent("拔掉了")
        try FileManager.default.moveItem(at: drive, to: unplugged)
        #expect(try readPending(indexer) == 0)
        #expect(try store.counts().notOnThisMac == 2)
        #expect(try indexer.sync([drive.path]).unreachable == [drive.path])
        try FileManager.default.moveItem(at: unplugged, to: drive)
        _ = try indexer.sync([drive.path])
        #expect(try readPending(indexer) == 2)
        #expect(try store.counts().items["doc"] == 2)
    }

    @Test("one unplugged while it's read isn't failed for good")
    func unpluggedWhileRead() throws {
        let (scratch, store, indexer, _) = try waiting()
        let drive = scratch.url.appendingPathComponent("files"), unplugged = scratch.url.appendingPathComponent("拔掉了")
        let read = indexer.read
        indexer.read = { _, _, _ in
            try? FileManager.default.moveItem(at: drive, to: unplugged)
            return Reading(outcome: .failed("The file couldn't be opened."))
        }
        #expect(try readPending(indexer) == 0)
        #expect(try store.counts().notOnThisMac == 2)
        #expect(try store.db.scalarInt("SELECT MAX(attempts) FROM items") == 0)   // the read finished
        indexer.read = read
        try FileManager.default.moveItem(at: unplugged, to: drive)
        _ = try indexer.sync([drive.path])
        #expect(try readPending(indexer) == 2)
    }

    @Test("one that changed or was read since it was listed isn't set aside as it was then")
    func changedMeanwhile() throws {
        let (scratch, store, indexer, _) = try waiting()
        try scratch.write("files/读过了.md", "# 读过了的笔记\n写着刺猬。")
        try scratch.write("files/改了名.md", "# 改了名的笔记\n写着海豹。")
        _ = try indexer.sync([scratch.path + "/files"])
        // Another process saw two of them change (one's time, the other's size), read the third, and moved the
        // fourth to its new name (a walk saw it renamed, here).
        for (name, change) in [("云上.md", "mtime = mtime + 1"), ("本机.md", "size = size + 1"),
                               ("读过了.md", "state = 'done'"), ("改了名.md", "path = path || '.新名字'")] {
            let listed = try #require(try store.item(path: scratch.path + "/files/" + name))
            try store.db.query("UPDATE items SET \(change) WHERE id = ?", [.int(listed.id)])
            try store.setAside(listed)
        }
        #expect(try store.counts().notOnThisMac == 0)
        #expect(try store.db.scalarInt("SELECT COUNT(*) FROM items WHERE detail = ?", [.text(IndexStore.notHere)]) == 0)
    }

    @Test("ones read as gone or not listed before, a drive unplugged then, are read again once; not other failures")
    func readAsGoneBefore() throws {
        let (scratch, store, indexer, _) = try waiting()
        try scratch.write("files/没了.md", "# 没了的笔记\n写着河狸。")
        try scratch.write("files/还在云上.md", "# 还在云上的笔记\n写着海豹。")
        try scratch.write("files/读时拔了.md", "# 读时拔了的笔记\n写着刺猬。")
        _ = try indexer.sync([scratch.path + "/files"])
        func listed(_ name: String) throws -> ItemRecord {
            try #require(try store.item(path: scratch.path + "/files/" + name))
        }
        let (back, gone, away, other) = (try listed("云上.md"), try listed("没了.md"), try listed("还在云上.md"),
                                         try listed("本机.md"))
        let unlisted = try listed("读时拔了.md")
        let photo = try #require(try store.item(id: store.addPhoto(PhotoAsset(
            id: "A1", isVideo: false, created: nil, modified: 1_000, width: 640, height: 480,
            filename: "IMG_0001.HEIC"))))
        for item in [back, gone, away, photo] {
            try store.store(Reading(outcome: .failed(Indexer.gone)), for: item, reader: Reader.versions[item.kind] ?? 0)
        }
        // Unplugged while it was read: not there to look at after (`Indexer.isListed`).
        try store.store(Reading(outcome: .failed(Indexer.notListed)), for: unlisted, reader: Reader.versions[.doc] ?? 0)
        try store.store(Reading(outcome: .failed("The file couldn't be opened.")), for: other,
                        reader: Reader.versions[.doc] ?? 0)
        try FileManager.default.removeItem(atPath: gone.path)
        indexer.crawler.isDataless = Self.onlyInICloud([away.path])
        try store.setMeta(IndexStore.goneRequeued, nil)   // an index from before
        let report = try indexer.sync([scratch.path + "/files"])
        #expect(report.requeued == 4 && report.removed == 1)
        #expect(try readPending(indexer) == 2)
        #expect(try store.item(path: back.path)?.state == "done")
        #expect(try store.item(path: unlisted.path)?.state == "done")
        #expect(try store.item(path: gone.path) == nil)   // really gone: removed by the walk
        #expect(try store.item(path: away.path)?.state == "pending")   // still away: set aside
        #expect(try store.counts().notOnThisMac == 1)
        #expect(try store.item(path: other.path)?.state == "failed")   // another failure, not the drive
        #expect(try store.item(id: photo.id)?.state == "failed")   // files only
        // Once: not at every walk.
        try store.db.query("UPDATE items SET state = 'failed', detail = ? WHERE id = ?",
                           [.text(Indexer.gone), .int(back.id)])
        #expect(try indexer.sync([scratch.path + "/files"]).requeued == 0)
        #expect(try store.item(path: back.path)?.state == "failed")
    }

    @Test("one the watchdog stopped, not on this Mac at the next start, isn't given up on: it waits, read when back")
    func stoppedWhileAway() throws {
        let (scratch, store, indexer, data) = try waiting()
        let long = try scratch.write("files/长笔记.txt", Drawn.longText())
        _ = try indexer.sync([scratch.path + "/files"])
        let drive = scratch.url.appendingPathComponent("files"), unplugged = scratch.url.appendingPathComponent("拔掉了")
        /// The note a process the watchdog ended left on `path` (`stage` as it was), and the next start, its drive
        /// unplugged meanwhile (a share gone mid-read, maybe why it hung). Plugged in again after.
        func stoppedThenUnplugged(_ path: String, stage: String? = nil) throws {
            let item = try #require(try store.item(path: path))
            let note = ReadWatchdog.Stopped(path: path, why: "reading it took more than 15 minutes", mtime: item.mtime,
                                            size: item.size, stage: stage)
            try JSONEncoder().encode(note).write(to: ReadWatchdog.location(data))
            try FileManager.default.moveItem(at: drive, to: unplugged)
            try indexer.noteStopped(data)
            #expect(ReadWatchdog.stopped(data) == nil)   // noted
            try FileManager.default.moveItem(at: unplugged, to: drive)
        }
        // Waiting to be read: set aside, its attempt counted, not failed.
        let waiting = try #require(try store.item(path: scratch.path + "/files/云上.md"))
        try store.startReading(waiting.id)   // the read that hung
        try stoppedThenUnplugged(waiting.path)
        #expect(try store.item(id: waiting.id)?.state == "pending")
        #expect(try Self.detail(store, waiting.id) == IndexStore.notHere)
        #expect(try store.item(id: waiting.id)?.attempts == 1)
        _ = try indexer.sync([scratch.path + "/files"])   // back
        try readPending(indexer)
        #expect(try store.item(id: waiting.id)?.state == "done")
        // The rest of a long one: still to be read, not ended as read.
        #expect(try store.item(path: long.path)?.state == "partial")
        try stoppedThenUnplugged(long.path)
        #expect(try store.item(path: long.path)?.state == "partial")
        #expect(try indexer.readRest() == 1)
        #expect(try store.item(path: long.path)?.state == "done")
        // Its pictures and sound being made again: they still wait.
        let read = try #require(try store.item(path: scratch.path + "/files/本机.md"))
        try store.db.query("UPDATE segments SET todo = 'media' WHERE item = ?", [.int(read.id)])
        try stoppedThenUnplugged(read.path, stage: ReadWatchdog.media)
        #expect(try store.db.scalarInt("SELECT COUNT(*) FROM segments WHERE item = ? AND todo = 'media'",
                                       [.int(read.id)]) ?? 0 > 0)
    }

    @Test("long files whose rest was read as gone or not listed before are read again from the start, once")
    func restReadAsGoneBefore() throws {
        let (scratch, store, indexer, _) = try waiting()
        try scratch.write("files/别的.md", "# 别的笔记\n写着海獭。")
        _ = try indexer.sync([scratch.path + "/files"])
        try readPending(indexer)
        func listed(_ name: String) throws -> ItemRecord {
            try #require(try store.item(path: scratch.path + "/files/" + name))
        }
        let (gone, unlisted, other) = (try listed("云上.md"), try listed("本机.md"), try listed("别的.md"))
        // As an older version ended them: read, with what of their rest couldn't be.
        for (item, why) in [(gone, Indexer.gone), (unlisted, Indexer.notListed), (other, "The file couldn't be opened.")] {
            try store.db.query("UPDATE items SET detail = ? WHERE id = ?", [.text(IndexStore.restFailed(why)), .int(item.id)])
        }
        try store.setMeta(IndexStore.goneRequeued, nil)   // an index from before
        #expect(try indexer.sync([scratch.path + "/files"]).requeued == 2)
        #expect(try store.item(id: gone.id)?.state == "pending" && store.item(id: unlisted.id)?.state == "pending")
        #expect(try Searcher(store: store).search("蝾螈").hits.first?.title == "云上.md")   // what was read stays
        #expect(try readPending(indexer) == 2)
        #expect(try store.item(id: gone.id)?.state == "done" && Self.detail(store, gone.id) == nil)
        #expect(try store.item(id: other.id)?.state == "done")   // another failure, not the drive
        #expect(try Self.detail(store, other.id) == IndexStore.restFailed("The file couldn't be opened."))
    }

    @Test("a long file unplugged while the rest of it is read isn't ended as read; the rest is read when it's back")
    func unpluggedWhileTheRestIsRead() throws {
        let scratch = try Scratch()
        let file = try scratch.write("files/长笔记.txt", Drawn.longText())
        let store = try scratch.store()
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        _ = try indexer.sync([scratch.path + "/files"])
        try readPending(indexer)
        #expect(try store.item(path: file.path)?.state == "partial")
        let drive = scratch.url.appendingPathComponent("files"), unplugged = scratch.url.appendingPathComponent("拔掉了")
        let read = indexer.read
        indexer.read = { _, _, _ in
            try? FileManager.default.moveItem(at: drive, to: unplugged)
            return Reading(outcome: .failed("The file couldn't be opened."))
        }
        #expect(try indexer.readRest() == 0)
        #expect(try store.item(path: file.path)?.state == "partial")
        #expect(try store.item(path: file.path)?.attempts == 0)   // the read finished
        indexer.read = read
        try FileManager.default.moveItem(at: unplugged, to: drive)
        #expect(try indexer.readRest() == 1)
        #expect(try store.item(path: file.path)?.state == "done")
        #expect(try Searcher(store: store).search("蝾螈").hits.first?.title == "长笔记.txt")
    }

    @Test("status and index (the built command line) say how many aren't on this Mac")
    func commandLineSays() throws {
        let (scratch, _, indexer, data) = try waiting()
        try FileManager.default.moveItem(at: scratch.url.appendingPathComponent("files"),
                                         to: scratch.url.appendingPathComponent("拔掉了"))
        try readPending(indexer)
        let status = try CommandRun(["status", "--index", data.url.path], in: scratch)
        defer { status.stop() }
        #expect(status.wait() == 0)
        #expect(status.stdout.contains("\n不在这台 Mac 上 2 个（只在 iCloud、盘拔了这些），回到这台 Mac 上再读\n"))
        let index = try CommandRun(["index", "--index", data.url.path], in: scratch)
        defer { index.stop() }
        #expect(index.wait() == 0)
        #expect(index.stdout.contains("\n不在这台 Mac 上 2 个，这次没读（只在 iCloud、盘拔了这些），回到这台 Mac 上再读。\n"))
    }

    @Test("one moved off this Mac while waiting and back under a new name is read")
    func waitingMovedBackRenamed() throws {
        let (scratch, store, indexer, _) = try waiting()
        let file = scratch.url.appendingPathComponent("files/云上.md")
        let away = scratch.url.appendingPathComponent("别处.md")
        try FileManager.default.moveItem(at: file, to: away)
        #expect(try readPending(indexer) == 1)
        #expect(try store.item(path: file.path)?.state == "pending")   // not failed as "file is gone"
        let renamed = scratch.url.appendingPathComponent("files/云上（改了名）.md")
        try FileManager.default.moveItem(at: away, to: renamed)
        #expect(try indexer.sync([scratch.path + "/files"]).moved == 1)
        #expect(try readPending(indexer) == 1)
        #expect(try store.item(path: renamed.path)?.state == "done")
    }
}
