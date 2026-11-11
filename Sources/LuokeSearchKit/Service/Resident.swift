import Foundation

/// Reads the folders (and the Photos library, if the user turned it on and allowed it) through once — the long
/// first pass — in steps that can stop at any moment and go on next time. Run by `luoke-search index --job` (meant to
/// be luoke-core's idle job: luoke-core#16) and, until luoke-core can launch a Swift accessory's job, by the resident
/// loop when the Mac allows it (`Resident`).
public struct FirstPass {
    public struct Report: Sendable {
        public var sync = Indexer.SyncReport()
        public var read = 0
        public var vectors = VectorFiller.Report()
        public var stopped = false
        /// Steps of long files read (the rest of what the first pass read only the start of).
        public var restSteps = 0
        /// The settings file couldn't be read: nothing was done (review A-05).
        public var unreadableSettings = false
    }

    public let directory: DataDirectory
    public let store: IndexStore
    public let hub: Hub?
    public let photos: PhotoSource?
    /// Walk the folders and list the library first. The resident loop follows changes itself and leaves this off:
    /// a whole walk every step would be work for nothing (reviews A-21, C-06).
    public var syncs = true
    /// Walks only the chosen folders `Settings.searchable` (the app as it ships).
    public var restrictFolders = false
    /// Stops the process when reading one file runs away (`ReadWatchdog`).
    public var watchdog: ReadWatchdog?
    /// When files are still waiting to be read after this step, filling vectors stops after this long (the resident
    /// loop sets it: a backlog of vectors mustn't hold new files back for hours).
    public var vectorSlice: TimeInterval?

    public init(directory: DataDirectory, store: IndexStore, hub: Hub?, photos: PhotoSource? = nil) {
        self.directory = directory
        self.store = store
        self.hub = hub
        self.photos = photos
    }

    /// The Photos library to read now: photos turned on in the settings, and access allowed.
    public static func usable(_ photos: PhotoSource?, _ settings: Settings) -> PhotoSource? {
        guard settings.photos, let photos, photos.access == .allowed else { return nil }
        return photos
    }

    /// Syncs the settings' folders and the Photos library, reads what's waiting (at most `limit` items), adds
    /// vectors, and notes when the first pass is done. `shouldStop` is asked between items (and folders): it ends the
    /// step where it is, nothing half done.
    public func run(limit: Int? = nil, shouldStop: @escaping () -> Bool = { false }) throws -> Report {
        var report = Report()
        guard let settings = Settings.read(directory) else {
            report.unreadableSettings = true
            return report
        }
        let library = Self.usable(photos, settings)
        var crawler = Crawler(excludedFolders: settings.skipFolders)
        crawler.shouldStop = shouldStop
        let indexer = Indexer(store: store, crawler: crawler)
        indexer.photos = library
        indexer.watchdog = watchdog
        indexer.readFirst = Indexer.usualFirst()
        do {
            try indexer.noteStopped(directory)
            if syncs {
                let folders = settings.searched(restricted: restrictFolders)
                if !folders.isEmpty {
                    report.sync = try indexer.sync(folders)
                }
                report.sync.removed += try indexer.prune(keeping: settings.keptRoots(restricted: restrictFolders))
                if let library {
                    let photos = try PhotoIndexing.sync(library, store: store, shouldStop: shouldStop)
                    report.sync.added += photos.added
                    report.sync.changed += photos.changed
                    report.sync.removed += photos.removed
                } else if !settings.photos {
                    report.sync.removed += try PhotoIndexing.removeAll(store: store)
                }
            }
            var count = 0
            let enough = { () -> Bool in shouldStop() || (limit.map { count >= $0 } ?? false) }
            report.read = try indexer.readPending(batch: 20, shouldStop: enough, progress: { _, _ in count += 1 })
            // Then the rest of long files: only once nothing else waits (every file read through once).
            if !enough() { report.restSteps = try indexer.readRest(shouldStop: enough, progress: { _ in count += 1 }) }
        } catch is CancellationError {
            report.stopped = true
            return report
        }
        report.stopped = shouldStop()
        if !report.stopped, let hub {
            let filler = VectorFiller(store: store, hub: hub)
            filler.photos = library
            filler.watchdog = watchdog
            let deadline = Resident.deadline(vectorSlice, store: store, photos: library != nil)
            report.vectors = filler.run(wait: false, shouldStop: { shouldStop() || Date() > deadline })
            report.stopped = shouldStop()
        }
        try ToolState.noteFirstPassIfDone(directory, store: store, restricted: restrictFolders)
        return report
    }
}

