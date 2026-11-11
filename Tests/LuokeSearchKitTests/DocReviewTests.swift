@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import LuokeSearchKit

// luoke-search#46: what was found reading the code against the system documents at 2f06213 (11-01). Synthetic
// files only.

extension Drawn {
    /// A one-page PDF whose own title is `title`.
    static func titledPDF(_ title: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let info = [kCGPDFContextTitle: title] as CFDictionary
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, info)!
        context.beginPDFPage(nil)
        draw((0..<5).map { _ in "这是一份有自己标题的文件，讲的是日常的事情和一些说明，内容没有什么特别的地方。" },
             in: context, top: 780, size: 14)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

enum DocReviewFiles {
    /// A recording saved in a film's file (an .mp4 with sound and no pictures): a memo.
    static func soundOnlyFilm() throws -> Data {
        try Data(contentsOf: TestMedia.memo)
    }

    /// A film's file with no pictures whose sound breaks off two thirds in (some 45 of 68 seconds, after its first
    /// window): a podcast with its index moved to the front and the rest cut off, as a download that
    /// stopped would leave it.
    static func brokenSoundFilm() throws -> Data {
        let file = [UInt8](try Data(contentsOf: TestMedia.podcast))
        func word<C: Collection>(_ bytes: C) -> Int where C.Element == UInt8 { bytes.reduce(0) { $0 << 8 | Int($1) } }
        var atoms: [String: Range<Int>] = [:]
        var at = 0
        while at + 8 <= file.count {
            let size = word(file[at..<at + 4])
            try #require(size >= 8)   // no 64-bit sizes, no "to the end"
            atoms[String(decoding: file[at + 4..<at + 8], as: UTF8.self)] = at..<at + size
            at += size
        }
        let sound = try #require(atoms["mdat"]), index = try #require(atoms["moov"])
        var moov = Array(file[index])
        try #require(!moov.indices.dropLast(4).contains { moov[$0..<$0 + 4].elementsEqual("co64".utf8) })
        // Where its sound is in the file (every `stco` entry) moves by the index's length.
        for start in 0..<moov.count - 16 where moov[start + 4..<start + 8].elementsEqual("stco".utf8) {
            for entry in 0..<word(moov[start + 12..<start + 16]) {
                let place = start + 16 + entry * 4
                let moved = word(moov[place..<place + 4]) + moov.count
                for byte in 0..<4 { moov[place + byte] = UInt8(truncatingIfNeeded: moved >> (24 - 8 * byte)) }
            }
        }
        return Data(file[..<sound.lowerBound] + moov + file[sound.lowerBound..<sound.lowerBound + sound.count * 2 / 3])
    }

    /// A film with a picture track none of whose pictures can be decoded (it holds only an empty stretch, as far as
    /// the decoder gets with a codec this Mac can't play) and the memo's sound.
    static func undecodablePicturesFilm() throws -> AVAsset {
        let memo = AVURLAsset(url: TestMedia.memo)
        let (duration, sound) = try AsyncBridge.wait {
            (try await memo.load(.duration), try await memo.loadTracks(withMediaType: .audio).first)
        }
        let film = AVMutableComposition()
        let span = CMTimeRange(start: .zero, duration: duration)
        let pictures = film.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        pictures?.insertEmptyTimeRange(span)
        let heard = film.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        if let sound { try heard?.insertTimeRange(span, of: sound, at: .zero) }
        return film
    }
}

extension ReadsPictures {
    struct DocReviewTests {
        func indexed(_ scratch: Scratch) throws -> (IndexStore, Indexer) {
            let store = try scratch.store()
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([scratch.path + "/files"])
            try indexer.readPending()
            return (store, indexer)
        }

        @Test("#46-1: a PDF without a title of its own is embedded under \"none\", as digup does (measured: its file's name loses 3 of the 190 gate questions)")
        func untitledPDFKeepsNone() throws {
            let scratch = try Scratch()
            try scratch.write("files/年度报告.pdf", data: Drawn.longPDF(pages: 1))
            try scratch.write("files/合同扫描.pdf", data: Drawn.titledPDF("房屋租赁合同"))
            try scratch.write("files/笔记.md", "# 笔记\n第一版的内容。")
            let (store, _) = try indexed(scratch)
            let prompts = try store.textTodos(limit: 10).map { Prompts.document(title: $0.title, text: "") }
            #expect(Set(prompts) == ["title: none | text: ", "title: 房屋租赁合同 | text: ", "title: 笔记 | text: "])
        }

