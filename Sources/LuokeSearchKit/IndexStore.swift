import Foundation

/// An item as the index knows it.
public struct ItemRecord: Sendable, Equatable {
    public let id: Int64
    public let path: String
    public let kind: ItemKind
    public let size: Int64
    public let mtime: Double
    public let inode: UInt64
    public let device: UInt64
    public let state: String
    public let reader: Int
    /// Reads begun and not finished: the process ended while reading it (it crashed, or was killed).
    public var attempts = 0
}

/// What a walk found on disk for one file.
public struct FoundFile: Sendable, Equatable {
    public let path: String
    public let kind: ItemKind
    public let size: Int64
    public let mtime: Double
    public let inode: UInt64
    public let device: UInt64
}

/// The index: one SQLite file holding items (files, later photos), their segments with fp16 vectors, and two FTS5
/// tables for keyword search. Everything in one database, so a crash can't leave vectors out of step with the rows
/// they belong to.
///
/// - `fts`: words, `unicode61` (marks count as letters, so Bengali vowel signs stay in their words) with Porter
///   stemming for English, of the text as `Script.normalized` keeps it.
/// - `fts_tri`: the same rows when they hold scripts written without spaces (Chinese, Japanese, Thai…), matched three
///   characters at a time; two-character words are found with LIKE on it.
/// Both use the segment's id as rowid.
public final class IndexStore {
    public static let schemaVersion: Int64 = 8
    /// Characters of a PDF page that go into its vector.
    static let pageInput = 4000
    static let tokenizer = "porter unicode61 remove_diacritics 2 categories 'L* N* Co M*'"

    public let db: Database
    public let file: URL
    /// The user's home, to describe an item's folders relative to it.
    let home: String

