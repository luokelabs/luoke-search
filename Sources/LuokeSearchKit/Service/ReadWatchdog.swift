import Darwin
import Foundation

/// Ends the process when reading one file runs away. Some files make the system's readers grow without end or never
/// return (Apple's PDF text extraction was seen taking 30 GB in 3.5 minutes), and nothing stops code like that from
/// outside but ending the process. While a file is being read (`begin` … `end`, from `Indexer`), the watchdog looks
/// every second at this process's memory (its footprint, as Activity Monitor counts it) and at how long the file has
/// taken. Past `memoryLimit` with at least half of it grown during this read, or past `timeLimit` of the Mac being
/// awake, it writes the file down with why (`<data>/run/stopped-file.json`) and exits with `exitCode` (EX_TEMPFAIL:
/// "start me again"). The next start marks that file, as it was then, as one that couldn't be read
/// (`Indexer.noteStopped`), so it isn't read again until it changes. The idea is upstream DigUp's (`Watchdog`,
/// fe82ff0); this is written for luoke-search's resident loop and `index --job`.
/// Filling in vectors is watched the same way where a file is opened again: a PDF's page pictures, a video's frames,
/// a recording's windows made again for luoke-core (`VectorFiller`, stage `media`). Its memory counts from the file's
/// start (one document stays open for all its pictures), sent or not; its time only while pictures are made (`pause`
/// while they're sent), a step of `Reader.pdfStep` at a time (`newStep`), as a long file is read. A file that runs
/// away there keeps its text; only its pictures and sound stop waiting for vectors, until it changes.
/// A file's steps together have `totalLimit`, more for a file of many pages (`total`): those of this begin … end
/// (`newStep`), and those read before (`begin`'s `before`, which `Indexer` keeps for a long file between its steps).
public final class ReadWatchdog: @unchecked Sendable {
    public struct Stopped: Codable, Equatable, Sendable {
        public let path: String
        public let why: String
        /// The file as it was when its read began: a version changed since isn't blamed (review D-7).
        public var mtime: Double?
        public var size: Int64?
        /// What was being done with it: nil reading it, `media` making its pictures and sound again for vectors.
        public var stage: String? = nil
    }

    /// Making a file's pictures and sound again for vectors (`VectorFiller`).
    public static let media = "media"

    public static let exitCode: Int32 = 75

    /// Half the Mac's memory, but at least 4 GB and at most 8 GB.
    public static var defaultMemoryLimit: UInt64 {
        min(8 << 30, max(4 << 30, ProcessInfo.processInfo.physicalMemory / 2))
    }

    /// One file never takes this long: an hour of video is minutes, a long book is read 30 pages a step.
    public static let defaultTimeLimit: TimeInterval = 15 * 60

    /// A long file's steps together never take this long, or `timePerPage` for each of its pages if that's more
    /// (`total`; pre-release review, should-fix 2: each step had its own 15 minutes, so one file of 50 steps could
    /// take 12 hours).
    public static let defaultTotalTimeLimit: TimeInterval = 60 * 60

    /// A dense scanned page took 0.6 s to read on an M3 Pro (31 pages in 18 s, 10-26); this leaves room for a slower
    /// Mac at background priority. 2000 pages, all that's read of a PDF: 2 hours 47 minutes.
    public static let timePerPage: TimeInterval = 5

    /// A step isn't begun with less than this left of the total: the watchdog would end the process a moment into it.
    public static let leastStep: TimeInterval = 60

    /// What a file of `pages` pages (or pictures and sound to make) may take in all: `least`, or more for a long one.
    public static func total(_ least: TimeInterval, pages: Int) -> TimeInterval {
        max(least, Double(min(max(pages, 0), PDFReading.maxPages)) * timePerPage)
    }

