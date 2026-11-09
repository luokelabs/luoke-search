import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LuokeSearchKit

// The whole-branch review of 11bc2ca: filling in vectors and talking to luoke-core, each finding reproduced by number.

/// `count` short documents, read; a fake luoke-core; the client for it. Holds the scratch folder while used.
final class Texts {
    let scratch: Scratch, store: IndexStore, fake: FakeHub, hub: Hub

    init(_ count: Int) throws {
        scratch = try Scratch()
        for index in 0..<count { try scratch.write("files/note\(index).md", "# 笔记 \(index)\n第 \(index) 份笔记的内容。") }
        store = try scratch.store()
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        _ = try indexer.sync([scratch.path + "/files"])
        try indexer.readPending()
        fake = try FakeHub()
        hub = Hub(socket: fake.path, environment: [:])
    }

    deinit { fake.stop() }   // its socket and thread go with it

    func filler() -> VectorFiller {
        let filler = VectorFiller(store: store, hub: hub)
        filler.sleep = { _, _ in }
        return filler
    }
}

struct ReviewHubTests {
    @Test("B-05: vectors in another space than /tasks says: one switch a run, never a loop")
    func spaceDisagreement() throws {
        let texts = try Texts(3)
        texts.fake.answerSpace("other/2")
        let report = texts.filler().run(wait: false)
        #expect(report.stoppedBy == nil)
        #expect(report.embedded == 3)
        #expect(try texts.store.vectorSpace == "other/2")
        #expect(texts.fake.embedRequests.count == 2)   // the first answer's vectors were made again, once
        // /tasks names no space: the answer's is taken at once.
        let unnamed = try Texts(2)
        unnamed.fake.space = nil
        unnamed.fake.answerSpace("embeddinggemma-2/1")
        #expect(unnamed.filler().run(wait: false).embedded == 2)
        #expect(try unnamed.store.vectorSpace == "embeddinggemma-2/1")
        #expect(unnamed.fake.embedRequests.count == 1)
    }

    @Test("B-06: the batch shrinks mid-run: the new limits are read and used, nothing stops")
    func limitsChangeMidRun() throws {
        let texts = try Texts(40)
        texts.fake.changeBatch(to: 8, afterRequests: 1)
        let report = texts.filler().run(wait: false)
        #expect(report.stoppedBy == nil)
        #expect(report.embedded == 40)
        #expect(try texts.store.counts().waitingForVectors == 0)
        let sizes = texts.fake.embedRequests.compactMap {
            ((try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any])?["texts"] as? [String]
        }.map(\.count)
        #expect(sizes.first == 32 && sizes.dropFirst(2).allSatisfy { $0 <= 8 })
    }

    @Test("B-07: a long rest after a batch is waited out, not taken for a stop")
    func longRests() throws {
        let texts = try Texts(2)
        texts.fake.refuse(503, ["code": "busy", "reason": "power_cooldown", "retry_after_ms": 15_000])
        var slept: [TimeInterval] = []
        let filler = texts.filler()
        filler.sleep = { seconds, _ in slept.append(seconds) }
        let report = filler.run(wait: false)
        #expect(slept == [15])
        #expect(report.stoppedBy == nil && report.embedded == 2)
        // Rests that add up past the limit without a vector in between do stop it.
        let tired = try Texts(1)
        tired.fake.refuse(503, ["code": "busy", "reason": "lane_busy", "retry_after_ms": 400_000], times: 2)
        let stopped = tired.filler().run(wait: false)
        #expect(stopped.embedded == 0)
        if case .refused(_, "lane_busy", _)? = stopped.stoppedBy {} else { Issue.record("\(String(describing: stopped.stoppedBy))") }
    }

    @Test("B-14: a status this version doesn't know is 'not now', not 'not on this Mac'")
    func unknownStatus() throws {
        let texts = try Texts(1)
        texts.fake.status = "loading"
        let task = try texts.hub.embedTask(refresh: true)
        #expect(task.status == .unavailable && task.reason == "loading")
        #expect(texts.filler().run(wait: false).stoppedBy == .unavailable("loading"))
    }

