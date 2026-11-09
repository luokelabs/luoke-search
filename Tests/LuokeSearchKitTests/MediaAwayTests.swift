import Foundation
import Testing
@testable import LuokeSearchKit

// The pictures and sound of files read already, waiting for vectors, whose files aren't on this Mac when luoke-core
// takes them: their drive unplugged, their contents gone off to iCloud. Not given up on for good, not opened (that
// would download them): they wait until the file is here again (found in the third review of luoke-search#50, 11-02).
// Synthetic files only.

extension ReadsPictures {
    struct MediaAwayTests {
        /// A screenshot in `files/`, read; its picture waits for a vector. And a fake luoke-core that takes pictures.
        final class Shot {
            let scratch: Scratch, store: IndexStore, fake: FakeHub, hub: Hub
            let file: URL

            init() throws {
                scratch = try Scratch()
                file = try scratch.write("files/Screenshot 2026-10-12 at 09.30.00.png",
                                         data: Drawn.png(Drawn.picture(["付款失败：余额不足"])))
                store = try scratch.store()
                let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
                _ = try indexer.sync([scratch.path + "/files"])
                try indexer.readPending()
                fake = try FakeHub()
                fake.takesMedia = true
                hub = Hub(socket: fake.path, environment: [:])
            }

            var drive: URL { scratch.url.appendingPathComponent("files") }
            var unplugged: URL { scratch.url.appendingPathComponent("拔掉了") }
            /// The pictures luoke-core was sent.
            var picturesSent: Int { fake.inputRequests.flatMap { $0 }.filter { $0["budget"] != nil }.count }
        }

        @Test("a picture whose drive is unplugged isn't given up on; it gets its vector once the drive is back")
        func driveUnplugged() throws {
            let shot = try Shot()
            #expect(try shot.store.counts().waitingForMedia == 1)
            try FileManager.default.moveItem(at: shot.drive, to: shot.unplugged)
            // Twice: a run while it's away isn't one of the tries it's given (`IndexStore.startMedia`).
            for _ in 0..<Indexer.maxAttempts {
                let away = VectorFiller(store: shot.store, hub: shot.hub).run(wait: false)
                #expect(away.mediaFailed == 0 && away.embeddedMedia == 0)
            }
            #expect(try shot.store.counts().waitingForMedia == 1)
            #expect(shot.picturesSent == 0)
            try FileManager.default.moveItem(at: shot.unplugged, to: shot.drive)
            let back = VectorFiller(store: shot.store, hub: shot.hub).run(wait: false)
            #expect(back.embeddedMedia == 1 && back.mediaFailed == 0)
            #expect(try shot.store.counts().waitingForMedia == 0)
            #expect(shot.picturesSent == 1)
        }

        @Test("what's said of a picture waiting while its drive is unplugged: no vector for meaning yet, not luoke-core")
        func whatsSaidWhileItWaits() throws {
            let shot = try Shot()
            let data = DataDirectory(url: shot.scratch.url.appendingPathComponent("data"))
            var settings = Settings()
            settings.folders = [shot.drive.path]
            try settings.save(data)
            let service = try SearchService(directory: data, hub: shot.hub, opener: Opened().opener,
                                            home: shot.scratch.path)
            try service.noteFirstPassIfDone()
            try FileManager.default.moveItem(at: shot.drive, to: shot.unplugged)
            _ = VectorFiller(store: shot.store, hub: shot.hub).run(wait: false)   // its picture waits
            // A screenshot's words are searched by words only (`Reader.picture`): only its picture waits.
            #expect(try shot.store.counts().waitingForVectors == 0 && shot.store.counts().waitingForMedia == 1)
            // Searching by meaning.
            #expect(try Searcher(store: shot.store).partialReason(meaningUsed: true, note: nil)
                    == "1 个文件的图片和声音还没全有按意思搜的向量，这些暂时只能按名字和里面的字找到")
            // search_status, as the agent reads it.
            #expect(service.statusSentence(try service.status()) == "已索引 1 个，1 个文件的图片和声音还没全有按意思搜的向量。")
            // The first pass's report.
            let ready = try #require((service.outbox()["items"] as? [[String: Any]])?.first { $0["kind"] as? String == "index-ready" })
            #expect(ready["summary"] as? String
                    == "已索引 1 个文件，可以在螺壳里让我帮你找了。其中 1 个文件的图片和声音还没全有按意思搜的向量，这些暂时只能按名字和里面的字找到。")
        }

        @Test("a picture whose file is only in iCloud now isn't made (the file isn't opened); it waits until it's here")
        func onlyInICloud() throws {
            let shot = try Shot()
            var info = stat()
            lstat(shot.file.path, &info)
            let inode = info.st_ino
            let filler = VectorFiller(store: shot.store, hub: shot.hub)
            filler.isDataless = { $0.st_ino == inode }
            var asked = 0
            filler.next = { source in
                asked += 1
                return source.next()
            }
            // Twice: nothing asked of the file, nor counted as begun (`IndexStore.startMedia`), or the run after would
            // give up on it.
            for _ in 0..<Indexer.maxAttempts {
                let away = filler.run(wait: false)
                #expect(away.mediaFailed == 0 && away.embeddedMedia == 0)
            }
            #expect(asked == 0)
            #expect(try shot.store.counts().waitingForMedia == 1)
            #expect(shot.picturesSent == 0)
            filler.isDataless = { _ in false }
            #expect(filler.run(wait: false).embeddedMedia == 1)
            #expect(try shot.store.counts().waitingForMedia == 0)
        }

        @Test("making a file's pictures: one not on this Mac waits; one that went while it was made waits too")
        func sourceWaitsForTheFile() throws {
            let shot = try Shot()
            var info = stat()
            lstat(shot.file.path, &info)
            let want = MediaInputs.Wanted(segment: 1, kind: .image, loc: nil)
            let task = HubTask(status: .available)
            func source() -> MediaInputs.Source {
                MediaInputs.Source(path: shot.file.path, kind: .screenshot, wanted: [want], task: task, photos: nil,
                                   inode: UInt64(info.st_ino))
            }
            guard case .made? = source().next() else {
                Issue.record("not made from the file here")
                return
            }
            // Only in iCloud: waits, not made.
            let cloud = source()
            cloud.isDataless = { _ in true }
            guard case .later(_, let why)? = cloud.next() else {
                Issue.record("not waiting while the file is only in iCloud")
                return
            }
            #expect(why == IndexStore.notHere)
            // Here when it's begun, only in iCloud once it's made (or its drive unplugged meanwhile): waits.
            let went = source()
            var looks = 0
            went.isDataless = { _ in
                looks += 1
                return looks > 1
            }
            guard case .later(_, IndexStore.notHere)? = went.next() else {
                Issue.record("given up on when it went while it was made")
                return
            }
            // Its drive unplugged just as it's made: there for the look after (a moment before), not for the check that
            // it's the file listed. Waits, not "not the file that was listed" for good.
            let unplugged = source()
            var after = 0
            unplugged.isDataless = { _ in
                after += 1
                if after == 2 { try? FileManager.default.moveItem(at: shot.drive, to: shot.unplugged) }
                return false
            }
            guard case .later(_, IndexStore.notHere)? = unplugged.next() else {
                Issue.record("given up on when its drive was unplugged as it was made")
                return
            }
            #expect(after == 2)   // unplugged at the look after it was made
            // Still unplugged: waits, not "file is gone" for good.
            guard case .later(_, IndexStore.notHere)? = source().next() else {
                Issue.record("given up on while its drive is unplugged")
                return
            }
        }
    }
}