        @Test("#46-4: a .ts only in iCloud isn't opened to see whether it's a film (that would download it)")
        func transportStreamOnlyInICloud() throws {
            let scratch = try Scratch()
            var stream = Data(count: 188 * 4)
            for packet in 0..<4 { stream[packet * 188] = 0x47 }
            let clip = try scratch.write("clip.ts", data: stream)
            let code = try scratch.write("app.ts", String(repeating: "export const answer = 42;\n", count: 40))
            #expect(Rules.isTransportStream(clip))
            #expect(!Rules.isTransportStream(code))
            // Not looked into, so not known to be a film: the walk keeps a film it read while the file was here, and
            // counts it nowhere (TypeScript in iCloud isn't a film not on this Mac; review 11-02).
            var asked = false
            #expect(!Rules.isTransportStream(code, isDataless: { _ in asked = true; return true }))
            #expect(asked)
            #expect(!Rules.isTransportStream(clip, isDataless: { _ in true }))   // a film's too: not opened
            #expect(Rules.kind(of: code, isDataless: { _ in true }) == nil)
            #expect(Rules.classify(code, isDataless: { _ in true }) == .keep)
            #expect(Rules.classify(code, inProject: true, isDataless: { _ in true }) == .keep)
            #expect(Rules.classify(code, excludedExtensions: ["ts"], isDataless: { _ in true }) == .skip("excluded type"))
            // Nor counted towards a dataset-like folder.
            let streams = try (1...3).map { try scratch.write("frames/00000\($0).ts", data: stream) }
            #expect(Rules.datasetKinds(streams, minimum: 3) == [.video: 3])
            #expect(Rules.datasetKinds(streams, minimum: 3, isDataless: { _ in true }).isEmpty)
        }

        @Test("#46-4: the walk keeps what it read of a .ts now only in iCloud and counts none, in a code project too")
        func unopenedStreamsCountNowhere() throws {
            let scratch = try Scratch()
            var stream = Data(count: 188 * 4)
            for packet in 0..<4 { stream[packet * 188] = 0x47 }
            let clip = try scratch.write("files/clip.ts", data: stream)
            try scratch.write("files/app/Package.swift", "// swift-tools-version: 6.0")
            let code = try scratch.write("files/app/main.ts", String(repeating: "export const answer = 42;\n", count: 40))
            let store = try scratch.store()
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([scratch.path + "/files"])
            #expect(try store.item(path: clip.path) != nil)
            func inode(_ url: URL) -> ino_t {
                var info = stat()
                return lstat(url.path, &info) == 0 ? info.st_ino : 0
            }
            let away: Set<ino_t> = [inode(clip), inode(code)]
            indexer.crawler.isDataless = { away.contains($0.st_ino) }
            let report = try indexer.sync([scratch.path + "/files"])
            #expect(try store.item(path: clip.path) != nil)
            #expect(report.skipped["not on this Mac"] == nil && report.skipped["in a code project"] == nil, "\(report.skipped)")
            // A change seen by FSEvents takes the same way.
            let changed = try indexer.sync([scratch.path + "/files"], changed: [clip.path, code.path])
            #expect(changed.removed == 0)
            #expect(try store.item(path: clip.path) != nil)
            #expect(changed.skipped.isEmpty, "\(changed.skipped)")
        }

        @Test("#46-5: a film with sound and no pictures is read for its sound")
        func soundOnlyFilm() throws {
            let scratch = try Scratch()
            let file = try scratch.write("会议录音.mp4", data: try DocReviewFiles.soundOnlyFilm())
            let reading = Reader.read(file, kind: .video)
            #expect(reading.outcome == .done)
            #expect(!reading.pieces.isEmpty)
            #expect(reading.pieces.allSatisfy { $0.kind == .audio && $0.vector == .media })
            #expect(reading.info["duration"] != nil)
            // Made again for luoke-core: the same windows.
            let wanted = reading.pieces.enumerated().map {
                MediaInputs.Wanted(segment: Int64($0.offset), kind: .audio, loc: $0.element.loc, locEnd: $0.element.locEnd)
            }
            var task = HubTask(status: .available)
            task.audioBatch = 4
            let (made, impossible) = MediaInputs.make(path: file.path, kind: .video, wanted: wanted, task: task)
            #expect(impossible.isEmpty)
            #expect(made.count == wanted.count)
        }

