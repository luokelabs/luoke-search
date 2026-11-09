import Foundation
import Testing
@testable import LuokeSearchKit

enum Sound {
    /// 16 kHz mono: a 440 Hz tone over `tone` (seconds), silence elsewhere, `seconds` long.
    static func wav(seconds: Double, tone: [ClosedRange<Double>]) -> Data {
        let rate = 16_000.0
        let samples = (0..<Int(seconds * rate)).map { index -> Int16 in
            let time = Double(index) / rate
            guard tone.contains(where: { $0.contains(time) }) else { return 0 }
            return Int16(8000 * sin(2 * .pi * 440 * time))
        }
        return AudioWindows.wav(samples[...])
    }
}

extension ReadsPictures {
    struct MediaTests {
        @Test func soundIsCutIntoWindowsWithoutSilence() throws {
            let scratch = try Scratch()
            // Tone, 35 s of silence, tone: the window from 25 s is silence and is dropped; the tail is kept.
            let file = try scratch.write("memo.wav", data: Sound.wav(seconds: 70, tone: [0...20, 55...70]))
            let reading = Reader.read(file, kind: .audio)
            #expect(reading.outcome == .done)
            #expect(reading.pieces.map(\.kind) == [.audio, .audio])
            #expect(reading.pieces.map(\.loc) == [0, 50])
            #expect(reading.pieces.map(\.locEnd) == [30, 70])
            #expect(reading.pieces.allSatisfy { $0.vector == .media })
            #expect(reading.info["duration"] == "70.0")
        }

        @Test func silentRecording() throws {
            let scratch = try Scratch()
            let file = try scratch.write("quiet.wav", data: Sound.wav(seconds: 10, tone: []))
            let reading = Reader.read(file, kind: .audio)
            #expect(reading.pieces.isEmpty)
            #expect(reading.info["silent"] == "1")
        }

        @Test func wavHeader() {
            let data = AudioWindows.wav([1, -1, 2, -2][...])
            #expect(data.count == 44 + 8)
            #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
            #expect(data.le32(24) == 16_000)   // sample rate
            #expect(data.le16(22) == 1)        // mono
            #expect(data.le16(34) == 16)       // bits
            #expect(data.le32(40) == 8)        // data bytes
        }

        @Test func videoFramesWithoutRepeatsAndTheSameAgain() throws {
            let video = TestMedia.threePictures
            let reading = Reader.read(video, kind: .video)
            #expect(reading.outcome == .done)
            let frames = reading.pieces.filter { $0.kind == .frame }
            #expect(frames.map(\.loc) == [0.5, 6.5, 12.5])   // three pictures; frames like the last one dropped
            // Made again for luoke-core: the same frames, as JPEGs at budget 70.
            let wanted = frames.enumerated().map { MediaInputs.Wanted(segment: Int64($0.offset), kind: .frame,
                                                                      loc: $0.element.loc) }
            let task = HubTask(status: .available)
            let (made, impossible) = MediaInputs.make(path: video.path, kind: .video, wanted: wanted, task: task)
            #expect(impossible.isEmpty)
            #expect(made.count == 3)
            for item in made {
                guard case .image(let data, let budget) = item.input else { Issue.record("not a picture"); continue }
                #expect(budget == 70)
                #expect(data.starts(with: [0xFF, 0xD8]))   // JPEG
            }
        }

        @Test func picturesAreSentAtTheirBudgets() throws {
            let scratch = try Scratch()
            let shot = try scratch.write("Screenshot 2026-10-01 at 10.00.00.png", data: Drawn.png(Drawn.picture(["x"])))
            let photo = try scratch.write("IMG_1.jpg", data: Drawn.photo(taken: "2026:09:14 10:02:00", offset: "+08:00"))
            let task = HubTask(status: .available)
            let one = MediaInputs.Wanted(segment: 1, kind: .image, loc: nil)
            guard case .image(let png, 280)? = MediaInputs.make(path: shot.path, kind: .screenshot, wanted: [one],
                                                                 task: task).made.first?.input,
                  case .image(let jpeg, 140)? = MediaInputs.make(path: photo.path, kind: .image, wanted: [one],
                                                                  task: task).made.first?.input else {
                Issue.record("wrong inputs")
                return
            }
            #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
            #expect(jpeg.starts(with: [0xFF, 0xD8]))
        }

        @Test func limitsAreKept() {
            var task = HubTask(status: .available)
            task.maxAudioSecs = 10
            task.maxImageBytes = 10
            #expect(MediaInputs.tooBig(.audio(Sound.wav(seconds: 12, tone: [0...12])), task: task) != nil)
            #expect(MediaInputs.tooBig(.audio(Sound.wav(seconds: 8, tone: [0...8])), task: task) == nil)
            #expect(MediaInputs.tooBig(.image(Data(count: 11), budget: 140), task: task) != nil)
            task.imageBatch = 8
            task.imageBudgets = [70, 140]
            #expect(MediaInputs.taken(.image(Data(), budget: 140), by: task))
            #expect(!MediaInputs.taken(.image(Data(), budget: 280), by: task))
            #expect(!MediaInputs.taken(.audio(Data()), by: task))   // audio_batch 0: no sound on this tier
        }

