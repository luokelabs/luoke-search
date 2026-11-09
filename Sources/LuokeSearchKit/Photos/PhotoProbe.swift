@preconcurrency import AVFoundation
import Foundation
import Photos

/// What this Mac's Photos library gives luoke-search, for a test on a real library (`luoke-search photos-probe`).
/// Numbers only: never an identifier, a name, a date, a place or anything in a picture, not even in an error. Never
/// asks for access (the caller checks it's allowed) and never downloads from iCloud.
public enum PhotoProbe {
    public struct Report: Encodable {
        public var photos = 0
        public var videos = 0
        public var withoutName = 0
        public var smallerThan256 = 0
        /// Listing the library as a sync does (every asset and its original name).
        public var listSeconds = 0.0
        public var pictures = Pictures()
        public var originals = Originals()
        public var videoFiles = Videos()
    }

    /// Photos asked for as luoke-core is sent them (≤ 1024 px, nothing from iCloud): how many came, how big.
    public struct Pictures: Encodable {
        public var asked = 0
        public var got = 0
        public var notOnThisMac = 0
        /// Came at the size asked for (1024 px on the long side, or the photo's own size if smaller).
        public var fullSize = 0
        public var longSide = Spread()
        public var milliseconds = Spread()
        /// How many came with a long side of 1024, 512–1023, 256–511, under 256.
        public var sizes: [String: Int] = [:]
    }

    /// Whether a photo's original file is on this Mac (with "Optimize Mac Storage", most are only in iCloud).
    public struct Originals: Encodable {
        public var asked = 0
        public var onThisMac = 0
        public var inICloud = 0
        public var other = 0
    }

    public struct Videos: Encodable {
        public var asked = 0
        public var onThisMac = 0
        public var notOnThisMac = 0
        public var totalHours = 0.0
        public var hoursOnThisMac = 0.0
    }

    public struct Spread: Encodable {
        public var mean = 0.0
        public var p50 = 0.0
        public var p90 = 0.0
        public var max = 0.0

        init() {}

        init(_ values: [Double]) {
            guard !values.isEmpty else { return }
            let sorted = values.sorted()
            mean = (values.reduce(0, +) / Double(values.count) * 10).rounded() / 10
            p50 = sorted[sorted.count / 2]
            p90 = sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
            max = sorted[sorted.count - 1]
        }
    }

    /// `sample`: how many photos (and videos) to fetch, spread evenly over the library; `originals`: how many of
    /// those to check for their original file.
    public static func run(_ library: SystemPhotos, sample: Int, originals: Int) throws -> Report {
        var report = Report()
        let started = Date()
        let assets = try library.assets()
        report.listSeconds = (Date().timeIntervalSince(started) * 10).rounded() / 10
        let photos = assets.filter { !$0.isVideo }, videos = assets.filter(\.isVideo)
        report.photos = photos.count
        report.videos = videos.count
        report.withoutName = assets.filter { $0.filename == nil }.count
        report.smallerThan256 = photos.filter { max($0.width, $0.height) < Reader.smallestPicture }.count

        let picked = spread(photos, sample)
        var sides: [Double] = [], times: [Double] = []
        for asset in picked {
            autoreleasepool {
                report.pictures.asked += 1
                let start = Date()
                guard let image = try? library.image(asset.id, maxPixels: 1024) else {
                    report.pictures.notOnThisMac += 1
                    return
                }
                times.append((Date().timeIntervalSince(start) * 1000).rounded())
                report.pictures.got += 1
                let side = max(image.width, image.height)
                sides.append(Double(side))
                if side >= min(1024, max(asset.width, asset.height)) - 1 { report.pictures.fullSize += 1 }
                let bucket = side >= 1024 ? "1024" : side >= 512 ? "512-1023" : side >= 256 ? "256-511" : "under 256"
                report.pictures.sizes[bucket, default: 0] += 1
            }
        }
        report.pictures.longSide = Spread(sides)
        report.pictures.milliseconds = Spread(times)

        for asset in spread(picked, originals) {
            autoreleasepool {
                report.originals.asked += 1
                switch originalOnThisMac(library, asset.id) {
                case true?: report.originals.onThisMac += 1
                case false?: report.originals.inICloud += 1
                case nil: report.originals.other += 1
                }
            }
        }

        for asset in spread(videos, sample) {
            autoreleasepool {
                report.videoFiles.asked += 1
                let hours = (try? library.phAsset(asset.id).duration).map { $0 / 3600 } ?? 0
                report.videoFiles.totalHours += hours
                if (try? library.video(asset.id)) != nil {
                    report.videoFiles.onThisMac += 1
                    report.videoFiles.hoursOnThisMac += hours
                } else {
                    report.videoFiles.notOnThisMac += 1
                }
            }
        }
        report.videoFiles.totalHours = (report.videoFiles.totalHours * 10).rounded() / 10
        report.videoFiles.hoursOnThisMac = (report.videoFiles.hoursOnThisMac * 10).rounded() / 10
        return report
    }

    /// At most `count` items, evenly spread (old and new alike).
    static func spread<T>(_ items: [T], _ count: Int) -> [T] {
        guard items.count > count, count > 0 else { return count > 0 ? items : [] }
        return (0..<count).map { items[$0 * items.count / count] }
    }

    /// The unedited original's bytes, from this Mac only: true when there, false when only in iCloud, nil otherwise.
    static func originalOnThisMac(_ library: SystemPhotos, _ id: String) -> Bool? {
        guard let asset = try? library.phAsset(id) else { return nil }
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = false
        options.version = .original
        options.deliveryMode = .highQualityFormat
        var answer: Bool?
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
            if data != nil {
                answer = true
            } else if (info?[PHImageResultIsInCloudKey] as? Bool) == true {
                answer = false
            }
        }
        return answer
    }
}