    let note: URL
    let askedNote: URL
    let memoryLimit: UInt64
    let timeLimit: TimeInterval
    let totalLimit: TimeInterval
    let checkEvery: TimeInterval
    /// This process's memory; swapped in tests.
    var footprint: () -> UInt64? = ReadWatchdog.footprint
    /// Nanoseconds the Mac has been awake (CLOCK_UPTIME_RAW stands still while it sleeps); swapped in tests.
    var awake: () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    /// What stopping does: write the note (done before), then end the process. Tests record instead.
    var onStop: (Stopped) -> Void = { _ in _exit(ReadWatchdog.exitCode) }

    private let lock = NSLock()
    /// The file being worked on: since when (nil while paused), the time spent before that in this step, in its steps
    /// before this one, its memory at the start, what its steps may take in all.
    private var reading: (file: Stopped, since: UInt64?, spent: UInt64, before: UInt64, footprint: UInt64, total: TimeInterval)?
    private var running = false
    private var askedToStop = false

    public init(directory: DataDirectory, memoryLimit: UInt64 = ReadWatchdog.defaultMemoryLimit,
                timeLimit: TimeInterval = ReadWatchdog.defaultTimeLimit,
                totalLimit: TimeInterval = ReadWatchdog.defaultTotalTimeLimit, checkEvery: TimeInterval = 1) {
        note = Self.location(directory)
        askedNote = Self.askedLocation(directory)
        self.memoryLimit = memoryLimit
        self.timeLimit = timeLimit
        self.totalLimit = totalLimit
        self.checkEvery = checkEvery
    }

