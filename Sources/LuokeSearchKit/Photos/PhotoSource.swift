@preconcurrency import AVFoundation
import AppKit
import Foundation
import Photos

/// One photo or video in the Photos library, as indexing needs it.
public struct PhotoAsset: Sendable, Equatable {
    /// PhotoKit's local identifier (stable on this Mac).
    public let id: String
    public let isVideo: Bool
    /// When it was taken; when it was last changed (edits, favourites).
    public let created: Double?
    public let modified: Double
    public let width: Int
    public let height: Int
    /// The name it was imported under ("IMG_1001.HEIC"), if Photos knows it.
    public let filename: String?

    public init(id: String, isVideo: Bool, created: Double?, modified: Double, width: Int, height: Int,
                filename: String?) {
        self.id = id
        self.isVideo = isVideo
        self.created = created
        self.modified = modified
        self.width = width
        self.height = height
        self.filename = filename
    }
}

/// What changed in the Photos library, as PhotoKit tells it (`PHChange.changeDetails`): enough to follow the library
/// without listing all of it again (review A-20). New assets come with their original name; changed ones don't need it.
public struct PhotoChanges: Sendable, Equatable {
    public var inserted: [PhotoAsset] = []
    public var changed: [PhotoAsset] = []
    public var removed: [String] = []

    public init(inserted: [PhotoAsset] = [], changed: [PhotoAsset] = [], removed: [String] = []) {
        self.inserted = inserted
        self.changed = changed
        self.removed = removed
    }

    public var isEmpty: Bool { inserted.isEmpty && changed.isEmpty && removed.isEmpty }
}

public enum PhotoAccess: String, Sendable {
    case allowed, notAsked, denied
}

/// Where photos come from: the system's Photos library (`SystemPhotos`), or a fake one in tests. Nothing here
/// changes the library: it's only read.
public protocol PhotoSource: Sendable {
    var access: PhotoAccess { get }
    /// Every photo and video; `shouldStop` is asked as it goes (a large library takes a while), and stopping throws
    /// `CancellationError`: a partial list is never taken for the library. The original name is looked up only for
    /// assets not in `named` (the index has theirs already; looking it up is most of a listing's time).
    func assets(shouldStop: () -> Bool, named: Set<String>) throws -> [PhotoAsset]
    /// One asset, if it's still in the library.
    func asset(_ id: String) -> PhotoAsset?
    /// The picture, at most `maxPixels` on its long side. Only what's on this Mac: an iCloud-only original isn't
    /// downloaded (as iCloud placeholder files aren't read).
    func image(_ id: String, maxPixels: Int) throws -> CGImage
    func video(_ id: String) throws -> AVAsset
    /// Opens Photos (the agent's `search_open` for a photo; Photos can't be opened at one picture from outside).
    func open(_ id: String)
    /// Calls `changed` (on any thread) with what changed whenever the library does, from now on; with nil when
    /// PhotoKit can't say (the library must be listed again).
    func watch(_ changed: @escaping @Sendable (PhotoChanges?) -> Void)
}

extension PhotoSource {
    public func assets() throws -> [PhotoAsset] { try assets(shouldStop: { false }, named: []) }
    public func assets(shouldStop: () -> Bool) throws -> [PhotoAsset] { try assets(shouldStop: shouldStop, named: []) }
}

/// Every item from the Photos library has a path like `photos:<local identifier>` in the index.
public enum PhotoPath {
    public static func of(_ id: String) -> String { "photos:" + id }

    public static func id(_ path: String) -> String? {
        path.hasPrefix("photos:") ? String(path.dropFirst("photos:".count)) : nil
    }
}

/// The Photos library, through PhotoKit. Used only by the app itself (`Contents/Info.plist` explains why it asks)
/// or when `LUOKE_SEARCH_PHOTOS=system` says so: a command run from a terminal never reads the library of whoever
/// runs it by accident (`current`).
public struct SystemPhotos: PhotoSource {
    /// The asset isn't in the library any more.
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// It's in the library, but its picture or video is only in iCloud: it isn't downloaded, so it waits.
    public struct NotOnThisMac: Error, CustomStringConvertible {
        public init() {}
        public var description: String { "only in iCloud" }
    }

    /// The Photos library, if this process may use it; nil otherwise (photos are then simply not searched).
    public static var current: SystemPhotos? {
        let environment = ProcessInfo.processInfo.environment["LUOKE_SEARCH_PHOTOS"]
        if environment == "off" { return nil }
        guard LuokeSearch.isApp || environment == "system" else { return nil }
        return SystemPhotos()
    }