    public init(directory: DataDirectory, home: String = NSHomeDirectory()) throws {
        try directory.prepare()
        file = directory.indexFile
        self.home = home
        db = try Database(path: file.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try migrate()
    }

    private func migrate() throws {
        let version = try db.scalarInt("PRAGMA user_version")
        guard version <= Self.schemaVersion else {
            throw Database.Failure(message: "this index was made by a newer luoke-search (schema \(version))")
        }
        guard version < Self.schemaVersion else { return }
        let normalize = try db.transaction { () -> Bool in
            // Read again inside the write lock: another process may have migrated it while this one waited.
            var version = try db.scalarInt("PRAGMA user_version")
            guard version < Self.schemaVersion else { return false }
            // Schema 1 only ever existed in development builds (before keyword rows kept the original text): start over.
            if version == 1 {
                try db.execute("""
                    DROP TABLE IF EXISTS fts; DROP TABLE IF EXISTS fts_tri; DROP TABLE IF EXISTS segments;
                    DROP TABLE IF EXISTS items; DROP TABLE IF EXISTS meta;
                    """)
                version = 0
            }
            if version == 0 { try db.execute("""
                CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE items(
                    id INTEGER PRIMARY KEY,
                    path TEXT NOT NULL UNIQUE,      -- a file's path; a Photos asset is 'photos:<id>'
                    source TEXT NOT NULL DEFAULT 'file',
                    kind TEXT NOT NULL,             -- ItemKind
                    size INTEGER NOT NULL DEFAULT 0,
                    mtime REAL NOT NULL DEFAULT 0,
                    inode INTEGER NOT NULL DEFAULT 0,
                    device INTEGER NOT NULL DEFAULT 0,
                    taken REAL,                     -- when it was made, if the file says; else mtime is its time
                    title TEXT,
                    state TEXT NOT NULL DEFAULT 'pending',   -- pending | partial | done | failed | skipped
                    detail TEXT,                    -- why it failed or was skipped
                    info TEXT,                      -- JSON: pages, slides, duration, pixels…
                    reader INTEGER NOT NULL DEFAULT -1,      -- Reader.versions[kind] that read it
                    read_at REAL,
                    queued_at REAL,                 -- when it last started waiting: new changes are read first
                    attempts INTEGER NOT NULL DEFAULT 0   -- reads begun and not finished (the process ended)
                );
                CREATE INDEX items_state ON items(state, kind);
                CREATE INDEX items_inode ON items(device, inode);
                CREATE TABLE segments(
                    id INTEGER PRIMARY KEY,
                    item INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,             -- SegmentKind
                    loc REAL,                       -- chunk / slide / sheet / page number, or seconds
                    loc_end REAL,
                    modality TEXT,                  -- the vector's: text | image | audio; NULL: none wanted
                    vec BLOB,                       -- 768 × float16, L2-normalized
                    todo TEXT,                      -- Pending, while waiting for luoke-core
                    tries INTEGER NOT NULL DEFAULT 0,  -- picture or sound inputs that failed for now
                    vec_seq INTEGER                 -- vector_generation when `vec` was stored; NULL: no vector
                );
                CREATE INDEX segments_item ON segments(item);
                CREATE INDEX segments_vec_seq ON segments(vec_seq) WHERE vec_seq IS NOT NULL;
                CREATE INDEX segments_vec_unsequenced ON segments(id) WHERE vec IS NOT NULL AND vec_seq IS NULL;
                CREATE INDEX segments_todo ON segments(todo) WHERE todo IS NOT NULL;
                -- `mediaTodos`' pages start where the last ended, not with all that wait.
                CREATE INDEX segments_todo_item ON segments(todo, item) WHERE todo IS NOT NULL;
                -- `body` is `Script.normalized` (what words are matched in); `original` the text as written when that
                -- changed it (full-width Chinese punctuation, a soft hyphen): snippets and vectors use that.
                CREATE VIRTUAL TABLE fts USING fts5(name, body, original UNINDEXED, tokenize = "\(Self.tokenizer)");
                CREATE VIRTUAL TABLE fts_tri USING fts5(name, body, tokenize = 'trigram');
                """) }
            // Schema 2 → 3: when an item started waiting.
            if version == 2 {
                try db.execute("ALTER TABLE items ADD COLUMN queued_at REAL")
                version = 3
            }
            // 3 → 4: unfinished reads; picture and sound inputs that failed for now.
            if version == 3 {
                try db.execute("""
                    ALTER TABLE items ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE segments ADD COLUMN tries INTEGER NOT NULL DEFAULT 0;
                    """)
                version = 4
            }
            // 4 → 5: when each vector was stored, so a search loads only the vectors new since it last looked
            // (review B-18). Vectors stored before count as stored at 0.
            if version == 4 {
                try db.execute("""
                    ALTER TABLE segments ADD COLUMN vec_seq INTEGER;
                    UPDATE segments SET vec_seq = 0 WHERE vec IS NOT NULL;
                    CREATE INDEX segments_vec_seq ON segments(vec_seq) WHERE vec_seq IS NOT NULL;
                    CREATE INDEX segments_vec_unsequenced ON segments(id) WHERE vec IS NOT NULL AND vec_seq IS NULL;
                    """)
                version = 5
            }
            // 5 → 6: items waiting for pictures and sound a page at a time without going through all that wait for each
            // page. Files that aren't on this Mac wait as long as they're away (MediaInputs.Source): at 2,000 videos
            // unplugged a run of `VectorFiller` took 6 s of CPU, with this 0.05 s.
            if version == 5 {
                try db.execute("CREATE INDEX IF NOT EXISTS segments_todo_item ON segments(todo, item) WHERE todo IS NOT NULL")
                version = 6
            }
            // 6 or 7 → 8 after this, a batch at a time (below).
            try db.execute("PRAGMA user_version = \(version >= 6 ? version : Self.schemaVersion)")
            return version >= 6
        }
        // 6 → 7: keyword rows as `Script.normalized` keeps text now, no longer NFKC alone (11-02). A window of rows at
        // a time, each in a transaction of its own: in an index mostly in Arabic nearly every row changes (a hamza is
        // enough), and one transaction kept other processes out longer than they wait for the lock (40,000 rows:
        // 9 s). A row done isn't changed again, so a process stopped partway, or two at once, carry on from where it
        // is.
        // 7 → 8: Persian's yeh and keheh and the alef maksura as Arabic's yeh and kaf too (11-03). The same pass: in
        // an index normalized as 7 did, only the rows holding one of those three are found.
        if normalize {
            try normalizeWords()
            try db.execute("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    // MARK: Meta

    public func meta(_ key: String) throws -> String? {
        var value: String?
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { value = $0.text(0) }
        return value
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        if let value {
            try db.query("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                         [.text(key), .text(value)])
        } else {
            try db.query("DELETE FROM meta WHERE key = ?", [.text(key)])
        }
    }

    // MARK: Items

    static let itemColumns = "id, path, kind, size, mtime, inode, device, state, reader, attempts"

    static func item(_ row: Row) -> ItemRecord {
        ItemRecord(id: row.int(0), path: row.text(1) ?? "", kind: ItemKind(rawValue: row.text(2) ?? "") ?? .doc,
                   size: row.int(3), mtime: row.double(4), inode: UInt64(bitPattern: row.int(5)),
                   device: UInt64(bitPattern: row.int(6)), state: row.text(7) ?? "pending", reader: Int(row.int(8)),
                   attempts: Int(row.int(9)))
    }

    public func item(id: Int64) throws -> ItemRecord? {
        var found: ItemRecord?
        try db.query("SELECT \(Self.itemColumns) FROM items WHERE id = ?", [.int(id)]) { found = Self.item($0) }
        return found
    }

    public func item(path: String) throws -> ItemRecord? {
        var found: ItemRecord?
        try db.query("SELECT \(Self.itemColumns) FROM items WHERE path = ?", [.text(path)]) { found = Self.item($0) }
        return found
    }

    /// Items whose path is under one of `folders` (file items only).
    public func items(under folders: [String]) throws -> [ItemRecord] {
        var out: [ItemRecord] = []
        for folder in folders {
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            try db.query("SELECT \(Self.itemColumns) FROM items WHERE source = 'file' AND path >= ? AND path < ?",
                         [.text(prefix), .text(prefix + "\u{10FFFF}")]) { out.append(Self.item($0)) }
        }
        return out
    }

    /// A new item, waiting to be read. Its name is searchable right away.
    @discardableResult
    public func add(_ file: FoundFile) throws -> Int64 {
        try db.transaction {
            try db.query("""
                INSERT INTO items(path, kind, size, mtime, inode, device, queued_at) VALUES(?, ?, ?, ?, ?, ?, ?)
                """, [.text(file.path), .text(file.kind.rawValue), .int(file.size), .double(file.mtime),
                      .int(Int64(bitPattern: file.inode)), .int(Int64(bitPattern: file.device)),
                      .double(Date().timeIntervalSince1970)])
            let id = db.lastInsertID
            try writeName(item: id, path: file.path)
            return id
        }
    }

    /// A photo or video from the Photos library, waiting to be read. Its original file name ("IMG_1001.HEIC") is
    /// searchable right away and is what results call it.
    @discardableResult
    public func addPhoto(_ asset: PhotoAsset) throws -> Int64 {
        try db.transaction {
            try db.query("""
                INSERT INTO items(path, source, kind, mtime, taken, title, queued_at) VALUES(?, 'photos', ?, ?, ?, ?, ?)
                """, [.text(PhotoPath.of(asset.id)), .text((asset.isVideo ? ItemKind.video : .photo).rawValue),
                      .double(asset.modified), asset.created.map(SQLValue.double) ?? .null,
                      asset.filename.map(SQLValue.text) ?? .null, .double(Date().timeIntervalSince1970)])
            let id = db.lastInsertID
            try db.query("INSERT INTO segments(item, kind) VALUES(?, 'name')", [.int(id)])
            let name = asset.filename.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent + " "
                + URL(fileURLWithPath: $0).pathExtension } ?? ""
            try writeWords(segment: db.lastInsertID, name: Self.spaced(name), body: asset.isVideo ? "视频" : "照片")
            return id
        }
    }

    /// Items from the Photos library (`photos:` paths).
    /// Whether any item is from the Photos library: by the path's unique index (`photos:<id>`), not a scan.
    public func hasPhotos() throws -> Bool {
        try db.scalarInt("SELECT count(*) FROM (SELECT 1 FROM items WHERE path >= 'photos:' AND path < 'photos;' LIMIT 1)") > 0
    }

    public func photoItems() throws -> [ItemRecord] {
        var out: [ItemRecord] = []
        try db.query("SELECT \(Self.itemColumns) FROM items WHERE source = 'photos'") { out.append(Self.item($0)) }
        return out
    }

    /// The file changed on disk: read it again. Its old segments stay searchable until then.
    public func changed(_ id: Int64, to file: FoundFile) throws {
        try db.query("""
            UPDATE items SET kind = ?, size = ?, mtime = ?, inode = ?, device = ?, state = 'pending', detail = NULL,
                             queued_at = ?, attempts = 0
            WHERE id = ?
            """, [.text(file.kind.rawValue), .int(file.size), .double(file.mtime),
                  .int(Int64(bitPattern: file.inode)), .int(Int64(bitPattern: file.device)),
                  .double(Date().timeIntervalSince1970), .int(id)])
    }

    /// The same file under a new name or in another folder: only the path (and the name segment) change.
    public func moved(_ id: Int64, to path: String) throws {
        try db.transaction {
            try db.query("UPDATE items SET path = ? WHERE id = ?", [.text(path), .int(id)])
            try db.query("DELETE FROM fts WHERE rowid IN (SELECT id FROM segments WHERE item = ? AND kind = 'name')",
                         [.int(id)])
            try db.query("DELETE FROM fts_tri WHERE rowid IN (SELECT id FROM segments WHERE item = ? AND kind = 'name')",
                         [.int(id)])
            try db.query("DELETE FROM segments WHERE item = ? AND kind = 'name'", [.int(id)])
            try writeName(item: id, path: path)
        }
    }

    public func remove(_ id: Int64) throws {
        try db.transaction {
            try deleteSegments(item: id, keepName: false)
            try db.query("DELETE FROM items WHERE id = ?", [.int(id)])
        }
    }

    /// What a waiting item says while its file isn't on this Mac: its contents only in iCloud, its drive unplugged.
    /// Why its pictures and sound wait then too (`MediaInputs.Source`).
    public static let notHere = "not on this Mac"

    /// A waiting item whose file isn't on this Mac now (`Indexer.readPending`): set aside, neither asked for nor
    /// counted as waiting, until a walk finds the file here (`backHere`). What an older reader read stays searchable.
    /// Not if it changed or moved meanwhile (a walk moved it to where it's here).
    public func setAside(_ item: ItemRecord) throws {
        try db.query("""
            UPDATE items SET detail = ?
            WHERE id = ? AND state = 'pending' AND mtime = ? AND size = ? AND path = ?
            """, [.text(Self.notHere), .int(item.id), .double(item.mtime), .int(item.size), .text(item.path)])
    }

    /// A read begun (`startReading`) that finished with nothing stored, its file gone off this Mac meanwhile (a drive
    /// unplugged while it was read): not one that ended the process (`Indexer.maxAttempts`). Not if it changed
    /// meanwhile.
    public func readEnded(_ item: ItemRecord) throws {
        try db.query("UPDATE items SET attempts = 0 WHERE id = ? AND state = ? AND mtime = ? AND size = ?",
                     [.int(item.id), .text(item.state), .double(item.mtime), .int(item.size)])
    }

    /// A read begun (`startReading`) that ended because the process was asked to quit, not because of the file
    /// (`ReadWatchdog.noteAskedToStop`): not counted towards `Indexer.maxAttempts`. Nothing if it was finished
    /// (stored, or its attempts started again) meanwhile.
    public func takeBackAttempt(_ id: Int64) throws {
        try db.query("UPDATE items SET attempts = attempts - 1 WHERE id = ? AND attempts > 0", [.int(id)])
    }

    /// The items set aside (`setAside`).
    public func setAsideItems() throws -> Set<Int64> {
        var out = Set<Int64>()
        try db.query("SELECT id FROM items WHERE state = 'pending' AND detail = ?", [.text(Self.notHere)]) {
            out.insert($0.int(0))
        }
        return out
    }

    /// An item set aside whose file a walk found here: waiting again, as one that just changed.
    public func backHere(_ id: Int64) throws {
        try db.query("UPDATE items SET detail = NULL, queued_at = ? WHERE id = ? AND state = 'pending' AND detail = ?",
                     [.double(Date().timeIntervalSince1970), .int(id), .text(Self.notHere)])
    }

    /// Set once the items read as gone before files away were set aside were queued again.
    static let goneRequeued = "gone_requeued"

    /// Files read as "file is gone" (their drive unplugged while they waited) or as "not the file that was listed"
    /// (unplugged while they were read) before files away were set aside, read again never: queued again, once. So are
    /// long files whose rest was read so (`restFailed`), ended as read: read again from the start. One really gone is
    /// removed by the walk, one put in its place is dealt with as before, one still away is set aside. Returns how
    /// many.
    public func requeueGoneOnce() throws -> Int {
        guard try meta(Self.goneRequeued) == nil else { return 0 }
        try db.query("""
            UPDATE items SET state = 'pending', detail = NULL, attempts = 0, queued_at = ?
            WHERE source = 'file' AND (state = 'failed' AND detail IN (?, ?) OR state = 'done' AND detail IN (?, ?))
            """, [.double(Date().timeIntervalSince1970), .text(Indexer.gone), .text(Indexer.notListed),
                  .text(Self.restFailed(Indexer.gone)), .text(Self.restFailed(Indexer.notListed))])
        let requeued = db.changes
        try setMeta(Self.goneRequeued, "1")
        return requeued
    }

    /// Whether `pending` would list anything, without listing or sorting them (`Resident.paused`, on every status).
    public func hasPending(photos: Bool = true) throws -> Bool {
        try db.scalarInt("SELECT EXISTS(SELECT 1 FROM items WHERE state = 'pending' AND detail IS NOT ?"
                         + (photos ? "" : " AND source = 'file'") + ")", [.text(Self.notHere)]) == 1
    }

    /// Items waiting to be read: the kinds people look for most first (screenshots, pictures, PDFs, documents, then
    /// sound and video), newest first within a kind. `latestFirst`: the ones that started waiting last first (what just
    /// changed, ahead of a first pass's backlog).
    /// `photos`: include items from the Photos library (only when there's a library to read them from).
    /// Those set aside while their files aren't on this Mac (`setAside`) aren't among them.
    public func pending(limit: Int, latestFirst: Bool = false, photos: Bool = true) throws -> [ItemRecord] {
        var out: [ItemRecord] = []
        try db.query("""
            SELECT \(Self.itemColumns) FROM items
            WHERE state = 'pending' AND detail IS NOT ?\(photos ? "" : " AND source = 'file'")
            ORDER BY \(latestFirst ? "coalesce(queued_at, 0) DESC," : "") CASE kind WHEN 'screenshot' THEN 0 WHEN 'image' THEN 1 WHEN 'photo' THEN 1 WHEN 'pdf' THEN 2
                     WHEN 'doc' THEN 3 WHEN 'audio' THEN 4 ELSE 5 END, mtime DESC
            LIMIT ?
            """, [.text(Self.notHere), .int(Int64(limit))]) { out.append(Self.item($0)) }
        return out
    }

    /// Set once the films an older reader failed for having no pictures were queued again.
    static let filmsWithoutPicturesRequeued = "films_without_pictures_requeued"

    /// Queues again the items an older reader read, so a better reader reaches an existing index. Returns how many.
    @discardableResult
    public func requeueOlderReaders(_ versions: [ItemKind: Int] = Reader.versions) throws -> Int {
        var total = 0
        for (kind, version) in versions {
            try db.query("UPDATE items SET state = 'pending', attempts = 0 WHERE kind = ? AND reader < ? AND state != 'pending'",
                         [.text(kind.rawValue), .int(Int64(version))])
            total += db.changes
        }
        // Films with no pictures failed before their sound was read alone (luoke-search#46, defect 5): queued again
        // once, not at every walk by a reader's sentence (review 11-02).
        if try meta(Self.filmsWithoutPicturesRequeued) == nil {
            try db.query("UPDATE items SET state = 'pending', attempts = 0 WHERE state = 'failed' AND detail = ?",
                         [.text(MediaReading.noPicturesBefore)])
            total += db.changes
            try setMeta(Self.filmsWithoutPicturesRequeued, "1")
        }
        return total
    }

    /// Stores what reading an item gave, replacing its old segments (except its name).
    /// A long file read only up to `readTo` is `partial`: searchable for what was read, the rest read later
    /// (`storeMore`).
    public func store(_ reading: Reading, for item: ItemRecord, reader: Int) throws {
        let (state, detail): (String, String?) = switch reading.outcome {
        case .done: (reading.readTo == nil ? "done" : "partial", nil)
        case .failed(let why): ("failed", why)
        case .skipped(let why): ("skipped", why)
        }
        var fields = reading.info
        if let readTo = reading.readTo { fields["read_to"] = String(readTo) }
        let info = fields.isEmpty ? nil
            : String(data: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), encoding: .utf8)
        try db.transaction {
            // Another process (the resident loop, a job) may have changed it meanwhile: gone, read already, or changed
            // again since this read began. Then what was read is dropped and it stays as it is (review A-11).
            guard let now = try self.item(id: item.id), now.state == "pending", now.mtime == item.mtime,
                  now.size == item.size else { return }
            try deleteSegments(item: item.id, keepName: true)
            for piece in reading.pieces {
                try db.query("INSERT INTO segments(item, kind, loc, loc_end, modality, todo) VALUES(?, ?, ?, ?, ?, ?)",
                             [.int(item.id), .text(piece.kind.rawValue), piece.loc.map(SQLValue.double) ?? .null,
                              piece.locEnd.map(SQLValue.double) ?? .null,
                              piece.vector.map { .text($0 == .text ? "text" : Self.mediaModality(piece.kind)) } ?? .null,
                              piece.vector.map { .text($0.rawValue) } ?? .null])
                try writeWords(segment: db.lastInsertID, name: "", body: piece.text)
            }
            try db.query("""
                UPDATE items SET state = ?, detail = ?, info = ?, title = ?, taken = ?, reader = ?, read_at = ?,
                                 attempts = 0
                WHERE id = ?
                """, [.text(state), detail.map(SQLValue.text) ?? .null, info.map(SQLValue.text) ?? .null,
                      reading.title.map(SQLValue.text) ?? .null, reading.taken.map(SQLValue.double) ?? .null,
                      .int(Int64(reader)), .double(Date().timeIntervalSince1970), .int(item.id)])
        }
    }

    /// What a long file whose rest couldn't be read says (`storeMore`).
    static func restFailed(_ why: String) -> String { "the rest couldn't be read: \(why)" }

    /// The next step of a long file (`partial`), read from page or chunk `from`: its segments added to those read
    /// before, and where it's read to now (done when nothing's left). False when it changed or went meanwhile, or the
    /// step isn't the next one any more (another process stored it first: review D-4): nothing stored. `from` nil:
    /// only to end it (a failed reading).
    @discardableResult
    public func storeMore(_ reading: Reading, for item: ItemRecord, from: Int?) throws -> Bool {
        try db.transaction {
            guard let now = try self.item(id: item.id), now.state == "partial", now.mtime == item.mtime,
                  now.size == item.size else { return false }
            var fields = try info(of: item.id)
            if let from, fields["read_to"] != String(from - 1) { return false }
            // This version's pictures and sound were given up on (`giveUpMedia`): this step's don't wait either.
            let mediaGivenUp = fields[Self.mediaGivenUp] == String(item.mtime)
            for piece in reading.pieces {
                let vector = mediaGivenUp && piece.vector != .text ? nil : piece.vector
                try db.query("INSERT INTO segments(item, kind, loc, loc_end, modality, todo) VALUES(?, ?, ?, ?, ?, ?)",
                             [.int(item.id), .text(piece.kind.rawValue), piece.loc.map(SQLValue.double) ?? .null,
                              piece.locEnd.map(SQLValue.double) ?? .null,
                              vector.map { .text($0 == .text ? "text" : Self.mediaModality(piece.kind)) } ?? .null,
                              vector.map { .text($0.rawValue) } ?? .null])
                try writeWords(segment: db.lastInsertID, name: "", body: piece.text)
            }
            // What a step says of the file is the latest; scanned pages, pages too long to draw and the time the steps
            // took add up (review D-11).
            for (key, value) in reading.info where key != "empty" {
                fields[key] = ["scanned_pages", "pages_too_long_to_draw", Indexer.readTime].contains(key)
                    ? String((Int(fields[key] ?? "") ?? 0) + (Int(value) ?? 0)) : value
            }
            fields["read_to"] = reading.readTo.map(String.init)
            // What couldn't be read of the rest is said; what was read before stays, and why its pictures and sound
            // were given up on.
            var detail: String? = if case .failed(let why) = reading.outcome { Self.restFailed(why) } else { nil }
            let failed = detail != nil
            if detail == nil, mediaGivenUp {
                try db.query("SELECT detail FROM items WHERE id = ?", [.int(item.id)]) { detail = $0.text(0) }
            }
            let state = reading.readTo != nil && !failed ? "partial" : "done"
            try db.query("UPDATE items SET state = ?, detail = ?, info = ?, read_at = ?, attempts = 0 WHERE id = ?",
                         [.text(state), detail.map(SQLValue.text) ?? .null,
                          .text(String(data: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                                       encoding: .utf8) ?? "{}"),
                          .double(Date().timeIntervalSince1970), .int(item.id)])
            return true
        }
    }

    /// An item's `info` (pages, chunks, where it's read to…).
    public func info(of id: Int64) throws -> [String: String] {
        var text: String?
        try db.query("SELECT info FROM items WHERE id = ?", [.int(id)]) { text = $0.text(0) }
        guard let data = text?.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
    }

    /// The dataset-like folders the last whole walk passed over (`Rules.datasetKinds`), for `status`.
    public func setDatasetFolders(_ folders: [String: Int]) throws {
        let data = try JSONSerialization.data(withJSONObject: folders, options: [.sortedKeys])
        try setMeta("dataset_folders", String(decoding: data, as: UTF8.self))
    }

    public func datasetFolders() throws -> [String: Int] {
        guard let text = try meta("dataset_folders"), let data = text.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Int]) ?? [:]
    }

    /// Long files read only up to a point, oldest step first.
    public func partialItems(limit: Int) throws -> [ItemRecord] {
        var out: [ItemRecord] = []
        try db.query("SELECT \(Self.itemColumns) FROM items WHERE state = 'partial' ORDER BY read_at LIMIT ?",
                     [.int(Int64(limit))]) { out.append(Self.item($0)) }
        return out
    }

    static func mediaModality(_ kind: SegmentKind) -> String {
        kind == .audio ? "audio" : "image"
    }

    // MARK: Words

    /// The name segment: the file's name in `name`, the folders it's in (below the home folder) in `body`, so
    /// "合同" finds a file in a folder called 合同.
    private func writeName(item: Int64, path: String) throws {
        try db.query("INSERT INTO segments(item, kind) VALUES(?, 'name')", [.int(item)])
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent + " " + url.pathExtension
        try writeWords(segment: db.lastInsertID, name: Self.spaced(name), body: Self.spaced(folderWords(path)))
    }

    func folderWords(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let relative = parent.hasPrefix(home + "/") ? String(parent.dropFirst(home.count + 1))
            : parent.split(separator: "/").dropFirst(2).joined(separator: "/")
        return relative.split(separator: "/").joined(separator: " ")
    }

    /// Names use _ - . as spaces ("Q3_invoice-list" is three words).
    static func spaced(_ text: String) -> String {
        text.replacingOccurrences(of: #"[_\-.]+"#, with: " ", options: .regularExpression)
    }

    /// Text goes in as `Script.normalized` keeps it ("ＰＤＦ" matches "pdf", a word split by a soft hyphen is whole).
    private func writeWords(segment: Int64, name: String, body original: String) throws {
        let name = Script.normalized(name)
        let body = Script.normalized(original)
        let kept: SQLValue = body == original ? .null : .text(original)
        try db.query("INSERT INTO fts(rowid, name, body, original) VALUES(?, ?, ?, ?)",
                     [.int(segment), .text(name), .text(body), kept])
        if Script.hasUnspaced(name) || Script.hasUnspaced(body) {
            try db.query("INSERT INTO fts_tri(rowid, name, body) VALUES(?, ?, ?)",
                         [.int(segment), .text(name), .text(body)])
        }
    }

    /// Keyword rows written as NFKC alone (schema 6 and before) or as schema 7 normalized them (its letters not yet
    /// merged), normalized as `writeWords` writes them now: only the rows holding a character that changes
    /// (`Script.changedByNormalizing`), found by SQLite. Either then that is the same as that on the text as written,
    /// so the old row's words are enough; the text as written and the vectors stay as they are. Returns the rows
    /// changed.
    /// `normalizeWindow` rowids to a transaction, however few of them change: batches of 500 rows that change scanned
    /// all of an index with none in one (150,000 rows of Chinese and English: 20 s), and another process opening it
    /// meanwhile gave up on the lock (review 11-03).
    @discardableResult
    func normalizeWords() throws -> Int {
        let set = Script.changedByNormalizing.map { range -> String in
            let low = String(Character(Unicode.Scalar(range.lowerBound)!)), high = String(Character(Unicode.Scalar(range.upperBound)!))
            return range.lowerBound == range.upperBound ? low : low + "-" + high
        }.joined()
        let pattern = "*[" + set + "]*"
        let last = try db.scalarInt("SELECT coalesce(max(rowid), 0) FROM fts")
        var after: Int64 = 0, changed = 0
        while after < last {
            let upTo = after + Self.normalizeWindow
            try db.transaction {
                var rows: [(id: Int64, name: String, body: String, original: String?)] = []
                try db.query("""
                    SELECT rowid, name, body, original FROM fts
                    WHERE rowid > ? AND rowid <= ? AND (name GLOB ? OR body GLOB ?)
                    """, [.int(after), .int(upTo), .text(pattern), .text(pattern)]) { row in
                    rows.append((row.int(0), row.text(1) ?? "", row.text(2) ?? "", row.text(3)))
                }
                for row in rows {
                    let name = Script.normalized(row.name), body = Script.normalized(row.body)
                    let written = row.original ?? row.body
                    try db.query("UPDATE fts SET name = ?, body = ?, original = ? WHERE rowid = ?",
                                 [.text(name), .text(body), body == written ? .null : .text(written), .int(row.id)])
                    try db.query("UPDATE fts_tri SET name = ?, body = ? WHERE rowid = ?",
                                 [.text(name), .text(body), .int(row.id)])
                }
                changed += rows.count
            }
            after = upTo
        }
        return changed
    }

    static let normalizeWindow: Int64 = 1000

    /// About to read an item: noted (committed) first, so a read that ends the process is known next time.
    public func startReading(_ id: Int64) throws {
        try db.query("UPDATE items SET attempts = attempts + 1 WHERE id = ?", [.int(id)])
    }

    private func deleteSegments(item: Int64, keepName: Bool) throws {
        let which = keepName ? " AND kind != 'name'" : ""
        if try db.scalarInt("SELECT EXISTS(SELECT 1 FROM segments WHERE item = ?\(which) AND vec IS NOT NULL)",
                            [.int(item)]) == 1 {
            try vectorsChanged()
        }
        try db.query("DELETE FROM fts WHERE rowid IN (SELECT id FROM segments WHERE item = ?\(which))", [.int(item)])
        try db.query("DELETE FROM fts_tri WHERE rowid IN (SELECT id FROM segments WHERE item = ?\(which))", [.int(item)])
        try db.query("DELETE FROM segments WHERE item = ?\(which)", [.int(item)])
    }

    /// A segment's text as written (not `Script.normalized`): what snippets quote and vectors are made from.
    public func text(ofSegment id: Int64) throws -> String? {
        var text: String?
        try db.query("SELECT coalesce(original, body) FROM fts WHERE rowid = ?", [.int(id)]) { text = $0.text(0) }
        return text
    }

    // MARK: Vectors

    /// The vector space the stored vectors are in (luoke-core's `vector_space`), nil before the first vector.
    public var vectorSpace: String? {
        get throws { try meta("vector_space") }
    }

    /// A text segment waiting for its vector, with what it's made from.
    public struct TextTodo: Sendable {
        public let segment: Int64
        public let text: String
        /// The title the document prompt carries: a PDF's own title or none; for anything else the last part of its
        /// path without extension (a file's name; for a Photos item, the end of its `photos:` identifier).
        public let title: String?
    }

    public func textTodos(limit: Int) throws -> [TextTodo] {
        var out: [TextTodo] = []
        try db.query("""
            SELECT s.id, coalesce(f.original, f.body), i.path, i.kind, i.title, s.kind FROM segments s
            JOIN items i ON i.id = s.item JOIN fts f ON f.rowid = s.id
            WHERE s.todo = 'text' ORDER BY s.id LIMIT ?
            """, [.int(Int64(limit))]) { row in
            let path = row.text(2) ?? ""
            // A PDF has its own title, or none: with its file's name the 190 gate questions lost 3 (luoke-search#46,
            // defect 1, measured 11-01). The same prompts as digup.
            let title = row.text(3) == ItemKind.pdf.rawValue ? row.text(4)
                : URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            // A PDF page gives its first 4000 characters (digup's cut): enough for what the page is about.
            let text = row.text(1) ?? ""
            out.append(TextTodo(segment: row.int(0), text: row.text(5) == SegmentKind.page.rawValue
                                    ? String(text.prefix(Self.pageInput)) : text, title: title))
        }
        return out
    }

    /// Stores vectors made in `space` (all in one transaction).
    public func setVectors(_ vectors: [(segment: Int64, vector: [Float])], space: String?) throws {
        try db.transaction {
            // Made in another space than the index's now (another process switched): not stored (review A-11).
            if let space, let current = try meta("vector_space"), current != space { return }
            if let space, try meta("vector_space") == nil { try setMeta("vector_space", space) }
            let sequence = try vectorsChanged()
            try db.run("UPDATE segments SET vec = ?, vec_seq = ?, todo = NULL, tries = 0 WHERE id = ?",
                       vectors.map { [.blob(VectorMath.blob($0.vector)), .int(sequence), .int($0.segment)] })
        }
    }

    /// Items with pictures or sound waiting for vectors, `limit` items at a time in item order after `item` (a run
    /// goes through them once: review B-20), with the segments that wait and the kinds of them wanted (`pictures`:
    /// images, scanned pages, frames; `sound`: windows).
    public func mediaTodos(limit: Int, pictures: Bool, sound: Bool, after item: Int64 = 0)
        -> [(id: Int64, path: String, kind: ItemKind, mtime: Double, size: Int64, inode: UInt64, wanted: [MediaInputs.Wanted])] {
        var kinds: [String] = []
        if pictures { kinds += ["'image'", "'page'", "'frame'"] }
        if sound { kinds.append("'audio'") }
        guard !kinds.isEmpty else { return [] }
        let list = kinds.joined(separator: ",")
        var items: [Int64: (id: Int64, path: String, kind: ItemKind, mtime: Double, size: Int64, inode: UInt64,
                            wanted: [MediaInputs.Wanted])] = [:]
        var order: [Int64] = []
        try? db.query(Self.mediaTodosQuery(list), [.int(item), .int(Int64(limit))]) { row in
            let id = row.int(4)
            if items[id] == nil {
                items[id] = (id, row.text(5) ?? "", ItemKind(rawValue: row.text(6) ?? "") ?? .image, row.double(7),
                             row.int(8), UInt64(bitPattern: row.int(9)), [])
                order.append(id)
            }
            items[id]?.wanted.append(MediaInputs.Wanted(segment: row.int(0),
                                                        kind: SegmentKind(rawValue: row.text(1) ?? "") ?? .image,
                                                        loc: row.isNull(2) ? nil : row.double(2),
                                                        locEnd: row.isNull(3) ? nil : row.double(3)))
        }
        return order.compactMap { items[$0] }
    }

    /// The page after `?` of `?` items whose segments of `kinds` (SQL strings, comma-separated) wait.
    static func mediaTodosQuery(_ kinds: String) -> String {
        """
        SELECT s.id, s.kind, s.loc, s.loc_end, i.id, i.path, i.kind, i.mtime, i.size, i.inode FROM segments s
        JOIN items i ON i.id = s.item
        WHERE s.todo = 'media' AND s.kind IN (\(kinds))
          AND i.id IN (SELECT DISTINCT s2.item FROM segments s2 WHERE s2.todo = 'media' AND s2.kind IN (\(kinds))
                       AND s2.item > ? ORDER BY s2.item LIMIT ?)
        ORDER BY i.id, s.id
        """
    }

    /// A picture or sound input that couldn't be made or embedded this time (review B-08): counted; after `maxTries`
    /// it's given up. Returns whether it was.
    @discardableResult
    public func failedForNow(segment: Int64) throws -> Bool {
        try db.query("UPDATE segments SET tries = tries + 1 WHERE id = ?", [.int(segment)])
        guard try db.scalarInt("SELECT tries FROM segments WHERE id = ?", [.int(segment)]) >= Self.maxTries else {
            return false
        }
        try giveUpVector(segment: segment)
        return true
    }

    static let maxTries: Int64 = 3

    /// A segment that can't get a vector (luoke-core refuses its text however it's cut): keyword search only.
    public func giveUpVector(segment: Int64) throws {
        try db.query("UPDATE segments SET todo = NULL, modality = NULL WHERE id = ?", [.int(segment)])
    }

    /// An item whose pictures and sound can't be made again (making them ran away, `ReadWatchdog`): those still
    /// waiting get no vector, nor those of later steps of a long file (`storeMore`); what was read stays searchable.
    /// Why goes in its detail unless it has one. Until the file changes: read again, it starts afresh.
    /// False when there's nothing to give up on: an item that waits to be read again starts afresh anyway.
    @discardableResult
    public func giveUpMedia(item: Int64, why: String) throws -> Bool {
        try db.transaction {
            guard let record = try self.item(id: item), ["done", "partial"].contains(record.state) else { return false }
            try db.query("UPDATE segments SET todo = NULL, modality = NULL WHERE item = ? AND todo = 'media'", [.int(item)])
            var fields = try info(of: item)
            fields[Self.mediaGivenUp] = String(record.mtime)
            fields[Self.mediaTries] = nil   // given up on: nothing left to count
            try db.query("UPDATE items SET detail = coalesce(detail, ?), info = ? WHERE id = ?",
                         [.text("its pictures and sound get no vectors: \(why)"), .text(Self.json(fields)), .int(item)])
            return true
        }
    }

    /// In an item's info: the version (mtime) whose pictures and sound were given up on.
    static let mediaGivenUp = "media_given_up"
    /// In an item's info: how many times making its pictures and sound began and didn't end (`startMedia`).
    static let mediaTries = "media_tries"

    /// Making an item's pictures and sound again begins (`VectorFiller`): counted first, and cleared once that's
    /// over (`finishedMedia`), however it ended short of the process ending. A process that ends meanwhile (a crash,
    /// the system taking its memory: no watchdog note) leaves the count, as a read does (`startReading`). Returns how
    /// many times before it began and didn't end.
    @discardableResult
    public func startMedia(_ item: Int64) throws -> Int {
        try db.transaction {
            var fields = try info(of: item)
            let before = Int(fields[Self.mediaTries] ?? "") ?? 0
            fields[Self.mediaTries] = String(before + 1)
            try db.query("UPDATE items SET info = ? WHERE id = ?", [.text(Self.json(fields)), .int(item)])
            return before
        }
    }

    public func finishedMedia(_ item: Int64) throws {
        try db.transaction {
            var fields = try info(of: item)
            guard fields.removeValue(forKey: Self.mediaTries) != nil else { return }
            try db.query("UPDATE items SET info = ? WHERE id = ?", [.text(Self.json(fields)), .int(item)])
        }
    }

    static func json(_ fields: [String: String]) -> String {
        (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
            ?? "{}"
    }

    /// luoke-core's vectors are in another space now: every vector is made again, and nothing is read again for text
    /// (it's kept). Returns how many text segments wait again.
    @discardableResult
    public func adoptVectorSpace(_ space: String?) throws -> Int {
        try db.transaction {
            let current = try meta("vector_space")
            guard current != space else { return 0 }
            try db.query("UPDATE segments SET vec = NULL, vec_seq = NULL, todo = 'text' WHERE modality = 'text'")
            let count = db.changes
            try db.query("""
                UPDATE segments SET vec = NULL, vec_seq = NULL, todo = 'media', tries = 0 WHERE modality IN ('image', 'audio')
                """)
            try setMeta("vector_space", space)
            try vectorsChanged()
            return count
        }
    }

    /// The stored vectors, for search. `generation` changes whenever they do (to know when to load them again).
    func loadVectors() throws -> VectorMatrix {
        let matrix = VectorMatrix()
        try db.query("SELECT id, item, modality, vec FROM segments WHERE vec IS NOT NULL ORDER BY id") { row in
            if let blob = row.blob(3) {
                matrix.append(segment: row.int(0), item: row.int(1), modality: row.text(2) ?? "text", blob: blob)
            }
        }
        return matrix
    }

    /// What changed in the stored vectors since a load at generation `since` (`vectorGeneration`): `matrix` gets
    /// the rows stored after it (new segments, or a reused segment id's new vector) and loses those whose segment has
    /// no vector any more. Reads only those rows and the ids of all (review B-18).
    func updateVectors(_ matrix: VectorMatrix, since: Int64) throws {
        var present = Set<Int64>()
        try db.query("SELECT id FROM segments WHERE vec_seq IS NOT NULL") { present.insert($0.int(0)) }
        matrix.remove { !present.contains($0) }
        try db.query("SELECT id, item, modality, vec FROM segments WHERE vec_seq > ? AND vec IS NOT NULL",
                     [.int(since)]) { row in
            if let blob = row.blob(3) {
                matrix.upsert(segment: row.int(0), item: row.int(1), modality: row.text(2) ?? "text", blob: blob)
            }
        }
    }

    /// Vectors stored without when (by a luoke-search from before schema 5 still running while a newer one migrated
    /// the index): the rows that changed can't be told, so the next load is a full one (review of PR #20).
    func hasUnsequencedVectors() throws -> Bool {
        try db.scalarInt("SELECT EXISTS(SELECT 1 FROM segments WHERE vec IS NOT NULL AND vec_seq IS NULL)") == 1
    }

    /// Counts every change to the stored vectors (any process's): segment ids are reused, so the rows themselves
    /// can't tell an old vector from a new one in its place (review A-03). "<count>:<vector space>".
    var vectorGeneration: String {
        get throws {
            ((try meta("vector_generation")) ?? "0") + ":" + ((try? meta("vector_space")) ?? "")
        }
    }

    /// Adds one to the count and returns it (inside the caller's transaction, if any).
    @discardableResult
    private func vectorsChanged() throws -> Int64 {
        try db.query("""
            INSERT INTO meta(key, value) VALUES('vector_generation', '1')
            ON CONFLICT(key) DO UPDATE SET value = CAST(value AS INTEGER) + 1
            """)
        return Int64(try meta("vector_generation") ?? "") ?? 0
    }

    // MARK: Status

    public struct Counts: Sendable, Codable, Equatable {
        /// Items read (done, or partial: the start of a long file), by kind.
        public var items: [String: Int] = [:]
        public var waitingToRead = 0
        /// Waiting, set aside while their files aren't on this Mac (`setAside`): not in `waitingToRead`.
        public var notOnThisMac = 0
        /// Long files read only up to a point, the rest still to come.
        public var waitingForRest = 0
        public var failed = 0
        public var skipped = 0
        /// Segments waiting for a text vector, and items waiting for picture or sound vectors.
        public var waitingForVectors = 0
        public var waitingForMedia = 0
        public var vectors = 0
    }

    /// When something was last read (the app's page, `SearchService.overview`): a time, never which file. Nil before
    /// anything was.
    public func lastRead() throws -> Double? {
        var last: Double?
        try db.query("SELECT MAX(read_at) FROM items WHERE state IN ('done', 'partial')", []) { row in
            last = row.isNull(0) ? nil : row.double(0)
        }
        return last
    }

    public func counts() throws -> Counts {
        var counts = Counts()
        try db.query("SELECT kind, state, COUNT(*), SUM(detail IS ?) FROM items GROUP BY kind, state",
                     [.text(Self.notHere)]) { row in
            let n = Int(row.int(2))
            switch row.text(1) {
            case "done": counts.items[row.text(0) ?? "", default: 0] += n
            case "partial":
                counts.items[row.text(0) ?? "", default: 0] += n
                counts.waitingForRest += n
            case "pending":
                let aside = Int(row.int(3))
                counts.waitingToRead += n - aside
                counts.notOnThisMac += aside
            case "failed": counts.failed += n
            case "skipped": counts.skipped += n
            default: break
            }
        }
        counts.waitingForVectors = Int(try db.scalarInt("SELECT COUNT(*) FROM segments WHERE todo = 'text'"))
        counts.waitingForMedia = Int(try db.scalarInt(
            "SELECT COUNT(DISTINCT item) FROM segments WHERE todo = 'media'"))
        counts.vectors = Int(try db.scalarInt("SELECT COUNT(*) FROM segments WHERE vec IS NOT NULL"))
        return counts
    }

    /// Bytes on disk: the database and its write-ahead log.
    public var size: Int64 {
        [file.path, file.path + "-wal"].reduce(0) { total, path in
            total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
        }
    }
}
