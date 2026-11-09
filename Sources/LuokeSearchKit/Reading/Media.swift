@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// Sound and video, with AVFoundation (mp4, mov, m4v, 3gp, m4a, mp3, wav, aiff, caf, flac, aac…; formats it can't
/// open fail with a reason). Nothing is transcribed: a recording is found by what it sounds like, through its vector,
/// once luoke-core takes sound.
///
/// - Sound is cut into 30-second windows, one starting every 25 seconds, as 16 kHz mono 16-bit samples; windows that
///   are silence (RMS ≤ 0.003, about −50 dBFS) are dropped, and a tail shorter than 2 s isn't a window of its own.
///   Read as a stream: a three-hour podcast never holds more than one window in memory.
/// - Video gives a frame every 3 seconds (at most 1200: longer videos space them out), dropping frames that look
///   like the last one kept (8×8 average hash within 4 bits); its sound is windowed as above.
///
/// Neither pixels nor samples are stored: when luoke-core takes pictures and sound, the file is read again and the
/// same windows and frames come out (`MediaInputs`).
enum MediaReading {
    static let sampleRate = 16_000.0
    static let window = 30.0
    static let hop = 25.0
    static let shortest = 2.0
    static let silence: Float = 0.003
    static let frameInterval = 3.0
    static let maxFrames = 1200
    static let framePixels = 1024
    /// Why a film that gives neither pictures nor sound fails; why one with pictures none of which could be decoded
    /// fails; and why one with no pictures failed before its sound was read alone (those are read again, once:
    /// `IndexStore.requeueOlderReaders`).
    static let noPicturesNorSound = "no pictures or sound in this video"
    static let picturesUndecoded = "none of this video's pictures could be decoded"
    static let noPicturesBefore = "no pictures in this video"

    static func audio(_ url: URL) -> Reading {
        do {
            var reading = Reading()
            var pieces: [Piece] = []
            let duration = try AsyncBridge.wait {
                try await AudioWindows.scan(url) { start, end, _ in
                    pieces.append(Piece(kind: .audio, loc: start, locEnd: end, text: "", vector: .media))
                }
            }
            reading.pieces = pieces
            reading.info["duration"] = String(format: "%.1f", duration)
            reading.taken = try? AsyncBridge.wait { try await creationDate(url) }
            if pieces.isEmpty { reading.info["silent"] = "1" }
            return reading
        } catch {
            return Reading(outcome: .failed(describe(error)))
        }
    }

    static func video(_ url: URL) -> Reading { video(AVURLAsset(url: url)) }

    /// A film's frames and sound: a file's in a folder, or a video's in the Photos library (`PhotoIndexing.read`).
    static func video(_ asset: AVAsset) -> Reading {
        do {
            var reading = Reading()
            var frames: [Piece] = []
            let (duration, size) = try AsyncBridge.wait {
                try await Keyframes.scan(asset) { time, _ in
                    frames.append(Piece(kind: .frame, loc: time, text: "", vector: .media))
                }
            }
            // Pictures there, none decoded (a codec this Mac can't play, a damaged file): it fails as it did. Read for
            // its sound it would be done, and its pictures never read again.
            if frames.isEmpty, size != nil { return Reading(outcome: .failed(picturesUndecoded)) }
            var sound: [Piece] = []
            var heard = 0.0
            do {
                heard = try AsyncBridge.wait {
                    try await AudioWindows.scan(asset) { start, end, _ in
                        sound.append(Piece(kind: .audio, loc: start, locEnd: end, text: "", vector: .media))
                    }
                }
            } catch {
                // No pictures (a recording kept in a film's file): read as a recording is, so a decoding error fails
                // it rather than leaving it done with the rest never heard (review 11-02). With pictures, what was
                // heard before the error stays, as it always has.
                guard !frames.isEmpty else { return Reading(outcome: .failed(describe(error))) }
            }
            // No pictures: its sound alone (luoke-search#46, defect 5); neither, a failure.
            guard !frames.isEmpty || heard > 0 else { return Reading(outcome: .failed(noPicturesNorSound)) }
            reading.pieces = frames + sound
            reading.info["duration"] = String(format: "%.1f", duration)
            if reading.pieces.isEmpty { reading.info["silent"] = "1" }
            if let size {
                reading.info["width"] = String(Int(size.width))
                reading.info["height"] = String(Int(size.height))
            }
            reading.taken = try? AsyncBridge.wait { try await creationDate(asset) }
            return reading
        } catch {
            return Reading(outcome: .failed(describe(error)))
        }
    }

