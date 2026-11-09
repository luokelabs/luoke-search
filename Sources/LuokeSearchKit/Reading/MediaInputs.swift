@preconcurrency import AVFoundation
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// The pictures and sound luoke-core is sent for an item's waiting segments, made again from the file (neither pixels
/// nor samples are kept in the index): the same windows and frames come out as when it was read.
///
/// What is sent (luoke-core's multimodal draft, agreed with digup): the small copies made here, not pre-shrunk to
/// the budget (luoke-core's image processor shrinks once, and shrinking twice moved vectors off the reference):
///
/// | segment | picture | budget |
/// |---|---|---|
/// | a photo or picture | JPEG, ≤ 1024 px | 140 |
/// | a screenshot | PNG, ≤ 1536 px | 280 |
/// | a scanned PDF page | PNG, 1400 px wide | 280 |
/// | a video frame | JPEG, ≤ 1024 px | 70 |
/// | a sound window | WAV, 16 kHz mono 16-bit, ≤ 30 s | — |
///
/// They're made one at a time (`Source`): however long the recording or the scanned PDF, no more than one input is
/// held here (review B-03).
public enum MediaInputs {
    public struct Wanted: Sendable {
        public let segment: Int64
        public let kind: SegmentKind
        public let loc: Double?
        /// Where a window of sound ends (the last one may be shorter than 30 s).
        public let locEnd: Double?

        public init(segment: Int64, kind: SegmentKind, loc: Double?, locEnd: Double? = nil) {
            self.segment = segment
            self.kind = kind
            self.loc = loc
            self.locEnd = locEnd
        }
    }

    public struct Made: Sendable {
        public let segment: Int64
        public let input: Hub.Input
    }

    /// What making one wanted input came to.
    public enum Outcome: Sendable {
        case made(Made)
        /// It never can be: the page isn't there, another file is in its place.
        case impossible(Int64, String)
        /// Not this time (the file couldn't be decoded just now): counted, given up after a few tries.
        case failedForNow(Int64, String)
        /// Waits without counting: not on this Mac (its drive unplugged, its contents only in iCloud), no library in
        /// this process, or too large for this tier.
        case later(Int64, String)

        var segment: Int64 {
            switch self {
            case .made(let made): made.segment
            case .impossible(let segment, _), .failedForNow(let segment, _), .later(let segment, _): segment
            }
        }
    }

    /// The budget a wanted picture is sent at (nil for sound).
    static func budget(_ want: Wanted, kind: ItemKind) -> Int? {
        switch want.kind {
        case .page: 280
        case .frame: 70
        case .image: kind == .screenshot ? 280 : 140
        default: nil
        }
    }

