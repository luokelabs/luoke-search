import Foundation

/// Keeps the index in step with the folders: `sync` compares a walk with what's indexed (new, changed, moved, gone),
/// `readPending` reads what's waiting. Reading never needs luoke-core; vectors are added afterwards (a later block).
public final class Indexer {
    public struct SyncReport: Sendable, Codable, Equatable {
        public var added = 0
        public var changed = 0
        public var moved = 0
        public var removed = 0
        public var unchanged = 0
        public var requeued = 0
        public var skipped: [String: Int] = [:]
        public var unreachable: [String] = []
        /// Folders whose media were passed over as a dataset's, with how many files (a whole walk only).
        public var datasets: [String: Int] = [:]
    }

    public let store: IndexStore
    public var crawler: Crawler
    /// Reads of one item that may end the process before it's given up on.
    static let maxAttempts = 2
    /// The Photos library, when photos are searched and this process may read them; nil leaves Photos items waiting.
    public var photos: PhotoSource?
    /// Told when a file's reading begins and ends: it stops the process when one runs away (`ReadWatchdog`).
    public var watchdog: ReadWatchdog?
    /// Nanoseconds the Mac has been awake, for how long a long file's steps took; swapped in tests.
    var awake: () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    /// What a long file's steps took so far (milliseconds, in its `info`): the watchdog's total counts from it.
    static let readTime = "read_ms"
    /// How an item is read; swapped in tests.
    var read: (ItemRecord, PhotoSource?, Int) -> Reading = { item, photos, from in
        if PhotoPath.id(item.path) != nil, let photos { return PhotoIndexing.read(item, source: photos) }
        guard FileManager.default.fileExists(atPath: item.path) else { return Reading(outcome: .failed(Indexer.gone)) }
        // The file listed, before and after: what was read is kept only if it was that file all along.
        guard Indexer.isListed(item.path, inode: item.inode) else { return Reading(outcome: .failed(Indexer.notListed)) }
        let reading = Reader.read(URL(fileURLWithPath: item.path), kind: item.kind, from: from)
        return Indexer.isListed(item.path, inode: item.inode) ? reading : Reading(outcome: .failed(Indexer.notListed))
    }

    static let notListed = "not the file that was listed: replaced while waiting to be read"
    static let gone = "file is gone"