        @Test("#46-5: a film with neither pictures nor sound still fails")
        func filmWithNothing() throws {
            let scratch = try Scratch()
            let file = try scratch.write("坏的.mp4", data: Data(repeating: 0, count: 4096))
            guard case .failed = Reader.read(file, kind: .video).outcome else {
                Issue.record("read as if it were a film")
                return
            }
        }

        @Test("#46-5: a film with no pictures whose sound breaks off fails as the same recording does, not done with half")
        func filmWhoseSoundBreaksOff() throws {
            let scratch = try Scratch()
            let data = try DocReviewFiles.brokenSoundFilm()
            let file = try scratch.write("广播.m4a", data: data)
            // What this file is: a window of sound heard, then a decoding error.
            var windows = 0
            #expect(throws: (any Error).self) {
                try AsyncBridge.wait { try await AudioWindows.scan(file) { _, _, _ in windows += 1 } }
            }
            #expect(windows > 0)
            let recording = MediaReading.audio(file)
            guard case .failed = recording.outcome else {
                Issue.record("the sound doesn't break off: \(recording.outcome)")
                return
            }
            let film = MediaReading.video(try scratch.write("广播.mp4", data: data))
            #expect(film.outcome == recording.outcome)
            #expect(film.pieces.isEmpty)
        }

        @Test("#46-5: a video in the Photos library is read by the same reader: the same failure there")
        func photosFilmWhoseSoundBreaksOff() throws {
            let scratch = try Scratch()
            let file = try scratch.write("广播.mp4", data: try DocReviewFiles.brokenSoundFilm())
            guard case .failed(let why) = MediaReading.video(file).outcome else {
                Issue.record("read as done")
                return
            }
            let store = try scratch.store()
            let photos = FakePhotos([.video("V1", "IMG_0001.MOV")])
            photos.videoFiles["V1"] = file
            _ = try PhotoIndexing.sync(photos, store: store)
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            indexer.photos = photos
            _ = try indexer.readPending()
            var detail: (String?, String?) = (nil, nil)
            try store.db.query("SELECT state, detail FROM items WHERE path = 'photos:V1'") { detail = ($0.text(0), $0.text(1)) }
            #expect(detail == ("failed", why))
        }

        @Test("#46-5: a film whose pictures are there but can't be decoded still fails, sound or not")
        func undecodablePictures() throws {
            let film = try DocReviewFiles.undecodablePicturesFilm()
            let (pictures, sound) = try AsyncBridge.wait {
                (try await film.loadTracks(withMediaType: .video).count, try await film.loadTracks(withMediaType: .audio).count)
            }
            #expect(pictures == 1 && sound == 1)   // what this film is made of
            guard case .failed(MediaReading.picturesUndecoded) = MediaReading.video(film).outcome else {
                Issue.record("read for its sound alone")
                return
            }
        }

        @Test("#46-5: in the Photos library too, and failing so it isn't read again at every walk")
        func undecodablePicturesInPhotos() throws {
            let scratch = try Scratch()
            let store = try scratch.store()
            let photos = FakePhotos([.video("V1", "IMG_0001.MOV")])
            photos.videoAssets["V1"] = try DocReviewFiles.undecodablePicturesFilm()
            _ = try PhotoIndexing.sync(photos, store: store)
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            indexer.photos = photos
            _ = try indexer.readPending()
            func detail() throws -> (String?, String?) {
                var out: (String?, String?) = (nil, nil)
                try store.db.query("SELECT state, detail FROM items WHERE path = 'photos:V1'") { out = ($0.text(0), $0.text(1)) }
                return out
            }
            #expect(try detail() == ("failed", MediaReading.picturesUndecoded))
            _ = try indexer.sync([scratch.path])
            #expect(try detail() == ("failed", MediaReading.picturesUndecoded))   // not queued again
        }

        @Test("#46-5: films an older reader failed for having no pictures are read again")
        func soundOnlyFilmsReadAgain() throws {
            let scratch = try Scratch()
            try scratch.write("files/会议录音.mp4", data: try DocReviewFiles.soundOnlyFilm())
            let (store, indexer) = try indexed(scratch)
            let item = try #require(try store.item(path: scratch.path + "/files/会议录音.mp4"))
            #expect(item.state == "done")
            // As the reader before left it, in an index this reader never walked.
            try store.db.query("UPDATE items SET state = 'failed', detail = 'no pictures in this video' WHERE id = ?",
                               [.int(item.id)])
            try store.setMeta(IndexStore.filmsWithoutPicturesRequeued, nil)
            _ = try indexer.sync([scratch.path + "/files"])
            #expect(try store.item(id: item.id)?.state == "pending")
            try indexer.readPending()
            #expect(try store.item(id: item.id)?.state == "done")
            #expect(try !store.readSegments(item.path).isEmpty)
            // Once: failed so again (by an older build, say), it stays at the next walk (review 11-02).
            try store.db.query("UPDATE items SET state = 'failed', detail = 'no pictures in this video' WHERE id = ?",
                               [.int(item.id)])
            _ = try indexer.sync([scratch.path + "/files"])
            #expect(try store.item(id: item.id)?.state == "failed")
        }