    /// Watches from now on, on a thread of its own.
    public func start() {
        guard lock.withLock({ () -> Bool in defer { running = true }; return !running }) else { return }
        Thread.detachNewThread { [self] in
            while true {
                Thread.sleep(forTimeInterval: checkEvery)
                if let stopped = check() {
                    try? FileManager.default.createDirectory(at: note.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try? JSONEncoder().encode(stopped).write(to: note, options: .atomic)
                    // No path on stderr: luoke-core keeps it (the note, in the private data directory, has it).
                    FileHandle.standardError.write(Data("luoke-search: watchdog: \(stopped.why); stopping\n".utf8))
                    onStop(stopped)
                    return
                }
            }
        }
    }

    /// `before`: the time the file's earlier steps took (seconds); `pages`: how many it has (`total`).
    func begin(_ path: String, mtime: Double? = nil, size: Int64? = nil, stage: String? = nil, before: TimeInterval = 0,
               pages: Int = 0) {
        let file = Stopped(path: path, why: "", mtime: mtime, size: size, stage: stage)
        let footprint = footprint() ?? 0
        let total = Self.total(totalLimit, pages: pages)
        let asked = lock.withLock { () -> Bool in
            reading = (file, awake(), 0, UInt64(min(max(before, 0), total) * 1e9), footprint, total)
            return askedToStop
        }
        // Begun after the quit was asked (the one in hand finished before the stop reached the loop): this one is
        // the one that may be killed.
        if asked { writeAsked(file) }
    }

    func end() { lock.withLock { reading = nil } }

    /// Asked to quit (SIGTERM): the file being read, if one is, written down at once (`<data>/run/asked-to-stop.json`),
    /// before anything waits; and from then on each file begun, in place of it. luoke-core kills a quitting accessory
    /// after 15 s, sooner than a long read ends; a read ended that way isn't the file's doing, so the next run takes
    /// its attempt back (`Indexer.noteStopped`, luoke-search#65). Not while its pictures and sound are made again for
    /// vectors: those tries count too (`IndexStore.startMedia`), but the stop is asked after every picture, so that
    /// work is over long before the kill.
    public func noteAskedToStop() {
        guard let file = lock.withLock({ () -> Stopped? in
            askedToStop = true
            return reading?.file
        }) else { return }
        writeAsked(file)
    }

    private func writeAsked(_ file: Stopped) {
        guard file.stage == nil else { return }
        let asked = Stopped(path: file.path, why: "asked to stop", mtime: file.mtime, size: file.size)
        try? FileManager.default.createDirectory(at: askedNote.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(asked).write(to: askedNote, options: .atomic)
    }

    /// The file's work stops for a while (its pictures sent to luoke-core): that time isn't counted. Its memory still
    /// is (the document stays open; a check only once a second would miss a short burst of work).
    func pause() {
        lock.withLock {
            guard let since = reading?.since else { return }
            reading?.spent += awake() - since
            reading?.since = nil
        }
    }

    func resume() {
        lock.withLock { if reading != nil, reading?.since == nil { reading?.since = awake() } }
    }

    /// A new step of the same file: its time counts from here (the step before towards the total), its memory still
    /// from the file's start.
    func newStep() {
        lock.withLock {
            guard let current = reading else { return }
            let now = awake()
            reading?.before += current.spent + (current.since.map { now - $0 } ?? 0)
            reading?.spent = 0
            if current.since != nil { reading?.since = now }
        }
    }

    /// The file being read and why it must stop, if it must.
    func check() -> Stopped? {
        guard let reading = lock.withLock({ reading }) else { return nil }
        func stopped(_ why: String) -> Stopped {
            Stopped(path: reading.file.path, why: why, mtime: reading.file.mtime, size: reading.file.size,
                    stage: reading.file.stage)
        }
        let doing = reading.file.stage == Self.media ? "making its pictures and sound for vectors" : "reading it"
        // The whole process is measured, but a file is only blamed for what grew while it was read: memory the
        // process held before (vectors, caches) doesn't make the next file fail (review D-8).
        if let footprint = footprint(), footprint > memoryLimit, footprint - min(footprint, reading.footprint) > memoryLimit / 2 {
            return stopped("\(doing) needed more than \(memoryLimit >> 30) GB of memory")
        }
        // Time the Mac was awake: a lid closed for the night isn't a read that ran away (review D-2).
        // Time the Mac was awake and the file was being worked on (not while its pictures were sent).
        let step = Double(reading.spent + (reading.since.map { awake() - $0 } ?? 0)) / 1e9
        if step > timeLimit {
            return stopped("\(doing) took more than \(Self.describe(timeLimit))")
        }
        if Double(reading.before) / 1e9 + step > reading.total {
            return stopped("\(doing) took more than \(Self.describe(reading.total)) in all")
        }
        return nil
    }

    static func describe(_ limit: TimeInterval) -> String {
        limit >= 120 ? "\(Int(limit / 60)) minutes" : "\(Int(limit)) seconds"
    }

    static func location(_ directory: DataDirectory) -> URL {
        directory.runFolder.appendingPathComponent("stopped-file.json")
    }

    /// The note a stopped process left. It's removed (`clearStopped`) only once it's been written into the index, so
    /// a start that can't write it (the index busy) leaves it for the next (review D-1).
    public static func stopped(_ directory: DataDirectory) -> Stopped? {
        guard let data = try? Data(contentsOf: location(directory)) else { return nil }
        return try? JSONDecoder().decode(Stopped.self, from: data)
    }

    public static func clearStopped(_ directory: DataDirectory) {
        try? FileManager.default.removeItem(at: location(directory))
    }

    static func askedLocation(_ directory: DataDirectory) -> URL {
        directory.runFolder.appendingPathComponent("asked-to-stop.json")
    }

    /// The file a process asked to quit was reading (`noteAskedToStop`), if one was. Removed once it's in the index,
    /// as the watchdog's note.
    public static func askedToStop(_ directory: DataDirectory) -> Stopped? {
        guard let data = try? Data(contentsOf: askedLocation(directory)) else { return nil }
        return try? JSONDecoder().decode(Stopped.self, from: data)
    }

    public static func clearAskedToStop(_ directory: DataDirectory) {
        try? FileManager.default.removeItem(at: askedLocation(directory))
    }

    /// This process's footprint: the memory the kernel charges it.
    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
