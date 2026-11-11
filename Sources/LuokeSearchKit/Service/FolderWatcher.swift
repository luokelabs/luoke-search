import CoreServices
import Foundation

/// Tells which paths changed under the folders being searched (FSEvents, file by file). Changes are gathered until
/// things have been quiet for `quiet` seconds (0.75: a save is often several writes), then handed to `handler` on the
/// work queue. Events arrive on a queue of their own, so `hasPending` is true as soon as something changes, even while
/// the work queue is busy reading (the first-pass step yields to it). Paths inside hidden folders and hidden files
/// (`.DS_Store`) are left out: they're never indexed.
final class FolderWatcher: @unchecked Sendable {
    private let work: DispatchQueue
    private let events = DispatchQueue(label: "ai.luoke.search.fsevents")
    private let quiet: TimeInterval
    private let handler: ([String]) -> Void
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var roots: [String] = []
    private var pending = Set<String>()
    private var firstPending: Date?
    private var flush: DispatchWorkItem?
    private var _ignoring: (String) -> Bool = { _ in false }
    /// Changes are handed over at most this long after the first of them, however busy the folder stays (a library
    /// syncing, a download, a build: review A-07).
    let maxWait: TimeInterval

    /// Paths whose changes don't matter (inside packages, developer folders, skipped folders): never pending.
    var ignoring: (String) -> Bool {
        get { lock.withLock { _ignoring } }
        set { lock.withLock { _ignoring = newValue } }
    }

    init(queue: DispatchQueue, quiet: TimeInterval = 0.75, maxWait: TimeInterval = 5,
         handler: @escaping ([String]) -> Void) {
        work = queue
        self.quiet = quiet
        self.maxWait = maxWait
        self.handler = handler
    }

    deinit { stopStream() }

    /// Watches these folders from now on, replacing what was watched.
    func watch(_ folders: [String]) {
        events.sync {
            stopStream()
            lock.withLock { roots = folders }
            guard !folders.isEmpty else { return }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                var changed: [String] = []
                for index in 0..<min(count, list.count) {
                    let flag = Int(flags[index])
                    let rescan = flag & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0
                    changed.append(rescan ? watcher.root(of: list[index]) ?? list[index] : list[index])
                }
                watcher.received(changed)
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                                                 | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
            guard let created = FSEventStreamCreate(nil, callback, &context, folders as CFArray,
                                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else {
                return
            }
            FSEventStreamSetDispatchQueue(created, events)
            FSEventStreamStart(created)
            stream = created
        }
    }

    func stop() {
        events.sync {
            stopStream()
            flush?.cancel()
        }
        lock.withLock { pending.removeAll() }
    }

    /// Changes not yet handed over.
    var hasPending: Bool { lock.withLock { !pending.isEmpty } }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    func root(of path: String) -> String? {
        lock.withLock { Self.innermost(path, roots) }
    }

    /// The root a path belongs to: the innermost one holding it (iCloud Drive's, not the home folder's).
    static func innermost(_ path: String, _ roots: [String]) -> String? {
        roots.filter { path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
    }

    /// On `events`.
    private func received(_ paths: [String]) {
        let (added, waited) = lock.withLock { () -> (Bool, TimeInterval) in
            var any = false
            for path in paths {
                guard let root = Self.innermost(path, roots) else { continue }
                if path.dropFirst(root.count).split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
                if _ignoring(path) { continue }
                pending.insert(path)
                any = true
            }
            if any, firstPending == nil { firstPending = Date() }
            return (any, firstPending.map { Date().timeIntervalSince($0) } ?? 0)
        }
        guard added else { return }
        flush?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let paths = lock.withLock { () -> [String] in
                defer {
                    pending.removeAll()
                    firstPending = nil
                }
                return Array(pending)
            }
            guard !paths.isEmpty else { return }
            work.async { self.handler(paths) }
        }
        flush = item
        events.asyncAfter(deadline: .now() + max(0, min(quiet, maxWait - waited)), execute: item)
    }
}