    static func describe(_ error: Error) -> String {
        if let failure = error as? Pictures.Failure { return failure.description }
        return "can't read this file (\((error as NSError).localizedDescription))"
    }

    /// When it was recorded, if the file says (its creation-date metadata).
    static func creationDate(_ url: URL) async throws -> Double? { try await creationDate(AVURLAsset(url: url)) }

    static func creationDate(_ asset: AVAsset) async throws -> Double? {
        guard let item = try await asset.load(.creationDate) else { return nil }
        return try await item.load(.dateValue)?.timeIntervalSince1970
    }
}

/// The 30-second windows of a file's sound, in order. `emit` gets each window that isn't silence: its start and end
/// in seconds and its samples. Returns the duration.
enum AudioWindows {
    static func scan(_ url: URL, emit: (Double, Double, ArraySlice<Int16>) throws -> Void) async throws -> Double {
        try await scan(AVURLAsset(url: url) as AVAsset, emit: emit)
    }

    /// The same for sound that isn't a file of its own (a video in the Photos library).
    static func scan(_ asset: AVAsset, emit: (Double, Double, ArraySlice<Int16>) throws -> Void) async throws -> Double {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return 0 }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Pictures.Failure(description: "can't read the sound") }
        let rate = MediaReading.sampleRate
        let windowSamples = Int(MediaReading.window * rate), hopSamples = Int(MediaReading.hop * rate)
        var buffer: [Int16] = []
        var offset = 0   // which sample of the file buffer[0] is
        func send(_ count: Int) throws {
            let slice = buffer[0..<count]
            guard rms(slice) > MediaReading.silence else { return }
            try emit(Double(offset) / rate, Double(offset + count) / rate, slice)
        }
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Int16](repeating: 0, count: length / 2)
            _ = chunk.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            buffer.append(contentsOf: chunk)
            while buffer.count >= windowSamples {
                try send(windowSamples)
                buffer.removeFirst(hopSamples)
                offset += hopSamples
            }
        }
        if reader.status == .failed { throw reader.error ?? Pictures.Failure(description: "can't decode the sound") }
        // The tail: what's new after the last window's overlap, or the whole file when it's shorter than a window.
        let covered = offset == 0 ? 0 : windowSamples - hopSamples
        if buffer.count - covered >= Int(MediaReading.shortest * rate) { try send(buffer.count) }
        return duration.isFinite ? duration : Double(offset + buffer.count) / rate
    }

    /// 16 kHz mono 16-bit.
    static var pcm: [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: MediaReading.sampleRate, AVNumberOfChannelsKey: 1,
         AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
         AVLinearPCMIsNonInterleaved: false]
    }

    /// One window's samples, `seconds` from `start`, decoded on their own (made again for luoke-core without
    /// decoding everything before it).
    static func samples(_ asset: AVAsset, track: AVAssetTrack, from start: Double, seconds: Double) throws -> [Int16] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000),
                                       duration: CMTime(seconds: seconds, preferredTimescale: 48_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Pictures.Failure(description: "can't read the sound") }
        let wanted = Int(seconds * MediaReading.sampleRate)
        var out: [Int16] = []
        out.reserveCapacity(wanted)
        while out.count < wanted, let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Int16](repeating: 0, count: length / 2)
            _ = chunk.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            out.append(contentsOf: chunk.prefix(wanted - out.count))
        }
        if reader.status == .failed { throw reader.error ?? Pictures.Failure(description: "can't decode the sound") }
        reader.cancelReading()
        guard !out.isEmpty else { throw Pictures.Failure(description: "the sound isn't there any more") }
        return out
    }

    static func rms(_ samples: ArraySlice<Int16>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            let value = Float(sample) / 32768
            sum += value * value
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// 16 kHz mono 16-bit PCM in a WAV container, as luoke-core takes sound.
    static func wav(_ samples: ArraySlice<Int16>) -> Data {
        var data = Data()
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put32(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16); put16(1); put16(1)
        put32(UInt32(MediaReading.sampleRate)); put32(UInt32(MediaReading.sampleRate) * 2); put16(2); put16(16)
        data.append(contentsOf: Array("data".utf8)); put32(bytes)
        samples.withUnsafeBytes { raw in
            for index in stride(from: 0, to: raw.count, by: 2) {
                let value = raw.load(fromByteOffset: index, as: UInt16.self)
                put16(value)
            }
        }
        return data
    }
}

