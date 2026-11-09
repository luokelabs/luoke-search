import Foundation

/// The Photos library in the index: items with `photos:` paths, kind `photo` (or `video` for a video), kept in step
/// with the library and read like picture and video files — except nothing is read from a file, and photos aren't
/// read with OCR (as picture files aren't).
public enum PhotoIndexing {
    /// Brings the index's Photos items in line with the library: new ones wait to be read, changed ones (edited,
    /// modification date moved) are read again, deleted ones go.
    public static func sync(_ source: PhotoSource, store: IndexStore, shouldStop: () -> Bool = { false })
        throws -> Indexer.SyncReport {
        var report = Indexer.SyncReport()
        try retryOnlyInICloud(store)
        // Read by an older reader: queued again here too, for a library searched with no folder (review 11-02).
        report.requeued = try store.requeueOlderReaders()
        let known = Dictionary(try store.photoItems().map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        for asset in try source.assets(shouldStop: shouldStop, named: Set(known.keys.compactMap(PhotoPath.id))) {
            let path = PhotoPath.of(asset.id)
            seen.insert(path)
            if let item = known[path] {
                if abs(item.mtime - asset.modified) > 0.001 {
                    try store.changed(item.id, to: FoundFile(path: path, kind: item.kind, size: 0, mtime: asset.modified,
                                                             inode: 0, device: 0))
                    report.changed += 1
                } else {
                    report.unchanged += 1
                }
            } else {
                try store.addPhoto(asset)
                report.added += 1
            }
        }
        for (path, item) in known where !seen.contains(path) {
            try store.remove(item.id)
            report.removed += 1
        }
        return report
    }

    /// What PhotoKit said changed, without listing the library (review A-20): new assets wait to be read, changed
    /// ones whose modification date moved are read again, removed ones go. An asset this index doesn't have yet is
    /// added whichever way it came (its name looked up if PhotoKit didn't give it).
    public static func apply(_ changes: PhotoChanges, source: PhotoSource, store: IndexStore) throws -> Indexer.SyncReport {
        var report = Indexer.SyncReport()
        try retryOnlyInICloud(store)
        for asset in changes.inserted + changes.changed {
            if let item = try store.item(path: PhotoPath.of(asset.id)) {
                if abs(item.mtime - asset.modified) > 0.001 {
                    try store.changed(item.id, to: FoundFile(path: item.path, kind: item.kind, size: 0, mtime: asset.modified,
                                                             inode: 0, device: 0))
                    report.changed += 1
                } else {
                    report.unchanged += 1
                }
            } else {
                try store.addPhoto(asset.filename == nil ? source.asset(asset.id) ?? asset : asset)
                report.added += 1
            }
        }
        for id in changes.removed {
            guard let item = try store.item(path: PhotoPath.of(id)) else { continue }
            try store.remove(item.id)
            report.removed += 1
        }
        return report
    }

    /// Videos only in iCloud when last tried may be on this Mac now (watched in Photos): tried again, at most every
    /// few hours (review A-10), whichever way the library is followed.
    static func retryOnlyInICloud(_ store: IndexStore) throws {
        try store.db.query("""
            UPDATE items SET state = 'pending', queued_at = ? WHERE source = 'photos' AND state = 'skipped'
            AND detail = ? AND coalesce(read_at, 0) < ?
            """, [.double(Date().timeIntervalSince1970), .text(onlyInICloud),
                  .double(Date().timeIntervalSince1970 - retryICloud)])
    }

    /// What a video only in iCloud is marked with (skipped, not failed: it's tried again).
    static let onlyInICloud = "only in iCloud"
    static let retryICloud: TimeInterval = 6 * 3600

    /// The user turned photos off: every Photos item leaves the index.
    @discardableResult
    public static func removeAll(store: IndexStore) throws -> Int {
        let items = try store.photoItems()
        for item in items { try store.remove(item.id) }
        return items.count
    }

    /// A photo: when it was taken and its look (a vector, once luoke-core takes pictures). A video: its frames and
    /// its sound, as a video file's.
    public static func read(_ item: ItemRecord, source: PhotoSource) -> Reading {
        guard let id = PhotoPath.id(item.path), let asset = source.asset(id) else {
            return Reading(outcome: .failed("not in the Photos library any more"))
        }
        var reading = Reading()
        reading.taken = asset.created
        reading.title = asset.filename
        reading.info["width"] = String(asset.width)
        reading.info["height"] = String(asset.height)
        if !asset.isVideo {
            if max(asset.width, asset.height) < Reader.smallestPicture {
                reading.outcome = .skipped("small image")
                return reading
            }
            reading.pieces = [Piece(kind: .image, text: "", vector: .media)]
            return reading
        }
        do {
            // Read as a film's in a folder is, by the same reader (review 11-02); the library's own size and date
            // stay.
            let film = MediaReading.video(try source.video(id))
            reading.outcome = film.outcome
            reading.pieces = film.pieces
            reading.info.merge(film.info) { library, _ in library }
        } catch is SystemPhotos.NotOnThisMac {
            reading.outcome = .skipped(onlyInICloud)
        } catch {
            reading.outcome = .failed(Reader.describe(error))
        }
        return reading
    }
}