    /// Whether the file at `path` is on this Mac now: there (its drive not unplugged), its contents not only in
    /// iCloud (as `Indexer.isHere`; `isDataless` swapped in tests).
    static func isHere(_ path: String, isDataless: (stat) -> Bool) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && !isDataless(info)
    }

    /// One item's inputs, made as they're asked for. Pictures (pages, images) first, then frames, then windows.
    public final class Source {
        let path: String
        let kind: ItemKind
        /// The file's inode when it was listed (nil: not checked): pictures are made only from that file
        /// (`Indexer.isListed`).
        let inode: UInt64?
        let task: HubTask
        let photos: PhotoSource?
        /// Whether a file's contents are only in iCloud (as `Crawler.isDataless`); swapped in tests.
        var isDataless: (stat) -> Bool = { $0.st_flags & Crawler.datalessFlag != 0 }
        private var queue: [Wanted]
        private let photo: String?
        private var pdf: PDFDocument?
        private var asset: AVAsset?
        private var generator: AVAssetImageGenerator?
        private var soundTrack: AVAssetTrack?

        public init(path: String, kind: ItemKind, wanted: [Wanted], task: HubTask, photos: PhotoSource?,
                    inode: UInt64? = nil) {
            self.path = path
            self.kind = kind
            self.inode = inode
            self.task = task
            self.photos = photos
            photo = PhotoPath.id(path)
            queue = wanted.filter { $0.kind == .image || $0.kind == .page } + wanted.filter { $0.kind == .frame }
                + wanted.filter { $0.kind == .audio }
        }

        var url: URL { URL(fileURLWithPath: path) }

        /// The next wanted segment's input, or why there isn't one; nil when all have been made.
        public func next() -> Outcome? {
            guard !queue.isEmpty else { return nil }
            let want = queue.removeFirst()
            if photo != nil {
                return photos == nil ? .later(want.segment, "no Photos library in this process") : make(want)
            }
            // Not on this Mac now (its drive unplugged, its contents only in iCloud): not opened (that would download
            // it) nor given up on. It waits until the file is here again, as the Photos library's do. (One really gone
            // is removed by the walk that sees it gone.)
            guard isHere else { return .later(want.segment, IndexStore.notHere) }
            if let other = notListed(want) { return other }
            let made = make(want)
            // Unplugged while it was made: it waits, as above, whatever came of it.
            guard isHere else { return .later(want.segment, IndexStore.notHere) }
            return notListed(want) ?? made
        }

        var isHere: Bool { MediaInputs.isHere(path, isDataless: isDataless) }

        /// From the file listed, before and after: a picture of another file put in its place isn't sent. Nil when it's
        /// that file (or no inode was given). Not there to look at (unplugged just now): it waits, as above.
        private func notListed(_ want: Wanted) -> Outcome? {
            guard let inode, !Indexer.isListed(path, inode: inode) else { return nil }
            return isHere ? .impossible(want.segment, Indexer.notListed) : .later(want.segment, IndexStore.notHere)
        }

        private func make(_ want: Wanted) -> Outcome {
            do {
                switch want.kind {
                case .page:
                    return fitting(try pagePicture(Int(want.loc ?? 1)), as: .png, budget: 280, want.segment)
                case .image:
                    if let photo, let photos {
                        return fitting(try photos.image(photo, maxPixels: 1024), as: .jpeg, budget: 140, want.segment)
                    }
                    return kind == .screenshot
                        ? fitting(try Pictures.image(url, maxPixels: 1536), as: .png, budget: 280, want.segment)
                        : fitting(try Pictures.image(url, maxPixels: 1024), as: .jpeg, budget: 140, want.segment)
                case .frame:
                    return fitting(try frame(at: want.loc ?? 0), as: .jpeg, budget: 70, want.segment)
                case .audio:
                    let input = Hub.Input.audio(AudioWindows.wav(try window(want)[...]))
                    if let problem = tooBig(input, task: task) { return .later(want.segment, problem) }
                    return .made(Made(segment: want.segment, input: input))
                default:
                    return .impossible(want.segment, "not a picture or a sound")
                }
            } catch is SystemPhotos.NotOnThisMac {
                return .later(want.segment, "only in iCloud")
            } catch let failure as SystemPhotos.Failure {
                return .impossible(want.segment, failure.description)
            } catch let failure as NoSuchPlace {
                return .impossible(want.segment, failure.description)
            } catch {
                return .failedForNow(want.segment, Reader.describe(error))
            }
        }

        /// The picture encoded as its kind is sent; over this tier's byte limit, as a JPEG, then at half the size.
        /// Still over: it waits for a tier that takes it (it isn't given up). Always on white: a PNG kept transparency
        /// the JPEGs don't have, so the same screenshot went one way or the other by its size.
        func fitting(_ picture: CGImage, as type: UTType, budget: Int, _ segment: Int64) -> Outcome {
            let opaque: Set<CGImageAlphaInfo> = [.none, .noneSkipFirst, .noneSkipLast]
            let image = opaque.contains(picture.alphaInfo) ? picture : Self.scaled(picture, by: 1) ?? picture
            var tries: [(CGImage, UTType)] = [(image, type)]
            if type != .jpeg { tries.append((image, .jpeg)) }
            if let half = Self.scaled(image, by: 0.5) { tries.append((half, .jpeg)) }
            for (picture, kind) in tries {
                guard let data = try? Pictures.encode(picture, as: kind) else { continue }
                let input = Hub.Input.image(data, budget: budget)
                if MediaInputs.tooBig(input, task: task) == nil { return .made(Made(segment: segment, input: input)) }
            }
            return .later(segment, "picture too large for luoke-core")
        }

        /// On white, as the JPEG of the whole picture is: a transparent background drawn on nothing came out black.
        static func scaled(_ image: CGImage, by factor: Double) -> CGImage? {
            let width = max(1, Int(Double(image.width) * factor)), height = max(1, Int(Double(image.height) * factor))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            let frame = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(frame)
            context.interpolationQuality = .high
            context.draw(image, in: frame)
            return context.makeImage()
        }

        struct NoSuchPlace: Error, CustomStringConvertible {
            let description: String
        }

        /// The PDF opened once for all its pages.
        func pagePicture(_ number: Int) throws -> CGImage {
            if pdf == nil { pdf = PDFDocument(url: url) }
            guard let document = pdf else { throw Pictures.Failure(description: "can't open the PDF") }
            guard let page = document.page(at: number - 1) else { throw NoSuchPlace(description: "no such page") }
            guard let image = PDFReading.render(page, pixels: PDFReading.renderPixels) else {
                throw Pictures.Failure(description: "can't draw the page")
            }
            return image
        }

        func video() throws -> AVAsset {
            if let asset { return asset }
            let made: AVAsset
            if let photo, let photos { made = try photos.video(photo) } else { made = AVURLAsset(url: url) }
            asset = made
            return made
        }

        /// One frame, at the time it was taken when read (with the same tolerance as `Keyframes`).
        func frame(at seconds: Double) throws -> CGImage {
            let asset = try video()
            if generator == nil {
                let duration = try AsyncBridge.wait { try await asset.load(.duration).seconds }
                let step = max(MediaReading.frameInterval, (duration.isFinite ? duration : 0) / Double(MediaReading.maxFrames))
                let made = AVAssetImageGenerator(asset: asset)
                made.appliesPreferredTrackTransform = true
                made.maximumSize = CGSize(width: MediaReading.framePixels, height: MediaReading.framePixels)
                let tolerance = CMTime(seconds: step / 2, preferredTimescale: 600)
                made.requestedTimeToleranceBefore = tolerance
                made.requestedTimeToleranceAfter = tolerance
                generator = made
            }
            let generator = UncheckedGenerator(generator!)
            return try AsyncBridge.wait {
                try await generator.value.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            }
        }

        /// One window of sound, read on its own (review B-03: never the whole file's windows at once).
        func window(_ want: Wanted) throws -> [Int16] {
            let asset = try video()
            let start = want.loc ?? 0
            let length = min(MediaReading.window, max((want.locEnd ?? start + MediaReading.window) - start, 0.1))
            if soundTrack == nil {
                guard let track = try AsyncBridge.wait({ try await asset.loadTracks(withMediaType: .audio).first }) else {
                    throw Pictures.Failure(description: "no sound")
                }
                soundTrack = track
            }
            return try AudioWindows.samples(asset, track: soundTrack!, from: start, seconds: length)
        }
    }

    /// The generator stays with the waiting caller, which does nothing until the frame is made.
    struct UncheckedGenerator: @unchecked Sendable {
        let value: AVAssetImageGenerator
        init(_ value: AVAssetImageGenerator) { self.value = value }
    }

    /// What could be made for `wanted` of the item at `path`, and the segments that can't be now or ever (with why).
    /// Those that wait (not on this Mac, no library here, too large for this tier) are in neither.
    public static func make(path: String, kind: ItemKind, wanted: [Wanted], task: HubTask, photos: PhotoSource? = nil)
        -> (made: [Made], impossible: [(Int64, String)]) {
        let source = Source(path: path, kind: kind, wanted: wanted, task: task, photos: photos)
        var made: [Made] = [], impossible: [(Int64, String)] = []
        while let outcome = autoreleasepool(invoking: { source.next() }) {
            switch outcome {
            case .made(let input): made.append(input)
            case .impossible(let segment, let why), .failedForNow(let segment, let why): impossible.append((segment, why))
            case .later: break
            }
        }
        return (made, impossible)
    }

    /// Over one of the task's limits: never sent (luoke-core would refuse the whole request).
    static func tooBig(_ input: Hub.Input, task: HubTask) -> String? {
        switch input {
        case .image(let data, _):
            if let limit = task.maxImageBytes, data.count > limit { return "picture too large for luoke-core" }
        case .audio(let data):
            if let limit = task.maxAudioBytes, data.count > limit { return "sound too large for luoke-core" }
            let seconds = Double(max(data.count - 44, 0)) / (MediaReading.sampleRate * 2)
            if seconds > task.maxAudioSecs + 0.01 { return "sound too long for luoke-core" }
        case .text:
            break
        }
        return nil
    }

    /// Whether this tier takes the input at all (its kind, and for a picture its budget).
    static func taken(_ input: Hub.Input, by task: HubTask) -> Bool {
        switch input {
        case .image(_, let budget): task.takesImages && (task.imageBudgets?.contains(budget) ?? true)
        case .audio: task.takesAudio
        case .text: true
        }
    }

    /// Whether this tier takes what `want` would be, before making it.
    static func taken(_ want: Wanted, kind: ItemKind, by task: HubTask) -> Bool {
        guard let budget = budget(want, kind: kind) else { return task.takesAudio }
        return task.takesImages && (task.imageBudgets?.contains(budget) ?? true)
    }
}