        /// A library of a screenshot, a photo and a recording, read; and a fake luoke-core.
        /// Holds the scratch folder for as long as the test uses the index in it.
        final class Media {
            let scratch: Scratch, store: IndexStore, fake: FakeHub, hub: Hub
            init(_ scratch: Scratch, _ store: IndexStore, _ fake: FakeHub) {
                self.scratch = scratch
                self.store = store
                self.fake = fake
                hub = Hub(socket: fake.path, environment: [:])
            }
        }

        func library() throws -> Media {
            let scratch = try Scratch()
            try scratch.write("files/Screenshot 2026-10-11 at 15.12.08.png",
                              data: Drawn.png(Drawn.picture(["付款失败：余额不足"])))
            try scratch.write("files/IMG_2001.jpg", data: Drawn.photo(taken: "2026:09:14 10:02:00", offset: "+08:00"))
            try scratch.write("files/memo.wav", data: Sound.wav(seconds: 40, tone: [0...40]))
            let store = try scratch.store()
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([scratch.path + "/files"])
            try indexer.readPending()
            return Media(scratch, store, try FakeHub())
        }

        @Test func picturesAndSoundGetVectorsWhenTheHubTakesThem() throws {
            let media = try library()
            let (store, fake, hub) = (media.store, media.fake, media.hub)
            #expect(try store.counts().waitingForMedia == 3)
            let textOnly = VectorFiller(store: store, hub: hub).run(wait: false)
            #expect(textOnly.embeddedMedia == 0)                  // a text-only tier: they keep waiting
            #expect(try store.counts().waitingForMedia == 3)
            fake.takesMedia = true
            let report = VectorFiller(store: store, hub: hub).run(wait: false)
            #expect(report.embeddedMedia == 4)                    // screenshot, photo, two sound windows
            #expect(report.mediaFailed == 0)
            #expect(try store.counts().waitingForMedia == 0)
            let budgets = fake.inputRequests.flatMap { $0 }.compactMap { $0["budget"] as? Int }.sorted()
            #expect(budgets == [140, 280])
            #expect(fake.inputRequests.allSatisfy { inputs in inputs.filter { $0["audio"] != nil }.count <= 2 })
            withExtendedLifetime(media) {}
        }

        @Test func soundTheHubCantReadFailsAlone() throws {
            let media = try library()
            let (store, fake, hub) = (media.store, media.fake, media.hub)
            fake.takesMedia = true
            fake.failAudio = true
            let report = VectorFiller(store: store, hub: hub).run(wait: false)
            #expect(report.embeddedMedia == 2)
            #expect(report.mediaFailed == 2)
            #expect(try store.counts().waitingForMedia == 0)       // given up: never asked again
            withExtendedLifetime(media) {}
        }

        @Test func aBudgetThisTierDoesntTakeWaits() throws {
            let media = try library()
            let (store, fake, hub) = (media.store, media.fake, media.hub)
            fake.takesMedia = true
            fake.imageBudgets = [70, 140]
            let report = VectorFiller(store: store, hub: hub).run(wait: false)
            #expect(report.embeddedMedia == 3)                    // the photo and the sound
            #expect(try store.counts().waitingForMedia == 1)       // the screenshot (280) waits for a tier that takes it
            withExtendedLifetime(media) {}
        }
    }
}

struct AudioProbeTests {
    @Test("probe-audio reads back what a window sends: 16 kHz mono 16-bit, its length, how much is quiet")
    func windowFormat() {
        // One second of a tone, then one of silence.
        let tone = (0..<16_000).map { Int16(8_000 * sin(Double($0) * 2 * .pi * 440 / 16_000)) }
        let wav = AudioWindows.wav((tone + [Int16](repeating: 0, count: 16_000))[...])
        let format = AudioProbe.format(wav)
        #expect(format.rate == 16_000 && format.channels == 1 && format.bits == 16)
        #expect(abs(format.seconds - 2) < 0.001)
        #expect(abs(format.quiet - 0.5) < 0.03)
        #expect(format.rms > -20 && format.rms < -10)
    }

    @Test("probe-audio gives each window the parts of the transcript said mostly inside it")
    func transcriptParts() throws {
        // The podcast: topics at 0–27, 27–48.7, 48.7–68 s; windows 0–30, 25–55, 50–68.
        let parts = try JSONDecoder().decode([AudioProbe.Part].self, from: Data("""
            [{"from": 0, "to": 27, "text": "local"}, {"from": 27, "to": 48.7, "text": "sleep"},
             {"from": 48.7, "to": 68, "text": "knee"}]
            """.utf8))
        func said(_ from: Double, _ to: Double) -> [String] {
            parts.filter { AudioProbe.mostlyInside($0, from: from, to: to) }.map(\.text)
        }
        #expect(said(0, 30) == ["local"] && said(25, 55) == ["sleep"] && said(50, 68) == ["knee"])
        // A whole file's words belong to every window of it.
        let whole = AudioProbe.Part(from: 0, to: 600, text: "all")
        #expect(AudioProbe.mostlyInside(whole, from: 25, to: 55))
    }
}
