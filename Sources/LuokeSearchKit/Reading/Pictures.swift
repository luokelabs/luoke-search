import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Pictures: opening any format ImageIO knows (HEIC, WebP, AVIF, RAW…), small copies to send to luoke-core, what the
/// file says about itself (size, when it was taken), and the text in it (Vision OCR, the system's).
enum Pictures {
    struct Info {
        let width: Int
        let height: Int
        /// When it was taken (EXIF), seconds since 1970.
        let taken: Double?
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func info(_ url: URL) -> Info? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return svgSize(url).map { Info(width: $0.width, height: $0.height, taken: nil) }
        }
        var width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        // Orientations 5–8 turn the picture a quarter: width and height swap.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
        return Info(width: width, height: height, taken: taken(properties))
    }

    /// EXIF's DateTimeOriginal with its offset if given, else in this Mac's time zone.
    static func taken(_ properties: [CFString: Any]) -> Double? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let text = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
                ?? exif?[kCGImagePropertyExifDateTimeDigitized] as? String
                ?? tiff?[kCGImagePropertyTIFFDateTime] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let offset = exif?["OffsetTimeOriginal" as CFString] as? String,
           let zone = TimeZone(identifier: "GMT" + offset.replacingOccurrences(of: ":", with: "")) {
            formatter.timeZone = zone
        }
        return formatter.date(from: text)?.timeIntervalSince1970
    }

    /// The picture, decoded straight to at most `maxPixels` on its long side (a 48-megapixel photo is never decoded
    /// whole), turned upright.
    static func image(_ url: URL, maxPixels: Int) throws -> CGImage {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
        }
        if let image = svgImage(url, maxPixels: maxPixels) { return image }
        throw Failure(description: "can't open this picture")
    }

    /// SVG isn't ImageIO's: AppKit reads it. Its own size (its width and height, else its viewBox's, else its
    /// drawing's bounds), as a picture's pixels: what decides it's too small to read, the same on every Mac. A file
    /// can declare any size ("1e20" crashed turning it into an Int, review 11-02): each side is kept to 1 …
    /// `svgLargest`.
    static func svgSize(_ url: URL) -> (width: Int, height: Int)? {
        guard url.pathExtension.lowercased() == "svg", let picture = NSImage(contentsOf: url) else { return nil }
        let size = picture.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let side = { (length: CGFloat) in Int(min(max(length, 1), svgLargest).rounded()) }
        return (side(size.width), side(size.height))
    }

    /// The longest side an SVG's size is taken as: no picture anyone makes is longer.
    static let svgLargest: CGFloat = 100_000

    /// An SVG drawn at twice its own size (it's drawn, so its text comes out finer), at most `maxPixels` on its long
    /// side, into a bitmap of exactly that size: `NSImage.cgImage(forProposedRect:)` also multiplied by the screen's
    /// scale, 4× its size on a Retina Mac and past `maxPixels` (found 10-22, the coverage tests).
    static func svgImage(_ url: URL, maxPixels: Int = 1024) -> CGImage? {
        guard url.pathExtension.lowercased() == "svg", let picture = NSImage(contentsOf: url) else { return nil }
        let size = picture.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let scale = min(2, CGFloat(maxPixels) / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        picture.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func encode(_ image: CGImage, as type: UTType, quality: Double = 0.85) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw Failure(description: "can't encode")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure(description: "can't encode") }
        return data as Data
    }
}

/// Text in pictures, with the system's Vision. Languages are named, not detected: automatic detection made each
/// screenshot take about 16 s instead of 0.13 s (M3 Pro test machine, 2026-10-20), for the same text.
enum OCR {
    /// Chinese first: Vision's Chinese reading also reads English, but with English first a Chinese receipt came out
    /// as "#### (A) x1 ·32.00" instead of "燕麦拿铁（大）x1 ¥32.00" (same test, same picture). Then Japanese and
    /// Korean (no slower), then whatever else the Mac's preferred languages are, if Vision reads them.
    static let languages: [String] = {
        let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
        var out = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"].filter(supported.contains)
        for preferred in Locale.preferredLanguages {
            let match = supported.first { $0 == preferred } ?? supported.first { preferred.hasPrefix($0) }
                ?? supported.first { $0.hasPrefix(preferred.prefix(2) + "-") }
            if let match, !out.contains(match), !match.hasPrefix("zh") { out.append(match) }
        }
        return out
    }()

    /// One recognition at a time in this process. Call it (and `Reader.read`) from a thread of your own, never from
    /// Swift concurrency's pool: the recognizer waits for work of its own that needs a free pool thread, and with
    /// every pool thread blocked in a read it never finished (seen with twenty tests reading in parallel).
    private static let lock = NSLock()

    static func text(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        try lock.withLock { try VNImageRequestHandler(cgImage: image).perform([request]) }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