/// A video's frames, one every 3 seconds, skipping those that look like the last one kept. `keep` gets each frame
/// kept (its time and the picture, at most 1024 px). Returns the duration and the picture size.
enum Keyframes {
    static func scan(_ url: URL, keep: (Double, CGImage) throws -> Void) async throws -> (Double, CGSize?) {
        try await scan(AVURLAsset(url: url) as AVAsset, keep: keep)
    }

    /// The same for a video that isn't a file of its own (in the Photos library).
    static func scan(_ asset: AVAsset, keep: (Double, CGImage) throws -> Void) async throws -> (Double, CGSize?) {
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              let track = try await asset.loadTracks(withMediaType: .video).first else {
            return (duration.isFinite ? duration : 0, nil)
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let size = natural.applying(transform)
        let step = max(MediaReading.frameInterval, duration / Double(MediaReading.maxFrames))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: MediaReading.framePixels, height: MediaReading.framePixels)
        let tolerance = CMTime(seconds: step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = times(duration: duration).map { CMTime(seconds: $0, preferredTimescale: 600) }
        var last: UInt64?
        for await result in generator.images(for: times) {
            guard case let .success(requested, image, _) = result else { continue }
            let hash = averageHash(image)
            if let last, (hash ^ last).nonzeroBitCount <= 4 { continue }
            last = hash
            // The requested time, not the decoded one: reading again must give the same times.
            try keep((requested.seconds * 10).rounded() / 10, image)
        }
        return (duration, CGSize(width: abs(size.width), height: abs(size.height)))
    }

    /// Where frames are taken: half a second in (a first frame is often black), then every 3 s.
    static func times(duration: Double) -> [Double] {
        let step = max(MediaReading.frameInterval, duration / Double(MediaReading.maxFrames))
        return Array(stride(from: min(0.5, duration / 2), to: duration, by: step))
    }

    /// 64 bits: which of the 8 × 8 grey cells is brighter than their mean.
    static func averageHash(_ image: CGImage) -> UInt64 {
        var pixels = [UInt8](repeating: 0, count: 64)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: 8, height: 8, bitsPerComponent: 8,
                                          bytesPerRow: 8, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            return true
        }
        guard drawn else { return 0 }
        let mean = pixels.reduce(0) { $0 + Int($1) } / 64
        return pixels.enumerated().reduce(UInt64(0)) { hash, pixel in
            Int(pixel.element) > mean ? hash | (1 << UInt64(pixel.offset)) : hash
        }
    }
}

/// Runs async work (AVFoundation's loading) from synchronous reading code and waits for it. Reading runs on threads
/// of its own, so waiting here never holds up Swift concurrency's pool, where the work itself runs.
enum AsyncBridge {
    private final class Box<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    static func wait<T>(_ work: @escaping () async throws -> T) throws -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        let unchecked = UncheckedWork(work)
        Task.detached {
            do { box.result = .success(try await unchecked.work()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }

    /// The work and what it captures stay with the waiting caller, which does nothing until it's done.
    private struct UncheckedWork<T>: @unchecked Sendable {
        let work: () async throws -> T
        init(_ work: @escaping () async throws -> T) { self.work = work }
    }
}
