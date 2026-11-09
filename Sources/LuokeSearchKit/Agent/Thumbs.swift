@preconcurrency import AVFoundation
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Small pictures of results for the window's list (agent tool protocol §1b, the Image rules): the resource
/// `thumb/<item>`, which the agent reads and hands to the window, where it's held in memory only. Made from the file
/// (or the Photos library) each time it's asked for; nothing is kept here either.
extension SearchService {
    static let thumbPrefix = "thumb/"
    /// The kinds that have one: a picture, a screenshot or a photo itself, a video's frame, a PDF's first page.
    static let thumbKinds: Set<ItemKind> = [.image, .screenshot, .photo, .video, .pdf]
    /// How long a thumbnail may take (`thumbWait`): within the agent's 10 s for reading a resource.
    static let thumbTimeout: TimeInterval = 2
    /// The video files AVFoundation opens (an .mkv or a .webm is indexed by its name, but has no frame to show).
    static let playable = Set(AVURLAsset.audiovisualTypes().map(\.rawValue))

    /// The thumbnail a result has, by its item (a PDF's is its first page, whichever page the result points at).
    /// None for SVG (the window doesn't take it, and drawing it is AppKit's, not ImageIO's) or a video file
    /// AVFoundation can't open.
    static func thumbID(_ hit: Hit) -> String? {
        guard thumbKinds.contains(hit.kind), let item = hit.id.split(separator: "#").first else { return nil }
        if let path = hit.path, !drawable(path, kind: hit.kind) { return nil }
        return thumbPrefix + item
    }

    static func drawable(_ path: String, kind: ItemKind) -> Bool {
        let type = (path as NSString).pathExtension.lowercased()
        if type == "svg" { return false }
        guard kind == .video else { return true }
        return UTType(filenameExtension: type).map { playable.contains($0.identifier) } ?? false
    }

    /// `thumb/<item>`: inside the server's lock, what the item is (from the index); nil when it isn't there any more,
    /// has no picture, or its file's contents are only in iCloud (reading it would download it, as the crawler
    /// knows). What it gives makes the JPEG outside the lock, at most `thumbSlots` at a time: nil when they're all
    /// taken (the window shows its placeholder) or it took more than `thumbWait`. One that took too long keeps its
    /// slot until it ends, so no more threads than that are ever drawing.
    public func findThumb(_ item: String) -> (() -> Data?)? {
        guard let number = Int64(item), number > 0, String(number) == item, let target = try? target(item),
              Self.thumbKinds.contains(target.kind) else { return nil }
        if PhotoPath.id(target.path) == nil {
            var info = stat()
            guard Self.drawable(target.path, kind: target.kind), lstat(target.path, &info) == 0, !isDataless(info)
            else { return nil }
        }
        let photos = photos, slots = thumbSlots, wait = thumbWait
        return {
            guard slots.wait(timeout: .now()) == .success else { return nil }
            final class Box: @unchecked Sendable { var data: Data? }
            let box = Box(), done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                box.data = autoreleasepool { Thumbs.make(target, photos: photos) }
                slots.signal()
                done.signal()
            }
            guard done.wait(timeout: .now() + wait) == .success else { return nil }
            return box.data
        }
    }
}

enum Thumbs {
    /// Long side, in pixels: a list's thumbnail on a Retina screen, well under the window's 2048.
    static let pixels = 400
    /// The window's limit for one picture.
    static let maxBytes = 256 * 1024

    static func make(_ target: SearchService.Target, photos: PhotoSource?) -> Data? {
        guard let image = try? picture(target, photos: photos) else { return nil }
        return jpeg(image)
    }

    static func picture(_ target: SearchService.Target, photos: PhotoSource?) throws -> CGImage? {
        if let photo = PhotoPath.id(target.path) {
            guard let photos else { return nil }
            return target.kind == .video ? try frame(photos.video(photo)) : try photos.image(photo, maxPixels: pixels)
        }
        let url = URL(fileURLWithPath: target.path)
        switch target.kind {
        case .image, .screenshot:
            return try Pictures.image(url, maxPixels: pixels)
        case .pdf:
            // A locked one would draw blank: the window's placeholder says more.
            guard let document = PDFDocument(url: url), !document.isLocked, let page = document.page(at: 0) else {
                return nil
            }
            // `render` takes a width: an upright page drawn `pixels` wide would only be shrunk again.
            let box = page.bounds(for: .mediaBox)
            let (width, height) = page.rotation % 180 != 0 ? (box.height, box.width) : (box.width, box.height)
            guard width > 0, height > 0 else { return nil }
            return PDFReading.render(page, pixels: max(1, Int((Double(pixels) * min(1, width / height)).rounded())))
        case .video:
            return try frame(AVURLAsset(url: url))
        default:
            return nil
        }
    }

    /// A frame a second in (the very first is often black), or halfway through a shorter one.
    static func frame(_ asset: AVAsset) throws -> CGImage {
        let duration = try AsyncBridge.wait { try await asset.load(.duration).seconds }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let at = CMTime(seconds: duration.isFinite ? min(1, duration / 2) : 0, preferredTimescale: 600)
        let unchecked = MediaInputs.UncheckedGenerator(generator)
        return try AsyncBridge.wait { try await unchecked.value.image(at: at).image }
    }

    /// On white (a screenshot's transparent shadow would come out black), at most `pixels` on its long side, as a
    /// JPEG within `maxBytes`: at a lower quality, then at half the size, if need be.
    static func jpeg(_ image: CGImage) -> Data? {
        for (side, quality) in [(pixels, 0.8), (pixels, 0.6), (pixels / 2, 0.6)] {
            guard let flat = flattened(image, longSide: side),
                  let data = try? Pictures.encode(flat, as: .jpeg, quality: quality) else { return nil }
            if data.count <= maxBytes { return data }
        }
        return nil
    }

    static func flattened(_ image: CGImage, longSide: Int) -> CGImage? {
        let scale = min(1, Double(longSide) / Double(max(image.width, image.height, 1)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
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
}