    /// Whether `path` is still the file a walk listed: a regular file, not a link (or anything else) put in its
    /// place since, with the inode it had (pre-release review, should-fix 12: a file swapped for a link to one outside
    /// the folders, between the walk and the read, was read as if it were inside; the walk itself never follows
    /// links). Not the device: an external disk's changes each time it's mounted. Inode 0: listed before inodes were
    /// kept, only the kind of file is checked.
    static func isListed(_ path: String, inode: UInt64) -> Bool {
        var info = stat()
        // No link anywhere in the path (the walk's paths have none): a folder above it swapped for one isn't followed.
        guard fstatat(AT_FDCWD, path, &info, AT_SYMLINK_NOFOLLOW_ANY) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return false
        }
        return inode == 0 || UInt64(info.st_ino) == inode
    }

    /// The file a stopped process was reading (`ReadWatchdog`), if one was: marked as one that couldn't be read, with
    /// why, until it changes. One stopped while its pictures and sound were made again for vectors keeps what was
    /// read; they no longer wait for vectors, until it changes. A version changed since (and read again by another
    /// process) isn't marked. Nor one not on this Mac now (a share gone or a drive unplugged mid-read, maybe why it
    /// hung): one waiting is set aside as any other (`setAside`), the rest of a long one and its pictures and sound
    /// are left to wait; the attempt still counts (`maxAttempts`).
    ///
    /// First, the file it was reading when it was asked to quit (`ReadWatchdog.noteAskedToStop`): that attempt is
    /// taken back (luoke-search#65). Not when the watchdog's note names the same version: the watchdog stopped it.
    public func noteStopped(_ directory: DataDirectory) throws {
        let stopped = ReadWatchdog.stopped(directory)
        if let asked = ReadWatchdog.askedToStop(directory) {
            if let item = try store.item(path: asked.path), asked.mtime ?? item.mtime == item.mtime,
               asked.size ?? item.size == item.size,
               stopped.map({ $0.path != asked.path || $0.mtime != asked.mtime || $0.size != asked.size }) ?? true {
                try store.takeBackAttempt(item.id)
            }
            ReadWatchdog.clearAskedToStop(directory)
        }
        if let stopped {
            if let item = try store.item(path: stopped.path), stopped.mtime ?? item.mtime == item.mtime,
               stopped.size ?? item.size == item.size {
                if !isHere(item) {
                    if item.state == "pending" { try store.setAside(item) }
                } else if stopped.stage == ReadWatchdog.media {
                    try store.giveUpMedia(item: item.id, why: stopped.why)
                } else if item.state == "pending" {
                    try store.store(Reading(outcome: .failed(stopped.why)), for: item, reader: Reader.versions[item.kind] ?? 0)
                } else if item.state == "partial" {
                    try store.storeMore(Reading(outcome: .failed(stopped.why)), for: item, from: nil)
                }
            }
            ReadWatchdog.clearStopped(directory)
        }
    }

    /// What's read first in a first pass (11-10, once the whole home folder is searched): files in these folders, and
    /// any changed since this time, ahead of the rest. Empty: the kinds' order alone.
    public var readFirst = ReadFirst()

    public struct ReadFirst: Sendable, Equatable {
        public var folders: [String] = []
        public var since: Double?

        public init(folders: [String] = [], since: Double? = nil) {
            self.folders = folders
            self.since = since
        }
    }

    /// The desktop, documents and downloads, and what changed in the last 30 days: what people look for the same
    /// day, while the rest of a large home folder takes hours.
    public static func usualFirst(home: String = NSHomeDirectory(), now: Date = Date()) -> ReadFirst {
        let home = Crawler.canonical(home)
        return ReadFirst(folders: ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 },
                         since: now.timeIntervalSince1970 - 30 * 86_400)
    }

    public init(store: IndexStore, crawler: Crawler = Crawler()) {
        self.store = store
        self.crawler = crawler
    }

    /// Brings the index in line with `roots` as they are now. Items under a root that can't be reached (an unplugged
    /// drive, a folder macOS doesn't let us read) are kept: they come back when it does.
    public func sync(_ roots: [String]) throws -> SyncReport {
        var report = SyncReport()
        report.requeued = try store.requeueOlderReaders() + store.requeueGoneOnce()
        let walk = crawler.walk(roots)
        if walk.stopped { throw CancellationError() }   // incomplete: nothing may be removed because of it
        report.skipped = walk.skipped
        report.unreachable = walk.unreachable
        report.datasets = walk.datasets
        let reachable = roots.map(Crawler.canonical).filter { !walk.unreachable.contains($0) }
        // Folders outside this walk (another root, one unplugged now) keep what an earlier walk found (review D-10).
        var datasets = try store.datasetFolders().filter { folder, _ in
            !reachable.contains { folder == $0 || folder.hasPrefix($0 + "/") }
        }
        datasets.merge(walk.datasets) { _, new in new }
        try store.setDatasetFolders(datasets)
        // A root that can't be reached inside one that can (iCloud Drive not allowed, in a home folder that is) keeps
        // its items too: the outer walk never goes there, so they aren't gone.
        try apply(known: try store.items(under: reachable), found: walk.files, kept: walk.kept,
                  keptFolders: walk.keptFolders + walk.unreachable, into: &report)
        return report
    }

    /// Only what changed (FSEvents' paths, under `roots`): each changed folder is walked again, each changed file
    /// looked at, and items at paths that are gone are removed, unless they turn up at another changed path (a move).
    public func sync(_ roots: [String], changed paths: [String]) throws -> SyncReport {
        var report = SyncReport()
        var known: [ItemRecord] = []
        var files: [FoundFile] = []
        var kept: [String] = [], keptFolders: [String] = []
        let roots = roots.map(Crawler.canonical)
        for root in roots {
            // Each path to its innermost root only: a path in iCloud Drive isn't the home folder's to judge (its walk
            // never goes into ~/Library, and would take the items for gone).
            let mine = paths.filter { FolderWatcher.innermost($0, roots) == root }
            guard !mine.isEmpty else { continue }
            // A root that can't be listed now (a drive gone, access taken back) keeps its items, as in a whole walk.
            guard (try? FileManager.default.contentsOfDirectory(atPath: root)) != nil else { continue }
            let walk = crawler.walk(mine, under: root)
            if walk.stopped { throw CancellationError() }
            files += walk.files
            kept += walk.kept
            keptFolders += walk.keptFolders
            report.skipped.merge(walk.skipped, uniquingKeysWith: +)
            var theirs: [ItemRecord] = []
            for path in mine {
                if let item = try store.item(path: path) { theirs.append(item) }
                theirs += try store.items(under: [path])
            }
            // Not what's under another root inside this one (the home folder changed as a whole: iCloud Drive's
            // items are its own root's).
            known += theirs.filter { FolderWatcher.innermost($0.path, roots) == root }
        }
        try apply(known: known, found: files, kept: kept, keptFolders: keptFolders, into: &report)
        return report
    }

    /// Brings `known` (indexed items in some part of the folders) in line with `found` (the files that part holds now).
    /// Items at or under a `kept` path stay as they are.
    private func apply(known items: [ItemRecord], found files: [FoundFile], kept: [String] = [],
                       keptFolders: [String] = [], into report: inout SyncReport) throws {
        let keep = Set(kept)
        func isKept(_ path: String) -> Bool {
            keep.contains(path) || keptFolders.contains { path.hasPrefix($0 + "/") }
        }
        let known = Dictionary(items.filter { !isKept($0.path) }.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let found = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var gone = known.values.filter { found[$0.path] == nil }
        // Set aside while their files weren't on this Mac: found here now, they wait to be read again.
        let aside = known.values.contains { $0.state == "pending" } ? try store.setAsideItems() : []
        // A file can show up twice (a folder and a file in it both changed): once is enough.
        var seen = Set<String>()
        let new = files.filter { known[$0.path] == nil && seen.insert($0.path).inserted }

        // A file that disappeared from one path and appeared at another with the same inode, size and time was moved
        // or renamed: keep what was read, change the path.
        var byIdentity: [String: ItemRecord] = [:]
        for item in gone { byIdentity[Self.identity(item.device, item.inode, item.size, item.mtime)] = item }
        for file in new {
            let key = Self.identity(file.device, file.inode, file.size, file.mtime)
            if let item = byIdentity.removeValue(forKey: key), item.kind == file.kind {
                try store.moved(item.id, to: file.path)
                if aside.contains(item.id) { try store.backHere(item.id) }
                gone.removeAll { $0.id == item.id }
                report.moved += 1
            } else if try store.item(path: file.path) == nil {   // (one outside this part is already indexed)
                try store.add(file)
                report.added += 1
            }
        }
        for item in gone {
            try store.remove(item.id)
            report.removed += 1
        }
        for (path, item) in known {
            guard let file = found[path] else { continue }
            // Another file in its place counts too (a new inode, the same size and date: `rsync -a`, `cp -p`): one
            // read as "not the file that was listed" is read again (the review of should-fix 12).
            if file.size != item.size || abs(file.mtime - item.mtime) > 0.001 || file.kind != item.kind
                || item.inode != 0 && file.inode != item.inode {
                try store.changed(item.id, to: file)
                report.changed += 1
            } else {
                if aside.contains(item.id) { try store.backHere(item.id) }
                report.unchanged += 1
            }
        }
    }

    static func identity(_ device: UInt64, _ inode: UInt64, _ size: Int64, _ mtime: Double) -> String {
        "\(device):\(inode):\(size):\(Int64((mtime * 1000).rounded()))"
    }

    /// Removes items that aren't under any of `roots` (a folder the user stopped searching). Returns how many.
    @discardableResult
    public func prune(keeping roots: [String]) throws -> Int {
        let kept = roots.map(Crawler.canonical).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var doomed: [Int64] = []
        try store.db.query("SELECT id, path FROM items WHERE source = 'file'") { row in
            let path = row.text(1) ?? ""
            if !kept.contains(where: { path.hasPrefix($0) }) { doomed.append(row.int(0)) }
        }
        for id in doomed { try store.remove(id) }
        return doomed.count
    }

    /// Reads waiting items, `batch` at a time, until none are left or `shouldStop` says so. Calls `progress` after
    /// each item. Returns how many were read. Files not on this Mac now are set aside, not read
    /// (`IndexStore.setAside`).
    @discardableResult
    public func readPending(batch: Int = 50, latestFirst: Bool = false, shouldStop: () -> Bool = { false },
                            progress: (ItemRecord, Reading) -> Void = { _, _ in }) throws -> Int {
        var count = 0
        while !shouldStop() {
            let items = try store.pending(limit: batch, latestFirst: latestFirst, photos: photos != nil, first: readFirst)
            if items.isEmpty { break }
            for item in items {
                if shouldStop() { return count }
                // Its contents moved off to iCloud, its drive unplugged, since it was listed: not opened (that would
                // download it) nor read as gone, as in `readRest` (review D-6). Queued again once a walk finds it here.
                guard isHere(item) else {
                    try store.setAside(item)
                    continue
                }
                // Twice begun and never finished: reading it ended the process. It waits until the file changes
                // (review A-02: otherwise the resident service would read it first again, and end again, forever).
                if item.attempts >= Self.maxAttempts {
                    let failed = Reading(outcome: .failed("reading it ended the process"))
                    try store.store(failed, for: item, reader: Reader.versions[item.kind] ?? 0)
                    count += 1
                    progress(item, failed)
                    continue
                }
                // Watched before the attempt is noted: one asked to quit while it's noted is taken back as well.
                watchdog?.begin(item.path, mtime: item.mtime, size: item.size)
                defer { watchdog?.end() }
                try store.startReading(item.id)
                let reading = try autoreleasepool { () throws -> Reading? in
                    let began = awake()
                    var reading = read(item, photos, 1)
                    // Its drive unplugged while it was read: set aside as above, not failed for good.
                    if case .failed = reading.outcome, !isHere(item) {
                        try store.setAside(item)
                        try store.readEnded(item)
                        return nil
                    }
                    // A long file's first step counts towards its steps' total (`ReadWatchdog.totalLimit`).
                    if reading.readTo != nil { reading.info[Self.readTime] = String((awake() - began) / 1_000_000) }
                    try store.store(reading, for: item, reader: Reader.versions[item.kind] ?? 0)
                    return reading
                }
                guard let reading else { continue }
                count += 1
                progress(item, reading)
            }
        }
        return count
    }

    /// The rest of long files, which the first pass read only the start of (`Reading.readTo`): one step (30 pages of
    /// a PDF, the rest of a document) at a time, each stored as it's read, so stopping loses nothing and the next run
    /// goes on from there.
    /// Returns how many steps were read.
    @discardableResult
    public func readRest(shouldStop: () -> Bool = { false }, progress: (ItemRecord) -> Void = { _ in }) throws -> Int {
        var steps = 0
        // Files not on this Mac to read now (a drive unplugged, contents moved off to iCloud since): left as they are
        // for another run, not read as gone nor downloaded (review D-6).
        var away = Set<Int64>()
        while !shouldStop(),
              let item = try store.partialItems(limit: away.count + 1).first(where: { !away.contains($0.id) }) {
            guard isHere(item) else {
                away.insert(item.id)
                continue
            }
            // Twice begun and never finished, as for a first read (review A-02): what was read stays, the rest waits
            // until the file changes (review D-1).
            if item.attempts >= Self.maxAttempts {
                try store.storeMore(Reading(outcome: .failed("reading it ended the process")), for: item, from: nil)
                continue
            }
            let info = try store.info(of: item.id)
            let from = (Int(info["read_to"] ?? "") ?? 0) + 1
            // Its steps so far, towards their total (pre-release review, should-fix 2): one that took it all already
            // (read with no watchdog on), or all but too little for a step, isn't read further.
            let before = Double(Int(info[Self.readTime] ?? "") ?? 0) / 1000
            let pages = Int(info["pages"] ?? "") ?? 0
            let total = ReadWatchdog.total(watchdog?.totalLimit ?? ReadWatchdog.defaultTotalTimeLimit, pages: pages)
            if before > total - ReadWatchdog.leastStep {
                let why = "reading it took more than \(ReadWatchdog.describe(max(total - ReadWatchdog.leastStep, 0))) in all"
                try store.storeMore(Reading(outcome: .failed(why)), for: item, from: nil)
                continue
            }
            watchdog?.begin(item.path, mtime: item.mtime, size: item.size, before: before, pages: pages)
            do { try store.startReading(item.id) } catch {
                watchdog?.end()
                throw error
            }
            let began = awake()
            var reading = autoreleasepool { read(item, photos, from) }
            reading.info[Self.readTime] = String((awake() - began) / 1_000_000)
            watchdog?.end()
            // Its drive unplugged while this step was read: left for another run as above, not ended as read for good.
            if case .failed = reading.outcome, !isHere(item) {
                try store.readEnded(item)
                away.insert(item.id)
                continue
            }
            // Changed meanwhile, or another process stored this step first: nothing stored; the next look sees which.
            guard try store.storeMore(reading, for: item, from: from) else { continue }
            steps += 1
            progress(item)
        }
        return steps
    }

    /// Whether an item's file is there to read now, its contents on this Mac.
    func isHere(_ item: ItemRecord) -> Bool {
        if PhotoPath.id(item.path) != nil { return true }
        var info = stat()
        return lstat(item.path, &info) == 0 && !crawler.isDataless(info)
    }
}