/// luoke-search running in the background (`luoke-search serve`, opened by luoke-core at login): keeps the index in
/// step with the folders and the Photos library as they change, a few items at a time, fills in vectors luoke-core
/// couldn't give before, and answers the agent (`AgentSocket`, set up by the caller). All of its work happens on one
/// serial queue of its own — never on Swift concurrency's pool (reading blocks; see `OCR`).
public final class Resident: @unchecked Sendable {
    public let directory: DataDirectory
    /// Walks only the chosen folders `Settings.searchable` (the app as it ships).
    public var restrictFolders = false
    let store: IndexStore
    let hub: Hub?
    let photos: PhotoSource?
    let queue = DispatchQueue(label: "ai.luoke.search.resident", qos: .utility)
    private var watcher: FolderWatcher!
    private var settings = Settings()
    private var timers: [DispatchSourceTimer] = []
    private var watchingPhotos = false
    /// What was seen at the last reload, to notice changes made elsewhere: the settings file's date (the command
    /// line), Photos access (allowed in System Settings later), folders that couldn't be read (reviews C-05, C-20).
    private var settingsDate: Date?
    private var photosAccess: PhotoAccess?
    private var unreadableFolders: Set<String> = []
    /// The folders watched since the last reload: a disk plugged in or out changes what's searched.
    private var watchedFolders: [String] = []
    /// When luoke-core may be asked for vectors again (it said when).
    private var vectorsAfter = Date.distantPast
    /// A change couldn't be synced (the index was busy): the folders are walked whole at the next look (review A-11).
    private var resyncFolders = false
    private let stopLock = NSLock()
    private var _stopped = false
    private var photosQueued = false
    /// Changes waiting to be handled; nil: list the library again.
    private var photoChanges: [PhotoChanges]? = []
    /// Set at once by `stop()` (not on the queue), so work in progress ends after the item in hand: luoke-core gives
    /// a quitting accessory 15 s before it kills it.
    private var stopped: Bool { stopLock.withLock { _stopped } }

    /// Items read right away after a change (the rest wait for the first pass).
    public var newFilesPerChange = 50
    /// How often it looks around (settings, access) and whether it may read some of the first pass, and how much.
    public var backlogEvery: TimeInterval = 120
    public var backlogStep = 100
    /// How often it fills in vectors still waiting, when luoke-core lets it (review B-01).
    public var vectorsEvery: TimeInterval = 300
    /// While files wait to be read, a run of filling vectors stops after this long, so the queue gets back to reading
    /// them. A large backlog of vectors (an `index --job` that read everything while luoke-core was still loading)
    /// held 150 changed files back for over half an hour at 50,000 files.
    public var vectorSlice: TimeInterval = 60
    /// Photos library changes are gathered this long before the library is looked at again (review C-06).
    public var photosQuiet: TimeInterval = 2
    /// Whether to read the first pass here at all (until luoke-core can launch our job; tests turn it off).
    public var readsBacklog = true
    /// Stops the process when reading one file runs away (`ReadWatchdog`).
    public var watchdog: ReadWatchdog?
    /// What holds reading on this Mac now (`Power.held`; swapped in tests).
    var machine: (Bool) -> [String] = Power.held(onBattery:)

    /// `photos`: the Photos library this process may read (`SystemPhotos.current`: only the app itself).
    public init(directory: DataDirectory, hub: Hub?, photos: PhotoSource? = nil) throws {
        self.directory = directory
        store = try IndexStore(directory: directory)
        self.hub = hub
        self.photos = photos
        watcher = FolderWatcher(queue: queue) { [weak self] paths in self?.changed(paths) }
    }