        @Test("#46-5: a video in the Photos library with sound and no pictures is read for its sound")
        func soundOnlyPhotosVideo() throws {
            let scratch = try Scratch()
            let store = try scratch.store()
            let photos = FakePhotos([.video("V1", "IMG_0001.MOV")])
            photos.videoFiles["V1"] = TestMedia.memo
            _ = try PhotoIndexing.sync(photos, store: store)
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            indexer.photos = photos
            #expect(try indexer.readPending() == 1)
            #expect(try store.item(path: "photos:V1")?.state == "done")
            let segments = try store.readSegments("photos:V1")
            #expect(!segments.isEmpty && segments.allSatisfy { $0.hasPrefix("audio") })
            // Failed by the reader before, in a library searched with no folder: read again too.
            try store.db.query("UPDATE items SET state = 'failed', detail = 'no pictures in this video' WHERE path = 'photos:V1'")
            try store.setMeta(IndexStore.filmsWithoutPicturesRequeued, nil)
            _ = try PhotoIndexing.sync(photos, store: store)
            #expect(try store.item(path: "photos:V1")?.state == "pending")
        }
    }
}

struct DocReviewServiceTests {
    @Test("#46-6: a Photos item opened where the library can't be read says so, not that the file is gone")
    func photoWithoutTheLibrary() throws {
        let scratch = try Scratch()
        let directory = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        let service = try SearchService(directory: directory, hub: nil, opener: .dry, home: scratch.path)
        try service.store.db.query("INSERT INTO items(path, source, kind, state) VALUES('photos:A1', 'photos', 'photo', 'done')")
        let id = try service.store.db.scalarInt("SELECT id FROM items WHERE path = 'photos:A1'")
        #expect(throws: ToolFailure.self) { try service.open(String(id), reveal: false) }
        do {
            _ = try service.open(String(id), reveal: false)
        } catch let failure as ToolFailure {
            #expect(failure.code != "stale")
            #expect(failure.message.contains("照片图库"))
        }
    }

    @Test("#46-6: a photo while reading the library isn't allowed is not called gone, and nothing asks or opens",
          arguments: [(PhotoAccess.notAsked, true, "设置 · 权限"), (.denied, true, "系统设置"),
                      (.notAsked, false, "这里读不了"), (.denied, false, "这里读不了")])
    func photoWithoutAccess(_ access: PhotoAccess, resident: Bool, says: String) throws {
        let scratch = try Scratch()
        let directory = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        let photos = FakePhotos([.photo("A1", "IMG_0001.HEIC")], access: access)
        let service = try SearchService(directory: directory, hub: nil, opener: .dry, photos: photos, home: scratch.path)
        service.judgesAccess = resident   // a command in a terminal sees the terminal's access, not the app's
        try service.store.db.query("INSERT INTO items(path, source, kind, state) VALUES('photos:A1', 'photos', 'photo', 'done')")
        let id = try service.store.db.scalarInt("SELECT id FROM items WHERE path = 'photos:A1'")
        do {
            _ = try service.open(String(id), reveal: false)
            Issue.record("opened")
        } catch let failure as ToolFailure {
            #expect(failure.code == "failed")
            #expect(failure.message.contains(says))
        }
        #expect(service.findThumb(String(id)) == nil)   // its thumbnail neither (review of the review leftovers)
        #expect(photos.opened.isEmpty)
        #expect(photos.looked == 0)   // the real library would ask the user at the first lookup
    }

    @Test("#46-2: luoke-core's background state decides while it answers, battery included; without it the setting")
    func batteryFollowsLuokeCore() {
        var asked: [Bool] = []
        func held(_ onBattery: Bool) -> [String] { asked.append(onBattery); return [] }
        // luoke-core lets background work run (on power, or the user lets it run on battery): read, whatever the
        // setting says; only Low Power Mode and heat are still looked at here.
        #expect(Resident.backlogHeld(("running", []), onBattery: false, held: held).isEmpty)
        #expect(asked == [true])
        // luoke-core pauses (on battery, say): not read, even with the setting on.
        #expect(Resident.backlogHeld(("paused", ["battery"]), onBattery: true, held: held) == ["battery"])
        // No answer from luoke-core: the setting.
        asked = []
        _ = Resident.backlogHeld(nil, onBattery: false, held: held)
        _ = Resident.backlogHeld(nil, onBattery: true, held: held)
        #expect(asked == [false, true])
    }