    @Test("B-15: an all-zero vector is refused, for documents and for the query")
    func zeroVectors() throws {
        let texts = try Texts(2)
        texts.fake.zeroVectors = true
        let report = texts.filler().run(wait: false)
        #expect(report.embedded == 0)
        if case .failed? = report.stoppedBy {} else { Issue.record("\(String(describing: report.stoppedBy))") }
        #expect(try texts.store.counts().vectors == 0)
        let (meaning, note) = QueryMeaning.make("笔记", hub: texts.hub)
        #expect(meaning == nil && note != nil)
    }

    @Test("B-16: a question longer than the task's limit is cut, and still gets a vector")
    func longQuestions() throws {
        let texts = try Texts(1)
        texts.fake.maxChars = 60
        let (meaning, note) = QueryMeaning.make(String(repeating: "很长的问题", count: 40), hub: texts.hub)
        #expect(meaning != nil && note == nil)
        let sent = ((try? JSONSerialization.jsonObject(with: texts.fake.embedRequests.last!.body)) as? [String: Any])?["texts"]
        #expect((sent as? [String])?.first?.unicodeScalars.count == 60)
    }

    @Test("B-20: items waiting for pictures and sound are paged through in order, each once")
    func paging() throws {
        let scratch = try Scratch()
        let store = try scratch.store()
        for index in 1...3 {
            let id = try store.addPhoto(PhotoAsset(id: "P\(index)", isVideo: false, created: nil, modified: 1, width: 900,
                                                   height: 900, filename: nil))
            try store.store(Reading(pieces: [Piece(kind: .image, text: "", vector: .media)]),
                            for: try #require(try store.item(id: id)), reader: 1)
        }
        var seen: [Int64] = [], after: Int64 = 0
        while let next = store.mediaTodos(limit: 1, pictures: true, sound: false, after: after).first {
            seen.append(next.id)
            after = next.id
        }
        #expect(seen.count == 3 && seen == seen.sorted())
    }
}

extension ReadsPictures {
    struct ReviewMediaTests {
        /// A screenshot, a photo; read; a fake luoke-core that takes pictures.
        func pictures() throws -> (Scratch, IndexStore, FakeHub, Hub) {
            let scratch = try Scratch()
            try scratch.write("files/Screenshot 2026-10-11 at 15.12.08.png", data: Drawn.png(Drawn.picture(["付款失败"])))
            try scratch.write("files/IMG_2001.jpg", data: Drawn.photo(taken: "2026:09:14 10:02:00", offset: "+08:00"))
            let store = try scratch.store()
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([scratch.path + "/files"])
            try indexer.readPending()
            let fake = try FakeHub()
            fake.takesMedia = true
            return (scratch, store, fake, Hub(socket: fake.path, environment: [:]))
        }

        @Test("B-03: a long recording's windows are made and sent a request's worth at a time")
        func longRecording() throws {
            let scratch = try Scratch()
            try scratch.write("files/讲座.wav", data: Sound.wav(seconds: 600, tone: [0...600]))
            let store = try scratch.store()
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([scratch.path + "/files"])
            try indexer.readPending()
            let windows = try store.db.scalarInt("SELECT COUNT(*) FROM segments WHERE kind = 'audio'")
            #expect(windows == 24)
            let fake = try FakeHub()
            fake.takesMedia = true
            let report = VectorFiller(store: store, hub: Hub(socket: fake.path, environment: [:])).run(wait: false)
            #expect(report.embeddedMedia == 24)
            #expect(report.heldAtMost <= 2)   // audio_batch, never all 24
            #expect(report.heldBytesAtMost <= 2 * (30 * 16_000 * 2 + 44))
            withExtendedLifetime(scratch) {}
        }