    /// Whether the user has yet to let this app use photos (`LUOKE_PERMISSIONS_OFF`, from luoke): macOS grants luoke,
    /// the user grants this app, and neither stands in for the other.
    public static func notAllowed(_ value: String?) -> Bool {
        (value ?? "").split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "photos" }
    }

    public var access: PhotoAccess {
        // Not read, whatever macOS says, and said the way "not asked yet" is said: the way to allow it is the same.
        if Self.notAllowed(ProcessInfo.processInfo.environment["LUOKE_PERMISSIONS_OFF"]) { return .notAsked }
        return switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    public func assets(shouldStop: () -> Bool, named: Set<String>) throws -> [PhotoAsset] {
        var out: [PhotoAsset] = []
        var stopped = false
        let result = Self.fetchAll()
        // PhotoKit calls the block before it returns: the check doesn't really escape.
        withoutActuallyEscaping(shouldStop) { shouldStop in
            result.enumerateObjects { asset, index, stop in
                if index % 200 == 0, shouldStop() {
                    stopped = true
                    stop.pointee = true
                    return
                }
                guard Self.wanted(asset) else { return }
                out.append(Self.photoAsset(asset, name: !named.contains(asset.localIdentifier)))
            }
        }
        if stopped { throw CancellationError() }
        return out
    }

    /// Every asset, as the index follows them (hidden ones left out).
    static func fetchAll() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        return PHAsset.fetchAssets(with: options)
    }

    static func wanted(_ asset: PHAsset) -> Bool { asset.mediaType == .image || asset.mediaType == .video }

    /// `name`: look up the original file name too (a request per asset).
    static func photoAsset(_ asset: PHAsset, name: Bool) -> PhotoAsset {
        PhotoAsset(id: asset.localIdentifier, isVideo: asset.mediaType == .video,
                   created: asset.creationDate?.timeIntervalSince1970,
                   modified: (asset.modificationDate ?? asset.creationDate ?? .distantPast).timeIntervalSince1970,
                   width: asset.pixelWidth, height: asset.pixelHeight,
                   filename: name ? PHAssetResource.assetResources(for: asset).first?.originalFilename : nil)
    }

    public func asset(_ id: String) -> PhotoAsset? {
        guard let asset = try? phAsset(id) else { return nil }
        return Self.photoAsset(asset, name: true)
    }

    func phAsset(_ id: String) throws -> PHAsset {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw Failure(description: "not in the Photos library any more")
        }
        return asset
    }

    public func image(_ id: String, maxPixels: Int) throws -> CGImage {
        let asset = try phAsset(id)
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        let scale = min(1, Double(maxPixels) / Double(max(asset.pixelWidth, asset.pixelHeight, 1)))
        let size = CGSize(width: Double(asset.pixelWidth) * scale, height: Double(asset.pixelHeight) * scale)
        var image: NSImage?
        PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) {
            result, _ in image = result
        }
        var rect = CGRect(origin: .zero, size: image?.size ?? .zero)
        guard let picture = image?.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw NotOnThisMac() }
        return picture
    }

    public func video(_ id: String) throws -> AVAsset {
        let asset = try phAsset(id)
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        final class Box: @unchecked Sendable { var video: AVAsset? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { video, _, _ in
            box.video = video
            done.signal()
        }
        done.wait()
        guard let video = box.video else { throw NotOnThisMac() }
        return video
    }

    public func open(_ id: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Photos.app"))
    }
}

extension SystemPhotos {
    public func watch(_ changed: @escaping @Sendable (PhotoChanges?) -> Void) {
        PHPhotoLibrary.shared().register(LibraryObserver.keep(changed))
    }

    /// PhotoKit's change observer; kept alive for as long as the process runs (one per `watch`). It keeps the fetch
    /// of every asset that PhotoKit compares each change with, and hands on what changed in it (review A-20).
    final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
        nonisolated(unsafe) static var kept: [LibraryObserver] = []
        let changed: @Sendable (PhotoChanges?) -> Void
        private let lock = NSLock()
        private var fetched: PHFetchResult<PHAsset>

        init(_ changed: @escaping @Sendable (PhotoChanges?) -> Void) {
            self.changed = changed
            fetched = SystemPhotos.fetchAll()
        }

        static func keep(_ changed: @escaping @Sendable (PhotoChanges?) -> Void) -> LibraryObserver {
            let observer = LibraryObserver(changed)
            kept.append(observer)
            return observer
        }

        func photoLibraryDidChange(_ change: PHChange) {
            let details = lock.withLock { () -> PHFetchResultChangeDetails<PHAsset>? in
                guard let details = change.changeDetails(for: fetched) else { return nil }
                fetched = details.fetchResultAfterChanges
                return details
            }
            guard let details else { return }   // nothing the index follows changed (an album, a person)
            // Too much changed to say what (PhotoKit's own judgement): the library is listed again.
            guard details.hasIncrementalChanges else { return changed(nil) }
            let changes = PhotoChanges(
                inserted: details.insertedObjects.filter(SystemPhotos.wanted).map { SystemPhotos.photoAsset($0, name: true) },
                changed: details.changedObjects.filter(SystemPhotos.wanted).map { SystemPhotos.photoAsset($0, name: false) },
                removed: details.removedObjects.map(\.localIdentifier))
            if !changes.isEmpty { changed(changes) }
        }
    }
}