    public func start() {
        queue.async { self.reload() }
        for (every, work) in [(backlogEvery, backlogTick), (vectorsEvery, fillVectors)] as [(TimeInterval, () -> Void)] {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + every, repeating: every, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in if self != nil { work() } }
            timer.resume()
            timers.append(timer)
        }
    }

    /// The settings changed (a plan was carried out): watch the new folders, drop the old ones, take photos in or out.
    public func settingsChanged() {
        queue.async { self.reload() }
    }

    /// Work in progress ends after the item in hand; nothing waits for it here (`stop` does).
    public func askToStop() {
        stopLock.withLock { _stopped = true }
    }

    public func stop() {
        askToStop()
        queue.sync {
            timers.forEach { $0.cancel() }
            watcher.stop()
        }
    }

    // MARK: Work (all on `queue`)

    private var library: PhotoSource? { FirstPass.usable(photos, settings) }

    private func indexer() -> Indexer {
        var crawler = Crawler(excludedFolders: settings.skipFolders)
        crawler.shouldStop = { [weak self] in self?.stopped ?? true }
        let indexer = Indexer(store: store, crawler: crawler)
        indexer.photos = library
        indexer.watchdog = watchdog
        indexer.readFirst = Indexer.usualFirst()
        return indexer
    }

    /// The searched folders macOS doesn't let it list now, and the protected ones inside them (a searched home
    /// folder's desktop, documents, downloads): one allowed since is walked again.
    private func unreadable(_ folders: [String]) -> Set<String> {
        Set(SearchService.accessTargets(folders, skipped: settings.skipFolders, home: NSHomeDirectory())
            .filter { !SearchService.readable($0) })
    }

    private func reload() {
        guard !stopped else { return }
        resyncFolders = false
        settingsDate = Self.modified(directory.settingsFile)
        guard var read = Settings.read(directory) else {
            // Never taken for "nothing chosen": nothing is synced or removed until it can be read (review A-05).
            log("settings unreadable: left as they are")
            return
        }
        // A chosen disk mounted at another path: followed there (the old path's items are pruned below).
        if !read.volumes.isEmpty, (try? Settings.followDisks(directory, mounted: Volumes.external())) == true {
            settingsDate = Self.modified(directory.settingsFile)
            read = Settings.read(directory) ?? read
        }
        settings = read
        let folders = settings.searched(restricted: restrictFolders).map(Crawler.canonical)
        watchedFolders = folders
        unreadableFolders = unreadable(folders)
        let indexer = indexer()
        try? indexer.noteStopped(directory)   // the file the process ended on last time, if it did
        do {
            // A walk of names and dates only: nothing is read here but new items (below).
            _ = try indexer.sync(folders)
            _ = try indexer.prune(keeping: settings.keptRoots(restricted: restrictFolders))
        } catch is CancellationError {
            return
        } catch {
            log("sync failed")
        }
        watcher.ignoring = Self.ignored(skipping: settings.skipFolders, roots: folders)
        watcher.watch(folders)
        reloadPhotos()
        readNew()
        fillVectors()
    }

    /// Photos turned on and allowed: sync and follow the library. Never asked yet: nothing here asks; the outbox says
    /// so, and luoke's own program asks in its window (§1a; the permission's `owner`). Allowed later is noticed at
    /// the next look (`photosAccess`). Turned off: they go.
    private func reloadPhotos() {
        photosAccess = photos?.access
        guard settings.photos else {
            if let removed = try? PhotoIndexing.removeAll(store: store), removed > 0 { log("photos off: \(removed) gone") }
            return
        }
        guard let library else { return }   // not allowed (or never asked): the outbox says what to do
        // Watched before it's listed: what changes while a large library is being listed comes as changes after the
        // listing, instead of being in neither (review of PR #20).
        if !watchingPhotos {
            watchingPhotos = true
            library.watch { [weak self] changes in self?.photosChangedSoon(changes) }
        }
        if let report = try? PhotoIndexing.sync(library, store: store, shouldStop: { [weak self] in self?.stopped ?? true }) {
            log("photos: \(report.added) new, \(report.changed) changed, \(report.removed) gone")
        }
    }

    /// From PhotoKit's thread: a burst of changes (iCloud syncing, a burst of shots) is handled together, a little
    /// later, with at most one waiting (review C-06). What changed is kept; nil anywhere (PhotoKit couldn't say)
    /// means listing the library again (review A-20).
    private func photosChangedSoon(_ changes: PhotoChanges?) {
        let first = stopLock.withLock { () -> Bool in
            if let changes, photoChanges != nil { photoChanges?.append(changes) } else { photoChanges = nil }
            defer { photosQueued = true }
            return !photosQueued
        }
        guard first else { return }
        queue.asyncAfter(deadline: .now() + photosQuiet) { [weak self] in
            guard let self else { return }
            let changes = stopLock.withLock { () -> [PhotoChanges]? in
                photosQueued = false
                defer { photoChanges = [] }
                return photoChanges
            }
            photosChanged(changes)
        }
    }

    private func photosChanged(_ changes: [PhotoChanges]?) {
        guard !stopped, let library else { return }
        do {
            if let changes {
                for change in changes { _ = try PhotoIndexing.apply(change, source: library, store: store) }
            } else {
                _ = try PhotoIndexing.sync(library, store: store, shouldStop: { [weak self] in self?.stopped ?? true })
            }
        } catch {
            // (The index busy too long, say.) What changed isn't lost: the next look around lists it all again.
            log("photos: changes not taken in; listing the library again soon")
            resyncFolders = true
        }
        readNew()
    }

    private func changed(_ paths: [String]) {
        guard !stopped else { return }
        do {
            let report = try indexer().sync(settings.searched(restricted: restrictFolders).map(Crawler.canonical), changed: paths)
            log("changes: \(report.added) new, \(report.changed) changed, \(report.moved) moved, \(report.removed) gone")
        } catch is CancellationError {
            return
        } catch {
            log("sync failed")
            resyncFolders = true
        }
        readNew()
    }

    /// The newest waiting items, a few: a file that just appeared is searchable in seconds. When those were the last
    /// ones waiting, the first pass is done (review C-04).
    private func readNew() {
        var count = 0
        _ = try? indexer().readPending(batch: 10, latestFirst: true,
                                       shouldStop: { count >= self.newFilesPerChange || self.stopped },
                                       progress: { _, _ in count += 1 })
        if count > 0 {
            try? ToolState.noteFirstPassIfDone(directory, store: store, restricted: restrictFolders)
            fillVectors()
        }
    }

    /// Vectors still waiting (luoke-core was downloading, busy, or changed its model when they were read) are filled
    /// in here, whether or not anything changed since (review B-01); after a refusal, not before luoke-core said.
    private func fillVectors() {
        guard let hub, !stopped, Date() >= vectorsAfter,
              let counts = try? store.counts(), counts.waitingForVectors + counts.waitingForMedia > 0 else { return }
        let background = hub.background()
        guard !Self.vectorsHeld(background) else { return }
        let filler = VectorFiller(store: store, hub: hub)
        filler.photos = library
        filler.watchdog = watchdog
        // Only when reading may go on here now (`backlogHeld`).
        let deadline = readsBacklog && Self.backlogHeld(background, onBattery: settings.onBattery, held: machine).isEmpty
            ? Self.deadline(vectorSlice, store: store, photos: library != nil) : .distantFuture
        let report = filler.run(wait: false, shouldStop: { self.stopped || self.watcher.hasPending || Date() > deadline })
        switch report.stoppedBy {
        case .refused(_, _, let retryAfter)?: vectorsAfter = Date().addingTimeInterval(max(retryAfter ?? 60, 5))
        case .some: vectorsAfter = Date().addingTimeInterval(vectorsEvery)
        case nil: break
        }
    }

    /// Every couple of minutes: settings changed elsewhere (the command line), access granted since (Photos in System
    /// Settings, a folder that couldn't be read) — any of them reloads (reviews C-05, C-20); the first pass noted when
    /// nothing is left; then, when the Mac allows it (`backlogHeld`), a step of the first pass. Yields as soon as
    /// files change.
    private func backlogTick() {
        guard !stopped else { return }
        let folders = settings.searched(restricted: restrictFolders).map(Crawler.canonical)
        if resyncFolders || Self.modified(directory.settingsFile) != settingsDate
            || (settings.photos && photos != nil && photos?.access != photosAccess)
            || folders != watchedFolders || unreadable(folders) != unreadableFolders {
            reload()
            return
        }
        try? ToolState.noteFirstPassIfDone(directory, store: store, restricted: restrictFolders)
        guard readsBacklog, let counts = try? store.counts(), counts.waitingToRead + counts.waitingForRest > 0 else { return }
        guard Self.backlogHeld(hub?.background(), onBattery: settings.onBattery, held: machine).isEmpty else { return }
        var pass = FirstPass(directory: directory, store: store, hub: hub, photos: photos)
        pass.syncs = false
        pass.restrictFolders = restrictFolders
        pass.watchdog = watchdog
        pass.vectorSlice = vectorSlice
        _ = try? pass.run(limit: backlogStep, shouldStop: { self.stopped || self.watcher.hasPending })
    }

    /// Why the long first pass may not read now; empty: it may (luoke-search#46, defect 2; 11-01). While luoke-core
    /// answers, its background state says, battery included: it pauses on battery unless the user lets it run there,
    /// and luoke-search never asks it to (`allow_battery`). Without it, the user's own "on battery too". Never in Low
    /// Power Mode or when hot (`held`, the Mac's own). Paused with no reason given, its state stands in for one: what
    /// counts here is only whether any is left (`Paused.reasons` keeps luoke-core's own).
    static func backlogHeld(_ background: Hub.Background?, onBattery: Bool,
                            held: (Bool) -> [String] = Power.held(onBattery:)) -> [String] {
        guard let background else { return held(onBattery) }
        var reasons = background.state == "running" ? []
            : background.reasons.isEmpty ? [background.state] : background.reasons
        for reason in held(true) where !reasons.contains(reason) { reasons.append(reason) }
        return reasons
    }

    /// Whether filling vectors waits now: only while luoke-core says its background work is paused (the Mac's own
    /// state doesn't hold vectors).
    static func vectorsHeld(_ background: Hub.Background?) -> Bool {
        background.map { $0.state != "running" } ?? false
    }

    /// What waits and doesn't go on now, and why (`search_status` → `paused`, the `status` command): the first pass
    /// as `backlogTick` holds it, vectors as `fillVectors` does. New files are read all the same (`readNew`).
    public struct Paused: Codable, Equatable, Sendable {
        /// Why: luoke-core's own reasons when it paused ("battery", "low_power", "thermal", "memory"; maybe none),
        /// else the Mac's, named the same way.
        public var reasons: [String]
        /// "luoke": luoke-core paused its background work; "mac": the Mac's own state holds the first pass.
        public var by: String
        /// The first pass (files waiting to be read, the rest of long ones) is held.
        public var reading: Bool
        /// Vectors waiting, ones luoke-core would make now, are held.
        public var vectors: Bool
    }

    /// Nil when nothing waiting is held. `task`, `background`: from the `GET /tasks` the caller made (nil: no
    /// answer, no such task, none in it), so nothing more is asked. Only what would go on but for this counts:
    /// - Photos items waiting to be read only with the library at hand (`photos`, as in `deadline`);
    /// - vectors only for a task luoke-core has, pictures and sound only when it takes them (its tier may take text
    ///   only: those wait for another tier, not for the pause).
    public static func paused(_ store: IndexStore, counts: IndexStore.Counts, photos: Bool, task: HubTask?,
                              background: Hub.Background?, onBattery: Bool,
                              held: (Bool) -> [String] = Power.held(onBattery:)) -> Paused? {
        let toRead = counts.waitingForRest > 0 || counts.waitingToRead > 0 && (try? store.hasPending(photos: photos)) == true
        let toEmbed = task.map { task in
            task.status != .unsupported && (counts.waitingForVectors > 0
                || counts.waitingForMedia > 0 && (task.takesImages || task.takesAudio))
        } ?? false
        guard toRead || toEmbed else { return nil }
        let holding = backlogHeld(background, onBattery: onBattery, held: held)
        let byLuoke = vectorsHeld(background)
        let paused = Paused(reasons: byLuoke ? background?.reasons ?? [] : holding, by: byLuoke ? "luoke" : "mac",
                            reading: toRead && !holding.isEmpty, vectors: toEmbed && byLuoke)
        return paused.reading || paused.vectors ? paused : nil
    }

    /// When to stop filling vectors: `slice` from now if something waits that this process can read (Photos items
    /// only with the library at hand), else never.
    static func deadline(_ slice: TimeInterval?, store: IndexStore, photos: Bool) -> Date {
        guard let slice, let next = try? store.pending(limit: 1, photos: photos), !next.isEmpty else { return .distantFuture }
        return Date().addingTimeInterval(slice)
    }

    static func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    /// Changes never worth waking for: inside packages (the Photos library's database, apps), developer folders,
    /// `.noindex` folders, the user's skipped folders (review A-07); and, below the root a path belongs to, any folder
    /// a walk wouldn't go into (`Rules.skipReason`): with the whole home folder watched, ~/Library's caches and app
    /// data, ~/Music, tools' folders change all the time and would keep the first pass yielding.
    static func ignored(skipping: [String], roots: [String] = [], home: String = NSHomeDirectory()) -> (String) -> Bool {
        let skipped = skipping.map(Crawler.canonical)
        let roots = roots.map(Crawler.canonical)
        let home = Crawler.canonical(home)
        let packages: Set<String> = ["photoslibrary", "app", "bundle", "framework", "noindex", "xcodeproj",
                                     "xcworkspace", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle"]
        return { path in
            if skipped.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
            if path.split(separator: "/").dropLast().contains(where: { part in
                Rules.skippedFolderNames.contains(String(part))
                    || packages.contains((part as NSString).pathExtension.lowercased())
            }) { return true }
            guard let root = FolderWatcher.innermost(path, roots) else { return false }
            var folder = root
            for part in path.dropFirst(root.count).split(separator: "/") {
                folder += "/" + part
                // The path itself too: a folder skipped whole (~/Library) changes as a path of its own.
                if Rules.skipReason(folder: URL(fileURLWithPath: folder), home: home, excluded: []) != nil { return true }
            }
            return false
        }
    }

    /// Only what happened, never which file or what's in it.
    private func log(_ line: String) {
        FileHandle.standardError.write(Data("luoke-search: \(line)\n".utf8))
    }
}