        @Test("B-08: a picture that failed for now is tried again (three times); one luoke-core can't read is not")
        func failedForNow() throws {
            let (scratch, store, fake, hub) = try pictures()
            fake.failImages = "embed_failed"
            for run in 1...3 {
                let report = VectorFiller(store: store, hub: hub).run(wait: false)
                #expect(report.embeddedMedia == 0)
                if run < 3 {
                    #expect(report.mediaRetrying == 2 && report.mediaFailed == 0)
                    #expect(try store.counts().waitingForMedia == 2)
                } else {
                    #expect(report.mediaFailed == 2)   // the third time it's given up
                    #expect(try store.counts().waitingForMedia == 0)
                }
            }
            let (scratch2, store2, fake2, hub2) = try pictures()
            fake2.failImages = "image_unreadable"
            #expect(VectorFiller(store: store2, hub: hub2).run(wait: false).mediaFailed == 2)
            #expect(try store2.counts().waitingForMedia == 0)
            withExtendedLifetime((scratch, scratch2)) {}
        }

        @Test("B-08: too large for this tier: a smaller JPEG is sent, or it waits; a video that can't be decoded now is tried again")
        func notThisTime() throws {
            let scratch = try Scratch()
            let shot = try scratch.write("Screenshot 2026-10-01 at 10.00.00.png", data: Drawn.png(Drawn.picture(["很多字"])))
            let image = try Pictures.image(shot, maxPixels: 1536)
            let half = try #require(MediaInputs.Source.scaled(image, by: 0.5))
            var task = HubTask(status: .available)
            task.imageBatch = 8
            task.maxImageBytes = try Pictures.encode(half, as: .jpeg).count + 1
            #expect(try Pictures.encode(image, as: .png).count > task.maxImageBytes!)
            let want = MediaInputs.Wanted(segment: 1, kind: .image, loc: nil)
            guard case .made(let made)? = MediaInputs.Source(path: shot.path, kind: .screenshot, wanted: [want], task: task,
                                                             photos: nil).next(),
                  case .image(let data, 280) = made.input else { Issue.record("not made"); return }
            #expect(data.starts(with: [0xFF, 0xD8]))   // a JPEG instead of the PNG
            task.maxImageBytes = 10
            guard case .later? = MediaInputs.Source(path: shot.path, kind: .screenshot, wanted: [want], task: task,
                                                    photos: nil).next() else { Issue.record("not waiting"); return }
            // A video file that can't be decoded just now: failed for now, not "the frame isn't there any more".
            let broken = try scratch.write("VID.mp4", data: Data(repeating: 7, count: 4096))
            let frame = MediaInputs.Wanted(segment: 2, kind: .frame, loc: 0.5)
            guard case .failedForNow? = MediaInputs.Source(path: broken.path, kind: .video, wanted: [frame], task: task,
                                                           photos: nil).next() else { Issue.record("given up"); return }
        }