    @Test("#46-2: the resident service never asks luoke-core to run on battery, whatever it was opened with")
    func residentNeverAllowsBattery() throws {
        let scratch = try Scratch()
        let directory = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        let environment = ["LUOKE_HUB_SOCKET": scratch.path + "/hub.sock"]
        let arguments = try CommandArguments(ArraySlice(["--allow-battery"]))
        #expect(arguments.hub(for: directory, background: true, environment: environment)?.allowBattery == false)
        #expect(arguments.hub(for: directory, environment: environment)?.allowBattery == true)   // `index --allow-battery`
    }

    @Test("#46-2: a setup card shown before the default changed still works while no settings are saved")
    func setupCardFromBeforeTheDefault() throws {
        // As the version before left it: the plan made against its default, building on battery power on.
        func madeBefore(_ setup: SetupHome) throws {
            try ToolState.update(setup.directory) { state in
                for index in state.plans.indices { state.plans[index].basis.onBattery = true }
            }
        }
        let setup = try SetupHome()
        let plan = try setup.planID(setup.setup)
        try madeBefore(setup)
        #expect(try setup.planID(setup.setup) == plan)   // the same card stays
        #expect(SetupHome.code(setup.tap(plan)) == nil)
        #expect(Settings.load(setup.directory).folders == Settings.homeScope(home: setup.home).prefix(1).map { $0 })
        // Settings saved since (battery off, the user's own): stale, as any change since.
        let saved = try SetupHome()
        let old = try saved.planID(saved.setup)
        try madeBefore(saved)
        try Settings().save(saved.directory)
        #expect(SetupHome.code(saved.tap(old)) == "stale")
    }

    @Test("#46-7: settings --json with a change prints the JSON alone")
    func settingsJSONWithAChange() throws {
        let setup = try SetupHome()
        let out = try ShippedSettingsTests.run(["--photos", "on", "--json"], setup)
        let settings = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        #expect(settings?["photos"] as? Bool == true)
    }

    @Test("#46-8: folders the app as it ships won't search don't make the first pass done")
    func firstPassOnlyOfFoldersSearched() throws {
        let scratch = try Scratch()
        let directory = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        let store = try IndexStore(directory: directory, home: scratch.path)
        var settings = Settings()
        settings.folders = ["/etc"]
        try settings.save(directory)
        try ToolState.noteFirstPassIfDone(directory, store: store, restricted: true, home: scratch.path)
        #expect(ToolState.load(directory).firstPassDone == nil)
        // A development run searches it.
        try ToolState.noteFirstPassIfDone(directory, store: store, restricted: false, home: scratch.path)
        #expect(ToolState.load(directory).firstPassDone != nil)
    }

    @Test("#46-8: index judges the folders as the app does where it ships, and only after walking the settings' own")
    func indexNotesTheFirstPassAsShipped() throws {
        let scratch = try Scratch()
        let directory = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        let store = try IndexStore(directory: directory, home: scratch.path)
        var settings = Settings()
        settings.folders = ["/etc"]
        try settings.save(directory)
        func index(_ arguments: [String], shipped: Bool) throws -> Bool {
            var parsed = try CommandArguments(ArraySlice(arguments))
            parsed.shipped = shipped
            try ToolState.noteFirstPassAfterIndex(parsed, directory: directory, store: store, home: scratch.path)
            return ToolState.load(directory).firstPassDone != nil
        }
        #expect(try !index([], shipped: true))
        #expect(try !index(["/etc"], shipped: false))   // a folder given, not the settings' walk
        #expect(try index([], shipped: false))          // a development run searches it
    }

    @Test("#46-8: the service and the index command judge the folders as the app does")
    func serviceFirstPassRestricted() throws {
        let scratch = try Scratch()
        let directory = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        let service = try SearchService(directory: directory, hub: nil, home: scratch.path)
        service.restrictFolders = true
        var settings = Settings()
        settings.folders = ["/etc"]
        try settings.save(directory)
        try service.noteFirstPassIfDone()
        #expect(ToolState.load(directory).firstPassDone == nil)
    }
}
