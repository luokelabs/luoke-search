@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
@testable import LuokeSearchKit

/// A film and recordings the tests make themselves, in place of the testbed's: those are made on a developer's Mac
/// from macOS's own pictures and voices (scripts/testbed/make_zh_media.sh), which can't be given away with the code.
/// Made once a run, in a folder of its own under the temporary folder.
enum TestMedia {
    static let folder: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("luoke-search-media-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// 18 seconds, silent, 720 × 720 H.264: three pictures nothing alike, six seconds each (a frame every second).
    static let threePictures: URL = made("three-pictures.mp4") { try film($0, pictures: pictures, seconds: 6) }

    /// About 9 seconds of sound (a tone) in an .m4a: a short memo.
    static let memo: URL = made("memo.m4a") { try recording($0, seconds: 9) }

    /// 68 seconds of sound with no silence in an .m4a: three windows, the last one short.
    static let podcast: URL = made("podcast.m4a") { try recording($0, seconds: 68) }

    private static func made(_ name: String, _ make: (URL) throws -> Void) -> URL {
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        do { try make(url) } catch { fatalError("can't make \(name): \(error)") }
        return url
    }

    /// Black and white halves, each a different way, so an 8×8 average hash tells them far apart.
    static var pictures: [CGImage] {
        let halves: [CGRect] = [CGRect(x: 0, y: 0, width: 360, height: 720), CGRect(x: 0, y: 360, width: 720, height: 360),
                                CGRect(x: 360, y: 0, width: 360, height: 360)]
        return halves.map { black in
            let context = CGContext(data: nil, width: 720, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 720, height: 720))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(black)
            return context.makeImage()!
        }
    }

    static func film(_ url: URL, pictures: [CGImage], seconds: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 720, AVVideoHeightKey: 720,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 720, kCVPixelBufferHeightKey as String: 720,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for (index, picture) in pictures.enumerated() {
            let buffer = try pixels(picture)
            for second in 0..<seconds {
                while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
                adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index * seconds + second), timescale: 1))
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(pictures.count * seconds), timescale: 1))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    static func pixels(_ picture: CGImage) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, picture.width, picture.height, kCVPixelFormatType_32ARGB, nil, &made)
        guard let buffer = made else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: picture.width, height: picture.height,
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        context.draw(picture, in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
        return buffer
    }

    /// A tone, the whole way through, as AAC in an .m4a whose index comes after its sound (as most recorders write it).
    static func recording(_ url: URL, seconds: Int) throws {
        let wav = url.deletingPathExtension().appendingPathExtension("wav")
        try Sound.wav(seconds: Double(seconds), tone: [0...Double(seconds)]).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }
        let asset = AVURLAsset(url: wav)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        session.shouldOptimizeForNetworkUse = false
        let box = UncheckedSession(session)
        try AsyncBridge.wait { try await box.session.export(to: url, as: .m4a) }
        try shortSoundHeader(url)
    }

    /// AVFoundation writes the sound's box (`mdat`) with a 64-bit size; most recorders write a 32-bit one after an
    /// 8-byte `free`, which takes the same 16 bytes, so where the sound is in the file doesn't move.
    static func shortSoundHeader(_ url: URL) throws {
        var bytes = [UInt8](try Data(contentsOf: url))
        func word(_ at: Int, _ count: Int) -> Int { bytes[at..<at + count].reduce(0) { $0 << 8 | Int($1) } }
        var at = 0
        while at + 16 <= bytes.count {
            let size = word(at, 4)
            if size == 1, bytes[at + 4..<at + 8].elementsEqual("mdat".utf8) {
                let short = word(at + 8, 8) - 8
                bytes.replaceSubrange(at..<at + 16, with: [0, 0, 0, 8] + Array("free".utf8)
                    + (0..<4).map { UInt8(truncatingIfNeeded: short >> (24 - 8 * $0)) } + Array("mdat".utf8))
                try Data(bytes).write(to: url)
                return
            }
            guard size >= 8 else { return }
            at += size
        }
    }

    private final class UncheckedSession: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }
}