        @Test("B-08: a picture with a transparent background goes on white, as a PNG, a JPEG or at half the size (not black)")
        func smallerOnWhite() throws {
            let scratch = try Scratch()
            let clear = CGContext(data: nil, width: 600, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            clear.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            clear.fill(CGRect(x: 250, y: 100, width: 100, height: 100))
            let file = try scratch.write("图标.png", data: Drawn.png(clear.makeImage()!))
            let image = try Pictures.image(file, maxPixels: 1024)
            let half = try #require(MediaInputs.Source.scaled(image, by: 0.5))
            let halfBytes = try Pictures.encode(half, as: .jpeg).count
            #expect(try Pictures.encode(image, as: .jpeg).count > halfBytes + 1)
            var task = HubTask(status: .available)
            task.imageBatch = 8
            let want = MediaInputs.Wanted(segment: 1, kind: .image, loc: nil)
            // A screenshot goes as a PNG when it fits; a picture as a JPEG, then at half the size.
            for (kind, limit, png, width) in [(ItemKind.screenshot, Int?.none, true, 600), (.image, nil, false, 600),
                                              (.image, halfBytes + 1, false, 300)] {
                task.maxImageBytes = limit
                guard case .made(let made)? = MediaInputs.Source(path: file.path, kind: kind, wanted: [want], task: task,
                                                                 photos: nil).next(),
                      case .image(let data, _) = made.input,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let sent = CGImageSourceCreateImageAtIndex(source, 0, nil) else { Issue.record("not made"); return }
                #expect(data.starts(with: png ? [0x89, 0x50, 0x4E, 0x47] : [0xFF, 0xD8, 0xFF]))
                #expect(sent.width == width)
                // `pixel` draws on nothing: transparent comes out black there too.
                #expect(GlobalSearchTests.pixel(sent, x: 2, y: 2).allSatisfy { $0 > 240 }, "\(kind) \(width)")
                #expect(GlobalSearchTests.pixel(sent, x: sent.width / 2, y: sent.height / 2).allSatisfy { $0 < 40 })
            }
        }

        @Test("B-19: pictures embedded in another space are not stored under the old one")
        func mediaSpaceChange() throws {
            let (scratch, store, fake, hub) = try pictures()
            fake.answerSpace("other/2")
            let report = VectorFiller(store: store, hub: hub).run(wait: false)
            #expect(report.embeddedMedia == 0)
            #expect(report.stoppedBy == .failed("luoke-core's vector space changed"))
            #expect(try store.counts().waitingForMedia == 2 && store.counts().vectors == 0)
            withExtendedLifetime(scratch) {}
        }

        @Test("A-10: a Photos video only in iCloud waits and is read once it's on this Mac")
        func iCloudVideos() throws {
            let scratch = try Scratch()
            let store = try scratch.store()
            let photos = FakePhotos([.video("V1", "VID_0001.MOV")])
            photos.cloudOnly = ["V1"]
            _ = try PhotoIndexing.sync(photos, store: store)
            let indexer = Indexer(store: store)
            indexer.photos = photos
            try indexer.readPending()
            #expect(try store.item(path: "photos:V1")?.state == "skipped")
            // Watched in Photos: on this Mac now. Tried again on a later sync (after a few hours).
            photos.cloudOnly = []
            try store.db.execute("UPDATE items SET read_at = 0")
            _ = try PhotoIndexing.sync(photos, store: store)
            try indexer.readPending()
            #expect(try store.item(path: "photos:V1")?.state == "done")
            #expect(try store.readSegments("photos:V1") == ["frame@0.5", "frame@6.5", "frame@12.5"])
        }
    }
}

extension ReadsPictures {
    struct ReviewKindGateTests {
        @Test("B-02 follow-up: a recording that stands out a little is found when the question names recordings")
        func namedKindGate() throws {
            let scratch = try Scratch()
            for name in ["a", "b", "c", "d"] {
                try scratch.write("files/\(name).wav", data: Sound.wav(seconds: 5, tone: [0...5]))
            }
            let store = try scratch.store()
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([scratch.path + "/files"])
            try indexer.readPending()
            // Each window's cosine with the question: a.wav 0.44, the others about 0.40 (its z: about 1.65).
            var segments: [(String, Int64)] = []
            try store.db.query("""
                SELECT i.path, s.id FROM segments s JOIN items i ON i.id = s.item WHERE s.kind = 'audio' ORDER BY i.path
                """) { segments.append(($0.text(0) ?? "", $0.int(1))) }
            #expect(segments.count == 4)
            let cosines: [Float] = [0.44, 0.40, 0.41, 0.39]
            let vectors = segments.enumerated().map { index, segment -> (Int64, [Float]) in
                var vector = [Float](repeating: 0, count: VectorMath.dimension)
                vector[0] = cosines[index]
                vector[index + 1] = (1 - cosines[index] * cosines[index]).squareRoot()
                return (segment.1, vector)
            }
            try store.setVectors(vectors, space: "s")
            var query = [Float](repeating: 0, count: VectorMath.dimension)
            query[0] = 1
            let meaning = QueryMeaning(vector: query, space: "s")
            let searcher = Searcher(store: store)
            #expect(try searcher.search("开会时那段录音", meaning: meaning).hits.first?.title == "a.wav")
            #expect(try searcher.search("开会时那段", meaning: meaning).hits.isEmpty)   // not named: z 2 needed
        }
    }
}
