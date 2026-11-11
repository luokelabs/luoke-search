import AppKit
import Foundation

/// How results are opened on the Mac. Tests swap it for one that only records.
public struct Opener: Sendable {
    public var open: @Sendable (_ path: String, _ kind: ItemKind, _ location: Location?) -> Void
    /// Shows the file selected in a Finder window; false when that didn't happen.
    public var reveal: @Sendable (_ path: String) -> Bool
    public var openURL: @Sendable (_ url: URL) -> Void
    /// Only pretends (`dry`): nothing at all is opened, Photos included (review C-18), and what's said about it ends
    /// with "（演习）", so nobody takes it for the real thing.
    public var isDry = false

    public init(open: @escaping @Sendable (String, ItemKind, Location?) -> Void,
                reveal: @escaping @Sendable (String) -> Bool, openURL: @escaping @Sendable (URL) -> Void,
                isDry: Bool = false) {
        self.open = open
        self.reveal = reveal
        self.openURL = openURL
        self.isDry = isDry
    }

    /// The real one: a recording or video opens in QuickTime Player at the moment (`quickTime`), anything else in its
    /// default app; PDFs can't be opened at a page from outside, so the answer says which page.
    public static let mac = Opener(
        open: { path, kind, location in
            let url = URL(fileURLWithPath: path)
            if let time = location?.time, kind == .video || kind == .audio, quickTime(url, at: time) { return }
            NSWorkspace.shared.open(url)
        },
        reveal: { finderReveal($0) },
        openURL: { NSWorkspace.shared.open($0) })

    /// Only says what it would open, on stderr: development runs and agent checks (`LUOKE_SEARCH_OPENER=dry`).
    public static let dry = Opener(
        open: { path, kind, location in
            FileHandle.standardError.write(Data("luoke-search (dry): open \(kind.rawValue) \(path) \(location.map { "\($0)" } ?? "")\n".utf8))
        },
        reveal: { FileHandle.standardError.write(Data("luoke-search (dry): reveal \($0)\n".utf8)); return true },
        openURL: { FileHandle.standardError.write(Data("luoke-search (dry): open \($0)\n".utf8)) },
        isDry: true)

    /// `dry` when `LUOKE_SEARCH_OPENER=dry`, else the real one.
    public static var current: Opener {
        ProcessInfo.processInfo.environment["LUOKE_SEARCH_OPENER"] == "dry" ? .dry : .mac
    }

    static let quickTimeWait: TimeInterval = 5

    /// Shows `path` selected in Finder with `open -R`, and says whether it did. Not `NSWorkspace`'s
    /// `activateFileViewerSelecting`: called off the main thread, which is where the resident serves the agent's
    /// socket, it does nothing at all and says nothing (luoke-search#99). `open` works from any thread and has an exit
    /// status: 1 when the file isn't there. Finder may stay behind the app the user is in: only the app in front
    /// can bring another one forward.
    static func finderReveal(_ path: String, executable: String = "/usr/bin/open", wait: TimeInterval = revealWait) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-R", path]
        return succeeds(process, within: wait)
    }

    static let revealWait: TimeInterval = 5

    /// Runs `process` with its output dropped and says whether it exited 0 within `wait` seconds; stopped if not.
    /// This runs under the server's lock (`MCPServer`): the agent's next call waits that long at most.
    static func succeeds(_ process: Process, within wait: TimeInterval) -> Bool {
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let deadline = Date().addingTimeInterval(wait)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    /// The AppleScript `quickTime` runs: the path inside its quotes with its backslashes and quotes escaped.
    static func quickTimeScript(_ url: URL, at seconds: Double) -> String {
        let escaped = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "QuickTime Player"
                activate
                set movie to open POSIX file "\(escaped)"
                set current time of movie to \(max(0, seconds))
            end tell
            """
        return script
    }

    /// Started by luoke's own program, that program plays it (`playOnHost`): this one never asks macOS to control
    /// QuickTime Player. Otherwise (development, the command line) it does so itself, and macOS asks the first time
    /// whether luoke-search may. False: the caller opens the file plainly.
    static func quickTime(_ url: URL, at seconds: Double) -> Bool {
        if let handed = playOnHost(url, at: seconds) { return handed }
        let script = quickTimeScript(url, at: seconds)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        // The first time, macOS asks whether QuickTime Player may be controlled: not waited for past a few seconds
        // (the agent's call would time out meanwhile), the file is opened plainly instead (review C-12).
        return succeeds(process, within: quickTimeWait)
    }

    /// Names the descriptor luoke's own program left open for this one to ask it for things. Set by that program, so
    /// not one of the development switches (`CommandArguments.developmentVariables`).
    static let hostVariable = "LUOKE_HOST_FD"

    /// One line for luoke's own program: play this file from this moment. A path is one line whatever is in it: JSON
    /// escapes newlines.
    static func playLine(_ url: URL, at seconds: Double) -> Data? {
        guard seconds.isFinite, let path = try? JSONSerialization.data(
            withJSONObject: url.path, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return nil }
        return Data(#"{"play": "#.utf8) + path + Data(", \"at\": \(max(0, seconds))}\n".utf8)
    }

    /// Hands playing to luoke's own program: nil when this process wasn't given a way to (`hostVariable` not set).
    /// Given one that doesn't work, false, not a fall back to `osascript`: macOS would then ask the user about this
    /// program, the very prompt handing it over avoids.
    static func playOnHost(_ url: URL, at seconds: Double,
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           wait: TimeInterval = quickTimeWait) -> Bool? {
        guard let given = environment[hostVariable], !given.isEmpty else { return nil }
        guard let descriptor = Int32(given), isHostChannel(descriptor), let line = playLine(url, at: seconds) else {
            return false
        }
        return send(line, to: descriptor, wait: wait)
    }

    /// Tells luoke's own program the socket is up. It restarts this process when a permission changes and holds back
    /// the tool call that waits on it until now.
    public static func tellHostUp(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let given = environment[hostVariable], let descriptor = Int32(given), isHostChannel(descriptor) else { return }
        _ = send(Data("{\"up\": true}\n".utf8), to: descriptor, wait: 1)
    }

    /// Whether a descriptor can be the one from luoke's own program: a pipe or socket open for writing. The number
    /// comes from the environment, which a child of this process would inherit without the descriptor: there the
    /// number may be anything, a file the index is in, or the agent's standard output.
    static func isHostChannel(_ descriptor: Int32) -> Bool {
        guard descriptor > STDERR_FILENO else { return false }
        let flags = fcntl(descriptor, F_GETFL)
        var info = stat()
        guard flags >= 0, flags & O_ACCMODE != O_RDONLY, fstat(descriptor, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFIFO || info.st_mode & S_IFMT == S_IFSOCK
    }

    /// Writes all of `line`, or false: the other end gone, or not reading for `wait` seconds. Never blocks past that:
    /// this runs under the server's lock (`MCPServer`), so one call at a time, and the agent's call waits. Gone is
    /// an error here, not SIGPIPE: the command line doesn't ignore it. Given up on halfway, the other end gets part
    /// of a line, which isn't JSON, so it's dropped there.
    private static func send(_ line: Data, to descriptor: Int32, wait: TimeInterval) -> Bool {
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else { return false }
        let deadline = Date().addingTimeInterval(wait)
        return line.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let written = write(descriptor, bytes.baseAddress! + sent, bytes.count - sent)
                if written > 0 {
                    sent += written
                    continue
                }
                guard written < 0 else { return false }
                if errno == EINTR { continue }
                let left = deadline.timeIntervalSinceNow
                guard errno == EAGAIN, left > 0 else { return false }
                var ready = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                _ = poll(&ready, 1, Int32(left * 1000) + 1)
            }
            return true
        }
    }
}

/// Everything the agent (MCP) and the command line ask of luoke-search, in one place: search, open, status,
/// settings and their plans, the outbox. Used from one thread at a time (`MCPServer` serializes calls), but for
/// thumbnails, drawn outside it (`findThumb`) from the file or the Photos library only.
public final class SearchService: @unchecked Sendable {
    public let directory: DataDirectory
    public let store: IndexStore
    let searcher: Searcher
    let hub: Hub?
    let opener: Opener
    let home: String
    /// Only folders `Settings.searchable` in plans (the app as it ships, `restrictFolders`); development runs and tests
    /// take any (their folders are in scratch places, a checkout under ~/Library).
    public var restrictFolders = false
    /// Called after the settings change (the resident loop watches the new folders).
    public var onSettingsChanged: (@Sendable () -> Void)?
    /// Whether what macOS lets this process read decides the `needs-access` items (`folderItems`, `photosItem`): only
    /// the resident (`serve`), whose access is the app's. The command line and `mcp` run with the terminal's (often
    /// Full Disk Access, and its own answer for Photos, even the app's program run there, `LuokeSearch.isApp`) and
    /// would let items go or number them again; looking at folders would have macOS ask about the terminal (third
    /// review of PR #44).
    public var judgesAccess = false
    /// Whether macOS lets the searched folders be read, for the outbox (`folderItems`).
    var folderAccess = FolderAccess()
    /// The disks plugged in now that the page may offer (`Volumes.external`; swapped in tests).
    var mountedVolumes: () -> [MountedVolume] = Volumes.external

    /// The Photos library this process may read, if any (`SystemPhotos.current`; a fake in tests).
    public let photos: PhotoSource?
    /// How long a search waits for its question's vector (`meaningTimeout`; shorter in tests).
    var meaningWait = SearchService.meaningTimeout
    /// The window gives each source 10 seconds (§1b, luoke-agent#3), the search itself and the way back included:
    /// half of it for the vector, then words only, saying so. Warm, a question's vector takes about 0.1 s.
    static let meaningTimeout: TimeInterval = 5
    /// Thumbnails being drawn at most at once, and how long one may take (`thumbTimeout`; shorter in tests).
    let thumbSlots = DispatchSemaphore(value: 2)
    var thumbWait = SearchService.thumbTimeout
    /// Whether a file's contents are only in iCloud (as `Crawler.isDataless`; swapped in tests).
    var isDataless: (stat) -> Bool = { $0.st_flags & Crawler.datalessFlag != 0 }
    /// What holds reading on this Mac now (`Power.held`; swapped in tests).
    var machine: (Bool) -> [String] = Power.held(onBattery:)

    public init(directory: DataDirectory, hub: Hub?, opener: Opener = .mac, photos: PhotoSource? = nil,
                home: String = NSHomeDirectory()) throws {
        self.photos = photos
        self.directory = directory
        store = try IndexStore(directory: directory, home: home)
        searcher = Searcher(store: store)
        self.hub = hub
        self.opener = opener
        self.home = home
    }

    // MARK: Search

    public func search(_ text: String, options: SearchOptions) throws -> SearchAnswer {
        let started = Date()
        // No words (only a time): nothing to ask luoke-core for.
        let (meaning, note) = Searcher.isBlank(text) ? (nil, nil) : QueryMeaning.make(text, hub: hub, within: meaningWait)
        return try searchLock.withLock {
            lastSearch = Date()
            return try searcher.search(text, options: visible(options), meaning: meaning, meaningNote: note, started: started)
        }
    }

    /// What else is like the result `id` (`Searcher.similar`); nil when there's no such item any more.
    public func similar(_ id: String, options: SearchOptions) throws -> SearchAnswer? {
        let started = Date()
        return try searchLock.withLock {
            lastSearch = Date()
            return try searcher.similar(to: id, options: visible(options), started: started)
        }
    }

    /// Photos the user took permission back from (or never gave it) aren't found. Refused in System Settings, what was
    /// read still is: the user's own permission stands (`skippedSources`, `not_updated`). Only the resident knows the
    /// app's own access (`judgesAccess`).
    private func visible(_ options: SearchOptions) -> SearchOptions {
        var options = options
        options.hidesPhotos = judgesAccess && photos?.access == .notAsked
        return options
    }

    /// Of these results' items, those `similar` has vectors to go on.
    func withVectors(_ hits: [Hit]) throws -> Set<Int64> {
        let items = hits.compactMap { Int64($0.id.split(separator: "#").first ?? "") }
        return try searchLock.withLock { try searcher.withVectors(items) }
    }

    private let searchLock = NSLock()
    private var lastSearch = Date()
    private var idleTimer: DispatchSourceTimer?

    /// Gives the vectors' memory back after `idle` seconds without a search; the next search reads them again
    /// (review B-18).
    public func releaseVectorsWhenIdle(after idle: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + idle, repeating: min(idle, 60))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            searchLock.withLock {
                if Date().timeIntervalSince(lastSearch) >= idle { searcher.releaseVectors() }
            }
        }
        timer.resume()
        idleTimer = timer
    }

    var vectorsLoaded: Bool { searchLock.withLock { searcher.vectorsLoaded } }

    // MARK: Open

    public struct Target: Sendable {
        public let path: String
        public let kind: ItemKind
        public let location: Location?
    }

    /// What a result's id (`12`, `12#p3`, `12#t25.0`) points at, if the item is still there.
    public func target(_ id: String) throws -> Target? {
        let parts = id.split(separator: "#", maxSplits: 1)
        guard let item = Int64(parts.first ?? "") else { return nil }
        var path: String?, kind = ItemKind.doc
        try store.db.query("SELECT path, kind FROM items WHERE id = ?", [.int(item)]) { row in
            path = row.text(0)
            kind = ItemKind(rawValue: row.text(1) ?? "") ?? .doc
        }
        guard let path else { return nil }
        if let photo = PhotoPath.id(path) {
            // Looked up only with access (a thumbnail of a photo found while it's gone or was never given): the real
            // library would ask the user at the first lookup, and only luoke's own program asks.
            guard photos?.access == .allowed, photos?.asset(photo) != nil else { return nil }
            return Target(path: path, kind: kind, location: nil)
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var location: Location?
        // The place comes from the caller: only a finite, sensible number is one (a page, a second).
        if parts.count == 2, let tag = parts[1].first, let value = Double(parts[1].dropFirst()), value.isFinite,
           value >= 0, value < 10_000_000 {
            switch tag {
            case "p", "s": location = Location(page: Int(value))
            case "c": location = Location(part: Int(value))
            case "w": location = Location(sheet: Int(value))
            case "t": location = Location(time: value)
            default: break
            }
        }
        return Target(path: path, kind: kind, location: location)
    }

    /// Opens a result (or shows it in Finder) and says what was done.
    public func open(_ id: String, reveal: Bool) throws -> String {
        let said = try opening(id, reveal: reveal)
        return opener.isDry ? said + "（演习）" : said
    }

    private func opening(_ id: String, reveal: Bool) throws -> String {
        // A Photos item where the library can't be looked in (a command run in a terminal, or access not given): not
        // gone, only not readable here (luoke-search#46, defect 6). Known before looking in the library at all.
        if photos?.access != .allowed, let item = Int64(id.split(separator: "#").first ?? ""),
           try store.db.scalarInt("SELECT EXISTS(SELECT 1 FROM items WHERE id = ? AND source = 'photos')",
                                  [.int(item)]) == 1 {
            // Only the resident sees the app's own access (a command run in a terminal sees the terminal's).
            switch (judgesAccess ? photos?.access : nil) {
            case .denied?:
                throw ToolFailure("failed", "\(LuokeSearch.holder)没有读照片图库的权限（系统设置 › 隐私与安全性 › 照片）：到「照片」里按拍摄日期找。")
            case .notAsked?:
                throw ToolFailure("failed", "还没允许\(LuokeSearch.holder)读照片图库（在螺壳的「设置 · 权限」里允许）：到「照片」里按拍摄日期找。")
            default:
                throw ToolFailure("failed", "这里读不了照片图库：在螺壳里打开，或到「照片」里按拍摄日期找。")
            }
        }
        guard let target = try target(id) else { throw ToolFailure("stale", "这个文件已经不在原来的地方了。") }
        if let photo = PhotoPath.id(target.path) {
            // Photos can't be opened at one picture from outside (luoke-agent#1: open Photos, say when it was taken).
            if opener.isDry {
                opener.openURL(URL(fileURLWithPath: "/System/Applications/Photos.app"))
            } else {
                photos?.open(photo)
            }
            var taken = ""
            try store.db.query("SELECT coalesce(taken, mtime) FROM items WHERE path = ?", [.text(target.path)]) {
                taken = JSONOutput.date($0.double(0)).prefix(16).replacingOccurrences(of: "T", with: " ")
            }
            return "已打开「照片」。\(target.kind == .video ? "这段视频" : "这张")是 \(taken) 拍的，在图库里按日期能找到。"
        }
        let name = Secrets.mask((target.path as NSString).lastPathComponent)
        if reveal {
            guard opener.reveal(target.path) else { throw ToolFailure("failed", "没能在访达中显示 \(name)。") }
            return "已在访达中显示 \(name)。"
        }
        opener.open(target.path, target.kind, target.location)
        let place = target.location.flatMap(Cards.place)
        switch (target.kind, place) {
        case (.video, let place?), (.audio, let place?): return "已打开 \(name)，从 \(place) 开始。"
        case (_, let place?): return "已打开 \(name)，要找的在\(place)。"
        default: return "已打开 \(name)。"
        }
    }

    // MARK: Status

    public func status() throws -> [String: Any] {
        let counts = try store.counts()
        var hubState = "not_connected", note: String? = "没有连螺壳"
        var background: Hub.Background?, listed: HubTask?
        if let hub {
            do {
                // One `GET /tasks` for both (a slow luoke-core is waited for once: the agent's calls queue behind).
                let answer = try hub.tasks()
                listed = answer.task
                background = answer.background
                guard let task = answer.task else { throw HubError.unknownAccessory }
                hubState = task.status == .available ? "available"
                    : task.status == .downloading || task.status == .needsDownload ? "downloading"
                    : task.status == .paused || task.status == .unavailable ? "busy" : "unsupported"
                note = task.status == .available ? nil : task.reason
            } catch let error as HubError {
                if case .notRunning = error { hubState = "not_running" } else if case .refused = error {
                    hubState = "busy"
                } else { hubState = "unsupported" }
                note = QueryMeaning.note(error).replacingOccurrences(of: "，只按字词搜", with: "")
            }
        }
        let settings = Settings.load(directory)
        let paused = Resident.paused(store, counts: counts, photos: FirstPass.usable(photos, settings) != nil,
                                     task: listed, background: background, onBattery: settings.onBattery,
                                     held: machine)
        var items: [String: Int] = [:]
        for kind in ItemKind.allCases { items[kind.rawValue] = counts.items[kind.rawValue] ?? 0 }
        return [
            "items": items,
            "waiting": ["read": counts.waitingToRead, "rest_of_long_files": counts.waitingForRest,
                        "vectors": counts.waitingForVectors, "media": counts.waitingForMedia,
                        // Read once their files are on this Mac again (contents only in iCloud, a drive unplugged).
                        "not_on_this_mac": counts.notOnThisMac],
            // Why what waits doesn't go on now (on battery, luoke-core paused…): nothing when nothing is held.
            "paused": paused.map { ["reasons": $0.reasons, "by": $0.by, "reading": $0.reading, "vectors": $0.vectors]
                as [String: Any] } ?? NSNull(),
            "first_pass_done": ToolState.load(directory).firstPassDone != nil,
            // Folders whose media look like a dataset (hundreds of machine-named files): not read.
            "dataset_folders": ((try? store.datasetFolders()) ?? [:]).sorted { $0.key < $1.key }
                .map { ["path": $0.key, "files": $0.value] as [String: Any] },
            "vectors_ready": counts.vectors,
            "hub": ["state": hubState, "note": note ?? NSNull()] as [String: Any],
            "folders": settings.searched(restricted: restrictFolders, home: home),
            "photos": settings.photos ? (photos.map { $0.access == .allowed ? "on" : "needs_access" } ?? "on") : "off",
        ]
    }

    public func statusSentence(_ status: [String: Any]) -> String {
        let items = (status["items"] as? [String: Int] ?? [:]).values.reduce(0, +)
        let waiting = status["waiting"] as? [String: Int] ?? [:]
        var parts = ["已索引 \(items) 个"]
        if let read = waiting["read"], read > 0 { parts.append("还有 \(read) 个在等着读") }
        if let rest = waiting["rest_of_long_files"], rest > 0 { parts.append("\(rest) 个长文件还没读完") }
        if let away = waiting["not_on_this_mac"], away > 0 {
            parts.append("\(away) 个不在这台 Mac 上（只在 iCloud、盘拔了这些），回到这台 Mac 上再读")
        }
        if let vectors = waiting["vectors"], vectors > 0 { parts.append("\(vectors) 段在等螺壳算向量") }
        // Not "waiting for luoke-core" (as in `Searcher.partialReason`): some wait for their files.
        if let media = waiting["media"], media > 0 { parts.append("\(media) 个文件的图片和声音还没全有按意思搜的向量") }
        if let note = (status["hub"] as? [String: Any])?["note"] as? String { parts.append(note) }
        var sentence = parts.joined(separator: "，") + "。"
        if let paused = Self.paused(status) { sentence += Self.words(paused) }
        return sentence
    }

    /// How far each way of searching is, for the page (`statusSentence` is for the agent's model and the command
    /// line), and what else there is to say. Progress is as of now: the page shows it when it's read.
    func pageStatus(_ status: [String: Any]) -> (exact: SearchState, semantic: SearchState, note: String?) {
        let read = (status["items"] as? [String: Int] ?? [:]).values.reduce(0, +)
        let waiting = status["waiting"] as? [String: Int] ?? [:]
        let toRead = waiting["read", default: 0], rest = waiting["rest_of_long_files", default: 0]
        let toVector = waiting["vectors", default: 0], media = waiting["media", default: 0]
        let vectors = status["vectors_ready"] as? Int ?? 0

        let exact: SearchState = toRead > 0 ? .progress(read, of: read + toRead)
            : SearchState(rest > 0 ? "\(rest) 个长文件还在读" : read == 0 ? "还没有内容" : "可用")
        let semantic: SearchState
        if let blocked = Self.semanticBlocked[(status["hub"] as? [String: Any])?["state"] as? String ?? ""] {
            semantic = SearchState(blocked)
        } else if toVector > 0 {
            semantic = .progress(vectors, of: vectors + toVector)
        } else if media > 0 {
            semantic = SearchState("\(media) 个文件的图片和声音还在处理")
        } else {
            semantic = SearchState(read == 0 ? "还没有内容" : "可用")
        }

        var notes: [String] = []
        if let paused = Self.paused(status) { notes.append(Self.pauseNote(paused)) }
        if let away = waiting["not_on_this_mac"], away > 0 { notes.append("\(away) 个文件不在这台 Mac 上，回来后接着读。") }
        return (exact, semantic, notes.isEmpty ? nil : notes.joined())
    }

    /// Why there's no searching by meaning, in a word or two, by `status`'s hub state.
    private static let semanticBlocked = ["downloading": "等待下载", "busy": "稍后可用", "not_running": "未连接",
                                          "not_connected": "未连接", "unsupported": "不支持"]

    private static func paused(_ status: [String: Any]) -> Resident.Paused? {
        guard let paused = status["paused"] as? [String: Any], let reasons = paused["reasons"] as? [String] else { return nil }
        return Resident.Paused(reasons: reasons, by: paused["by"] as? String ?? "mac",
                               reading: paused["reading"] as? Bool ?? false, vectors: paused["vectors"] as? Bool ?? false)
    }

    /// What is held and why, as a sentence of its own after what waits and luoke-core's note (so its cause isn't read
    /// as theirs): "因为螺壳的后台已暂停（在用电池），等着的文件先不读（新存的文件照样读，先只能按字词搜），向量先不算。"
    /// The reasons named close to luoke-core's own menu; one this version has no words for isn't named.
    public static func words(_ paused: Resident.Paused) -> String {
        let cause = cause(paused)
        // New files are read all the same; with vectors held too, they're found by their words only for now.
        let reading = paused.reading ? "等着的文件先不读（新存的文件照样读" + (paused.vectors ? "，先只能按字词搜）" : "）") : nil
        let what = [reading, paused.vectors ? "向量先不算" : nil].compactMap { $0 }.joined(separator: "，")
        return (cause.isEmpty ? "" : "因为\(cause)，") + what + "。"
    }

    /// The same for the page: what it means for the user, without the machinery.
    static func pauseNote(_ paused: Resident.Paused) -> String {
        let cause = cause(paused)
        return (cause.isEmpty ? "" : cause + "，") + (paused.reading ? "等着的文件先不读，新存的文件照样读。" : "语义搜索的准备先停一下。")
    }

    private static func cause(_ paused: Resident.Paused) -> String {
        let named = ["battery": "在用电池", "low_power": "开着低电量模式", "thermal": "Mac 太热", "memory": "内存不够"]
        let why = paused.reasons.compactMap { named[$0] }.joined(separator: "、")
        return paused.by == "luoke" ? "螺壳的后台已暂停" + (why.isEmpty ? "" : "（\(why)）") : why
    }

    // MARK: Settings

    public struct Change: Sendable {
        public var addFolders: [String] = []
        public var removeFolders: [String] = []
        public var skipFolders: [String] = []
        public var unskipFolders: [String] = []
        /// Disks by UUID: only ones plugged in now (`mountedVolumes`) may be added.
        public var addVolumes: [String] = []
        public var removeVolumes: [String] = []
        public var photos: Bool?
        public var onBattery: Bool?

        public init() {}
    }

    /// One line of a plan: what would change, with a folder called what the user knows it as ("桌面", "notes"),
    /// and that folder's full path (for the small print).
    public struct PlanLine: Sendable, Equatable {
        public let text: String
        public let path: String?

        init(_ text: String, path: String? = nil) {
            self.text = text
            self.path = path
        }
    }

    /// A plan for `change` against the current settings, kept until it's carried out, and the lines saying what it
    /// would do.
    /// What one change may name (pre-release review, should-fix 11: `search_settings` needs no tap, and each call
    /// with any folders at all, of any length, was kept in `state.json`).
    static let maxFoldersInChange = 50
    static let maxPathBytes = 1024
    /// Plans not carried out (yet) kept at most: the oldest go first.
    static let maxPlans = 20

    public func plan(_ change: Change) throws -> (SettingsPlan, [PlanLine]) {
        guard let settings = Settings.read(directory) else { throw ToolFailure("needs_setup", Settings.unreadable) }
        for names in [change.addFolders, change.removeFolders, change.skipFolders, change.unskipFolders,
                      change.addVolumes, change.removeVolumes] {
            guard names.count <= Self.maxFoldersInChange else {
                throw ToolFailure("invalid", "一次最多改 \(Self.maxFoldersInChange) 个文件夹。")
            }
            if let long = names.first(where: { $0.utf8.count > Self.maxPathBytes }) {
                throw ToolFailure("invalid", "「\(MCPServer.shown(long))」太长了，不像一个文件夹。")
            }
        }
        var plan = SettingsPlan(id: "plan-" + UUID().uuidString.prefix(8).lowercased(),
                                made: Date().timeIntervalSince1970, basis: settings)
        var lines: [PlanLine] = []
        let deadline = Date().addingTimeInterval(2)   // for counting files, all folders together
        for name in change.addFolders {
            let folder = Settings.folder(named: name, home: home)
            guard !settings.folders.contains(folder), !plan.addFolders.contains(folder) else { continue }
            // Judged before it's looked for: whether a place outside these exists isn't told either.
            guard !restrictFolders || Settings.searchable(folder, home: home) else {
                throw ToolFailure("invalid", "螺壳搜索不搜「\(MCPServer.shown(name))」：只搜你的个人文件夹和外接磁盘里不隐藏的文件夹（资源库里只有 iCloud 云盘）。")
            }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
                throw ToolFailure("invalid", "没有「\(MCPServer.shown(name))」这个文件夹。")
            }
            plan.addFolders.append(folder)
            // Listing a folder macOS protects would ask the user before the card is even shown (review C-09).
            if Self.isProtected(folder, home: home) {
                lines.append(PlanLine("搜「\(display(folder))」：第一遍在后台慢慢读（macOS 会先问你让不让读）", path: folder))
            } else {
                let (count, more) = Self.countFiles(folder, until: deadline)
                lines.append(PlanLine("搜「\(display(folder))」：\(more ? "至少 " : "大约 ")\(count) 个文件，第一遍在后台慢慢读",
                                      path: folder))
            }
        }
        let disks = settings.volumes.isEmpty ? [] : Volumes.roots(settings.volumes, mounted: mountedVolumes())
        for name in change.removeFolders {
            // As stored first: one kept unlike the walk spells it (a link, written by an earlier version) still goes.
            let folder = settings.folders.contains(name) ? name : Settings.folder(named: name, home: home)
            // A disk chosen on the page, named by where it is (or was): it goes by its UUID.
            if !settings.folders.contains(folder),
               let disk = settings.volumes.first(where: { volume in
                   ([volume.path] + Volumes.roots([volume], mounted: mountedVolumes())).contains(folder)
               }) {
                if !plan.removeVolumes.contains(disk.uuid) {
                    plan.removeVolumes.append(disk.uuid)
                    lines.append(PlanLine("不再搜外接盘「\(quietName(disk.path))」：它的内容会移出索引", path: disk.path))
                }
                continue
            }
            guard settings.folders.contains(folder), !plan.removeFolders.contains(folder) else { continue }
            plan.removeFolders.append(folder)
            // Not by Finder's name: it may look inside a folder macOS protects, and ask the user (review C-09).
            lines.append(PlanLine("不再搜「\(quietName(folder))」：它的内容会移出索引", path: folder))
        }
        // What's searched once this plan is carried out: the app as it ships skips only what's inside it. Compared
        // as the walk spells them (links followed: "documents" isn't, a typed path is).
        let searched = (settings.folders.filter { !plan.removeFolders.contains($0) } + plan.addFolders + disks)
            .map(Crawler.canonical)
        for name in change.skipFolders {
            let folder = Settings.folder(named: name, home: home)
            guard !settings.skipFolders.contains(folder) else { continue }
            let skipped = Crawler.canonical(folder)
            guard !restrictFolders || searched.contains(where: { skipped.hasPrefix($0 + "/") }) else {
                throw ToolFailure("invalid", "只能跳过要搜的文件夹里面的：「\(MCPServer.shown(name))」不在要搜的文件夹里。")
            }
            plan.skipFolders.append(folder)
            // Not by Finder's name: it may look inside a folder macOS protects (review C-09).
            lines.append(PlanLine("跳过「\(quietName(folder))」", path: folder))
        }
        for name in change.unskipFolders {
            let folder = settings.skipFolders.contains(name) ? name : Settings.folder(named: name, home: home)
            guard settings.skipFolders.contains(folder), !plan.unskipFolders.contains(folder) else { continue }
            plan.unskipFolders.append(folder)
            lines.append(PlanLine("不再跳过「\(quietName(folder))」", path: folder))
        }
        if !change.addVolumes.isEmpty || !change.removeVolumes.isEmpty {
            let mounted = mountedVolumes()
            for uuid in change.addVolumes where !settings.volumes.contains(where: { $0.uuid == uuid })
                && !plan.addVolumes.contains(where: { $0.uuid == uuid }) {
                // Only a disk plugged in now, as the page offered it: a UUID alone says nothing of where it is.
                guard let disk = mounted.first(where: { $0.uuid == uuid }) else {
                    throw ToolFailure("invalid", "这块盘现在没接在这台 Mac 上。")
                }
                plan.addVolumes.append(ChosenVolume(uuid: uuid, path: disk.path))
                lines.append(PlanLine("也搜外接盘「\(Secrets.mask(disk.name))」：第一遍在后台慢慢读（macOS 会先问你让不让读）",
                                      path: disk.path))
            }
            for uuid in change.removeVolumes {
                guard let disk = settings.volumes.first(where: { $0.uuid == uuid }), !plan.removeVolumes.contains(uuid)
                else { continue }
                plan.removeVolumes.append(uuid)
                lines.append(PlanLine("不再搜外接盘「\(quietName(disk.path))」：它的内容会移出索引", path: disk.path))
            }
        }
        if let photos = change.photos, photos != settings.photos {
            plan.photos = photos
            lines.append(PlanLine(photos ? "也搜「照片」里的照片和视频（要你允许读照片）" : "不再搜「照片」"))
        }
        if let onBattery = change.onBattery, onBattery != settings.onBattery {
            plan.onBattery = onBattery
            lines.append(Self.batteryLine(onBattery))
        }
        if !plan.isEmpty {
            try ToolState.update(directory) { state in
                state.plans.removeAll { Date().timeIntervalSince1970 - $0.made > 7 * 86_400 }
                state.plans.append(plan)
                // The setup card's plan (with choices) is one of its own; of the rest, the newest `maxPlans`.
                let offered = state.plans.filter { $0.choices == nil }
                if offered.count > Self.maxPlans {
                    let gone = Set(offered.prefix(offered.count - Self.maxPlans).map(\.id))
                    state.plans.removeAll { gone.contains($0.id) }
                }
            }
        }
        return (plan, lines)
    }

    /// What a plan does, said again (when its card is drawn again).
    func describe(_ plan: SettingsPlan) -> [PlanLine] {
        plan.addFolders.map { PlanLine("搜「\(display($0))」", path: $0) }
            + plan.removeFolders.map { PlanLine("不再搜「\(quietName($0))」", path: $0) }
            + plan.skipFolders.map { PlanLine("跳过「\(quietName($0))」", path: $0) }
            + plan.unskipFolders.map { PlanLine("不再跳过「\(quietName($0))」", path: $0) }
            + plan.addVolumes.map { PlanLine("也搜外接盘「\(quietName($0.path))」", path: $0.path) }
            + plan.removeVolumes.map { uuid in PlanLine("不再搜一块外接盘", path: plan.basis.volumes.first { $0.uuid == uuid }?.path) }
            + (plan.photos.map { [PlanLine($0 ? "也搜「照片」里的照片和视频" : "不再搜「照片」")] } ?? [])
            + (plan.onBattery.map { [Self.batteryLine($0)] } ?? [])
    }

    static func batteryLine(_ onBattery: Bool) -> PlanLine {
        PlanLine(onBattery ? "用电池时也建索引（连着螺壳时，听螺壳的电池设置）" : "用电池时不建索引（新文件照样马上读；连着螺壳时，听螺壳的电池设置）")
    }

    /// Carries out a plan this tool made. `surfaceID`: the card tapped, which shows the result.
    /// `surfaceID`: the card tapped. It must be this plan's own (review C-16: a tap on another card is no say-so for
    /// it). Nil: the user typed it (the command line). `ticks`: what the user ticked on the card, for a plan that has
    /// choices (`needs-setup`).
    public func apply(planID: String, surfaceID: String?, ticks: [String: Bool] = [:]) throws -> String {
        if let surfaceID, surfaceID != "s-" + planID {
            throw ToolFailure("needs_user_action", "这个操作要你在这个方案的卡片上点过才能执行。")
        }
        // Whether macOS lets it read the new folders, asked before the data directory is locked: the first time,
        // macOS asks the user and the call waits for the answer, and the resident loop and a job would wait with it
        // (review of the setup card). Only for a plan that would be carried out: a stale one says so instead.
        let before = ToolState.load(directory)
        // The places macOS protects inside a folder added (the desktop, documents and downloads in the home folder):
        // looked at now, so macOS asks on this tap, not later in the background when the resident walks there. Not
        // a reason to refuse: one not allowed gets its needs-access card, the rest is searched.
        if let offered = before.plans.first(where: { $0.id == planID }), usable(offered, before),
           let plan = offered.ticked(ticks), let settings = Settings.read(directory) {
            for place in Self.accessTargets(plan.addFolders, skipped: settings.skipFolders, home: home)
            where !plan.addFolders.contains(place) && FileManager.default.fileExists(atPath: place) {
                _ = Self.readable(place)
            }
        }
        if let offered = before.plans.first(where: { $0.id == planID }), usable(offered, before),
           let plan = offered.ticked(ticks), let settings = Settings.read(directory),
           plan.fits(settings, saved: Settings.saved(directory)),
           !restrictFolders || plan.addFolders.allSatisfy({ Settings.searchable($0, home: home) }),
           let unreadable = (plan.addFolders + plan.addVolumes.map(\.path)).first(where: { !Self.readable($0) }) {
            // The plan stays, drawn again with what to do first and the way there (review C-13); its ticks as
            // the user left them.
            let note = "macOS 现在不让\(LuokeSearch.holder)读「\(placeName(unreadable))」：在系统设置里允许以后，再点「好」。"
            let card = surfaceID.map {
                offered.choices == nil
                    ? Cards.plan(plan, lines: describe(plan), surfaceID: $0, update: true, note: note, settingsPane: "files")
                    : Cards.setup(planID: offered.id, choices: setupChoices(offered),
                                  protected: isProtected(offered), surfaceID: $0, update: true, note: note,
                                  settingsPane: "files")
            }
            throw ToolFailure("needs_setup", "macOS 现在不让\(LuokeSearch.holder)读「\(placeName(unreadable))」，先在系统设置里允许它。",
                              card: card)
        }
        // Read, checked and written under the data directory's lock: the resident loop, a job or the command line
        // may be writing the same files (review C-17).
        let (plan, applied): (SettingsPlan, Settings) = try Stored.locked(directory) {
            var state = ToolState.load(directory)
            guard let offered = state.plans.first(where: { $0.id == planID }) else {
                throw ToolFailure("stale", "这个方案已经过期了，再说一遍要改什么吧。")
            }
            guard usable(offered, state) else { throw ToolFailure("stale", "要搜的地方已经选过了，这张卡片不再适用。") }
            guard let plan = offered.ticked(ticks) else { throw ToolFailure("invalid", "这个方案里没有这一项。") }
            guard !plan.isEmpty else { throw ToolFailure("invalid", "一个都没勾：勾上要搜的地方，再点「好」。") }
            guard let settings = Settings.read(directory) else { throw ToolFailure("needs_setup", Settings.unreadable) }
            guard plan.fits(settings, saved: Settings.saved(directory)) else {
                throw ToolFailure("stale", "设置在这之后又改过了，这个方案不再适用。")
            }
            // A plan made by an earlier version, before folders were judged.
            guard !restrictFolders || plan.addFolders.allSatisfy({ Settings.searchable($0, home: home) }) else {
                throw ToolFailure("stale", "这个方案里有螺壳搜索不搜的文件夹，再说一遍要改什么吧。")
            }
            let applied = plan.applied(to: settings)
            try applied.save(directory)
            state.plans.removeAll { $0.id == planID }
            if chosen(applied) { state.chose() }
            // Photos turned off: nothing to ask, so turned on again (before the outbox was looked at) is a new item.
            // Only that: whether access is allowed is judged by the resident (`judgesAccess`).
            if !applied.photos { state.photosNeeded = false }
            // Folders no longer searched let go, so chosen again (before the outbox was looked at) is a new item. Only
            // that: whether macOS lets a folder be read is judged by the resident (`judgesAccess`).
            let searched = Set(Self.accessTargets(applied.searched(restricted: restrictFolders, home: home,
                                                                   mounted: mountedVolumes()),
                                                  skipped: applied.skipFolders, home: home))
            state.folderItems = state.folderItems.filter { searched.contains($0.key) }
            try state.save(directory)
            return (plan, applied)
        }
        defer { onSettingsChanged?() }
        if !plan.removeFolders.isEmpty || !plan.removeVolumes.isEmpty {
            try Indexer(store: store).prune(keeping: applied.keptRoots(restricted: restrictFolders, home: home, mounted: mountedVolumes()))
        }
        return "好了，设置改好了。" + (plan.addFolders.isEmpty && plan.addVolumes.isEmpty ? "" : "新加的地方会在后台慢慢建索引。")
    }

    /// A folder as the user knows it: Finder's name for it ("桌面", "文稿" for the usual places), else its last part;
    /// credentials in it masked, as a file's title is (pre-release review: "身份证 110101199003070017 资料" went out
    /// whole in plans, cards and the outbox).
    func display(_ folder: String) -> String {
        special(folder) ?? Secrets.mask(FileManager.default.displayName(atPath: folder))
    }

    /// The home folder and iCloud Drive by what the user calls them: Finder would give the home folder the user's
    /// short name.
    func special(_ folder: String) -> String? {
        switch inHome(folder) {
        case "": "个人文件夹"
        // iCloud Drive's own folder too: luoke's activation may choose only that one.
        case Settings.iCloudDrive, Settings.iCloudDrive + "/com~apple~CloudDocs": "iCloud 云盘"
        default: nil
        }
    }

    /// Where `folder` is in the home folder ("" for the home folder itself), the home folder spelled either way (as
    /// given, or as the walk spells it); nil outside it.
    func inHome(_ folder: String) -> String? {
        for base in [home, Crawler.canonical(home)] {
            if folder == base { return "" }
            if folder.hasPrefix(base + "/") { return String(folder.dropFirst(base.count + 1)) }
        }
        return nil
    }

    static func readable(_ folder: String) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: folder)) != nil
    }

    /// Files luoke-search would read under `folder`, counted until `deadline`: the clock is looked at every 200
    /// entries walked, files or not (a big tree with nothing to read stops in time too).
    static func countFiles(_ folder: String, until deadline: Date) -> (Int, more: Bool) {
        guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return (0, false)
        }
        var count = 0, walked = 0
        for case let url as URL in walk {
            walked += 1
            if Rules.kind(of: url) != nil { count += 1 }
            if walked % 200 == 0, Date() > deadline { return (count, true) }
        }
        return (count, false)
    }

    /// Folders macOS asks the user about before an app may list them: Desktop, Documents, Downloads, iCloud Drive and
    /// cloud storage, other volumes; and a folder with one of them inside (the home folder: counting its files would
    /// ask too).
    static func isProtected(_ folder: String, home: String) -> Bool {
        let places = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
            .map { home + "/" + $0 } + ["/Volumes"]
        return places.contains { folder == $0 || folder.hasPrefix($0 + "/") || $0.hasPrefix(folder + "/") }
    }

    // MARK: Setup

    static let setupID = "needs-setup"
    /// The Photos needs-access card's surface: its item's number in it. The agent keys cards by surface: a new item
    /// would take over the card of one withdrawn in the same look, or of one done a while ago, and go with it (third
    /// review of PR #42).
    static func photosSurface(_ number: Int) -> String { "access-photos-" + String(number) }

    /// Something is searched (folders the walk takes, or the Photos library): chosen, as far as `needs-setup` goes.
    func chosen(_ settings: Settings) -> Bool {
        settings.photos || !settings.searched(restricted: restrictFolders, home: home).isEmpty
    }

    /// Whether a plan may still be carried out: a `needs-setup` one only while nothing was ever chosen and the report
    /// wasn't put down (a card from before, still in the conversation, doesn't bring the usual places back).
    func usable(_ plan: SettingsPlan, _ state: ToolState) -> Bool {
        plan.choices == nil || state.foldersChosen == nil && !state.closed.contains(Self.setupID)
    }

    /// The usual places by the names Finder gives them: asking Finder (`displayName`) may look inside them, and
    /// macOS would ask the user before the card is even shown. Any other folder by `display`.
    static let placeNames = ["Desktop": "桌面", "Documents": "文稿", "Downloads": "下载", "Pictures": "图片", "Movies": "影片",
                             "Music": "音乐", "Public": "公共"]

    func placeName(_ folder: String) -> String {
        inHome(folder).flatMap { Self.placeNames[$0] } ?? display(folder)
    }

    /// What's offered when nothing's chosen yet (`needs-setup`): the home folder and iCloud Drive (11-10: the whole
    /// home folder by default), those that are there. Only by the app as it ships (`restrictFolders`): a development
    /// run's home is the developer's own, with real files in it.
    func suggestedFolders() -> [String] {
        guard restrictFolders else { return [] }
        return Settings.homeScope(home: home).filter { folder in
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) && isFolder.boolValue
                && Settings.searchable(folder, home: home)
        }
    }

    /// The plan the `needs-setup` report offers, if it's due: no folder chosen and the Photos library off, never
    /// chosen before (`ToolState.foldersChosen`), the report not put down, something to suggest. Kept while the
    /// settings and the suggestions stay as they are, else made anew (the old one dropped): every folder ticked, the
    /// Photos library not.
    func setupPlan() -> SettingsPlan? {
        guard let settings = Settings.read(directory), !chosen(settings) else { return nil }
        let state = ToolState.load(directory)
        guard state.foldersChosen == nil, !state.closed.contains(Self.setupID) else { return nil }
        let folders = suggestedFolders()
        guard !folders.isEmpty else { return nil }
        let saved = Settings.saved(directory)
        if let kept = state.plans.first(where: { $0.choices != nil && $0.fits(settings, saved: saved) && $0.addFolders == folders }) {
            return kept
        }
        var plan = SettingsPlan(id: "plan-" + UUID().uuidString.prefix(8).lowercased(),
                                made: Date().timeIntervalSince1970, basis: settings)
        plan.addFolders = folders
        plan.choices = Dictionary(uniqueKeysWithValues: folders.indices.map { (SettingsPlan.folderChoice($0), true) })
        plan.choices?["photos"] = false
        var kept = false
        do {
            try ToolState.update(directory) { state in
                // Looked at again under the lock: chosen or put down meanwhile, no plan is left behind.
                guard state.foldersChosen == nil, !state.closed.contains(Self.setupID) else { return }
                state.plans.removeAll { $0.choices != nil }
                state.plans.append(plan)
                kept = true
            }
        } catch {
            return nil   // a plan that isn't kept couldn't be carried out
        }
        return kept ? plan : nil
    }

    /// The ticks on a `needs-setup` plan's card: its folders by the names the user knows, then the Photos library.
    func setupChoices(_ plan: SettingsPlan) -> [Cards.Choice] {
        plan.addFolders.indices.map {
            let key = SettingsPlan.folderChoice($0)
            return Cards.Choice(key: key, label: placeName(plan.addFolders[$0]), on: plan.choices?[key] ?? true)
        } + (plan.choices?["photos"].map { [Cards.Choice(key: "photos", label: "照片图库里的照片和视频（要你允许读照片）", on: $0)] }
             ?? [])
    }

    func isProtected(_ plan: SettingsPlan) -> Bool {
        plan.addFolders.contains { Self.isProtected($0, home: home) }
    }

    // MARK: Outbox

    /// What luoke-search wants the user told now (agent tool protocol §3): only that nothing's chosen to search yet,
    /// that macOS doesn't let it read a folder, and that the first pass is done. Never search results.
    public func outbox() -> [String: Any] {
        let settings = Settings.load(directory)
        let state = ToolState.load(directory)
        var items: [[String: Any]] = []
        let now = JSONOutput.date(Date().timeIntervalSince1970)
        // Chosen some other way (the command line of an earlier version, by hand): noted too.
        if chosen(settings), state.foldersChosen == nil {
            try? ToolState.update(directory) { $0.chose() }
        }
        if let plan = setupPlan() {
            let names = plan.addFolders.map { "「\(placeName($0))」" }.joined(separator: "和")
            items.append([
                "id": Self.setupID, "kind": "needs-setup", "urgency": "normal", "deadline": NSNull(), "expires": NSNull(),
                "created": JSONOutput.date(plan.made), "why_now": "还没选的话，螺壳搜索什么都搜不到",
                "title": "螺壳搜索还没选要搜的地方",
                "summary": "默认搜\(names)，点「好」就在后台开始建索引，都留在这台 Mac 上；照片图库、外接盘默认不搜。",
                "card": Cards.setup(planID: plan.id, choices: setupChoices(plan), protected: isProtected(plan),
                                    surfaceID: "s-" + plan.id),
            ])
        }
        for (folder, number) in folderItems(settings) where !state.closed.contains(Self.folderID(folder, number)) {
            // Not by Finder's name: the folder can't be read, and asking may have macOS ask the user.
            let name = placeName(folder)
            // Not one of the manifest's permissions (a folder is chosen in the settings), so no `permission`; `low` as
            // every needs-access (§1a).
            items.append([
                "id": Self.folderID(folder, number), "kind": "needs-access", "urgency": "low", "deadline": NSNull(),
                "expires": NSNull(), "created": now, "why_now": "不允许的话，「\(name)」里的东西搜不到",
                "title": "螺壳搜索读不了「\(name)」",
                "summary": "要在 系统设置 › 隐私与安全性 › 文件和文件夹 里允许\(LuokeSearch.holder)读取「\(name)」。",
                "card": Cards.needsAccess(name, pane: "files", surfaceID: Self.folderSurface(folder, number)),
            ])
        }
        // Photos on, not allowed. Never asked: nothing here asks; the permission is luoke's, and its own program asks
        // in its window (§1a "用到才要"). Refused: only System Settings can change it. Asked, then refused: the same
        // item, its card changed (the agent draws it again).
        if let number = photosItem(settings), let photos, !state.closed.contains(Self.photosID(number)) {
            let refused = photos.access == .denied
            let surface = Self.photosSurface(number)
            items.append([
                "id": Self.photosID(number), "kind": "needs-access", "permission": "photos", "urgency": "low",
                "deadline": NSNull(), "expires": NSNull(), "created": now, "why_now": "不允许的话，照片图库里的照片和视频搜不到",
                "title": refused ? "螺壳搜索读不了「照片」" : "螺壳搜索要你允许读「照片」",
                "summary": refused ? "要在 系统设置 › 隐私与安全性 › 照片 里允许\(LuokeSearch.holder)读取照片图库。"
                    : "你让螺壳搜索也搜照片图库。要在螺壳的「设置 · 权限」里允许读照片。",
                "card": refused ? Cards.needsAccess("照片", pane: "photos", surfaceID: surface, dismiss: true)
                    : Cards.askForPhotos(surfaceID: surface),
            ])
        }
        if let done = state.firstPassDone, Date().timeIntervalSince1970 - done < 3 * 86_400 {
            let id = "index-ready/\(Int(done))"
            if !state.closed.contains(id), let counts = try? store.counts() {
                let total = counts.items.values.reduce(0, +)
                var summary = "已索引 \(total) 个文件，可以在螺壳里让我帮你找了。"
                if counts.waitingForMedia > 0 {
                    summary += "其中 \(counts.waitingForMedia) 个文件的图片和声音还没全有按意思搜的向量，这些暂时只能按名字和里面的字找到。"
                }
                // Set aside while not on this Mac: the first pass is done without them (as the status says).
                if counts.notOnThisMac > 0 {
                    summary += "另有 \(counts.notOnThisMac) 个文件不在这台 Mac 上（只在 iCloud、盘拔了这些），回到这台 Mac 上再读。"
                }
                items.append([
                    "id": id, "kind": "index-ready", "urgency": "low", "deadline": NSNull(),
                    "expires": JSONOutput.date(done + 3 * 86_400), "created": JSONOutput.date(done),
                    "why_now": "第一遍建完了", "title": "螺壳搜索的第一遍索引建好了", "summary": summary,
                    "card": Cards.note("螺壳搜索的第一遍索引建好了", summary, surfaceID: "ready-\(Int(done))"),
                ])
            }
        }
        return ["items": items]
    }

    /// The same short id for the same text in every run (Swift's hashValue changes from run to run).
    static func stableID(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash % 0xFFFF_FFFF, radix: 16)
    }

    /// Only an id the outbox could hold now is kept (pre-release review, should-fix 11: any text at all was kept for
    /// good, word for word, from a tool that needs no tap); ids of what it can no longer hold are let go.
    public func acknowledge(_ id: String, state answer: String) throws {
        let settings = Settings.load(directory)
        let possible = outboxIDs(settings, ToolState.load(directory))
        guard possible.contains(id) else { throw ToolFailure("invalid", "outbox 里没有这一件。") }
        guard answer == "answered" || answer == "dismissed" else { return }   // "shown": nothing to keep
        try ToolState.update(directory) { state in
            // What the outbox couldn't hold now is let go (a folder no longer searched, chosen again later, is asked
            // about again); not while the settings can't be read: that isn't "no folders" (`Settings.read`).
            if let settings = Settings.read(directory) {
                let possible = outboxIDs(settings, state)
                state.closed.removeAll { !possible.contains($0) }
            }
            if !state.closed.contains(id) { state.closed.append(id) }
            if id == Self.setupID { state.plans.removeAll { $0.choices != nil } }   // put down: its plan goes too
        }
    }

    /// The ids the outbox could hold with these settings, whether or not it does now (photos allowed since). Photos and
    /// each folder: only the latest item.
    func outboxIDs(_ settings: Settings, _ state: ToolState) -> Set<String> {
        var ids: Set<String> = [Self.setupID]
        if state.photosItem > 0 { ids.insert(Self.photosID(state.photosItem)) }
        for folder in accessTargets(settings) {
            if let number = state.folderItems[folder] { ids.insert(Self.folderID(folder, number)) }
        }
        if let done = state.firstPassDone { ids.insert("index-ready/\(Int(done))") }
        return ids
    }

    static func photosID(_ number: Int) -> String { "needs-access/photos/\(number)" }

    /// The places whose access the outbox reports: each searched folder, and the folders macOS protects inside one
    /// (the desktop, documents and downloads in a searched home folder, 11-10) that aren't skipped. The walk passes a
    /// folder it can't list over quietly, keeping what was read of it; this is how the user hears of it.
    func accessTargets(_ settings: Settings) -> [String] {
        Self.accessTargets(settings.searched(restricted: restrictFolders, home: home, mounted: mountedVolumes()),
                           skipped: settings.skipFolders, home: home)
    }

    static func accessTargets(_ searched: [String], skipped: [String], home: String) -> [String] {
        // As the walk spells them: a home folder written either way is the one the walk goes through.
        let walked = searched.map(Crawler.canonical), skips = skipped.map(Crawler.canonical)
        let inside = ["Desktop", "Documents", "Downloads"].map { Crawler.canonical(home) + "/" + $0 }.filter { place in
            !walked.contains(place) && walked.contains { place.hasPrefix($0 + "/") }
                && !skips.contains { place == $0 || place.hasPrefix($0 + "/") }
        }
        return searched + inside
    }

    static func folderID(_ folder: String, _ number: Int) -> String { "needs-access/" + folder + "/\(number)" }

    /// A folder's needs-access card's surface: its item's number in it, as the Photos card's (`photosSurface`).
    static func folderSurface(_ folder: String, _ number: Int) -> String { "access-\(stableID(folder))-\(number)" }

    /// Each searched folder macOS won't let it read, with its `needs-access` item's number now. As for Photos, each
    /// time a folder needs the user again (it could be read, wasn't searched, or wasn't there) its item gets a new
    /// number, noted in the state: a card withdrawn once the folder could be read, or taken out of the settings, is
    /// shown again when access is taken back or the folder is chosen again (the agent never shows an id again once
    /// it's gone). Judged only by the resident (`judgesAccess`); any other process reports what the resident noted
    /// last and looks into no folder. The number is the time, as the Photos item's.
    func folderItems(_ settings: Settings) -> [(folder: String, number: Int)] {
        let searched = accessTargets(settings)
        guard judgesAccess else {
            let state = ToolState.load(directory)
            return searched.compactMap { folder in state.folderItems[folder].map { (folder, $0) } }
        }
        let there = searched.filter { FileManager.default.fileExists(atPath: $0) }
        let answers = folderAccess.answers(there)
        var state = ToolState.load(directory)
        // macOS hasn't answered yet (its prompt is waiting for the user): as things were.
        let unreadable = there.filter { !(answers[$0] ?? (state.folderItems[$0] == nil)) }
        let needed = Set(unreadable)
        if Set(state.folderItems.keys) != needed {
            try? ToolState.update(directory) { stored in
                stored.folderItems = stored.folderItems.filter { needed.contains($0.key) }
                for folder in unreadable where stored.folderItems[folder] == nil {
                    stored.folderItem = max(stored.folderItem + 1, Int(Date().timeIntervalSince1970))
                    stored.folderItems[folder] = stored.folderItem
                }
                state = stored
            }
        }
        return unreadable.compactMap { folder in state.folderItems[folder].map { (folder, $0) } }
    }

    /// The Photos `needs-access` item's number now, or nil while there's nothing to ask (off, allowed). Each time it's
    /// needed again it gets a new number, noted in the state: a card put down, or withdrawn when photos were turned off
    /// or allowed, is shown again when they're turned on again or access is taken back. Noticed when the outbox is
    /// looked at (and turned off, when a plan is carried out). Judged only by the resident (`judgesAccess`): the
    /// command line and development runs have no library and would take "nothing to ask" for an answer (third review
    /// of PR #42); the app's program run in a terminal has the terminal's answer. Any other process with the library
    /// reports what the resident noted last. The number is the time (as `index-ready`'s), so a state file lost or
    /// deleted doesn't bring back one the agent already holds as done.
    func photosItem(_ settings: Settings) -> Int? {
        guard let photos else { return nil }
        var state = ToolState.load(directory)
        guard judgesAccess else {
            return settings.photos && state.photosNeeded && state.photosItem > 0 ? state.photosItem : nil
        }
        let needed = settings.photos && photos.access != .allowed
        if state.photosNeeded != needed {
            try? ToolState.update(directory) { stored in
                if needed, !stored.photosNeeded {
                    stored.photosItem = max(stored.photosItem + 1, Int(Date().timeIntervalSince1970))
                }
                stored.photosNeeded = needed
                state = stored
            }
        }
        return needed && state.photosItem > 0 ? state.photosItem : nil
    }

    /// Notes that the folders have been read through once (for the `index-ready` report), the first time only.
    public func noteFirstPassIfDone() throws {
        try ToolState.noteFirstPassIfDone(directory, store: store, restricted: restrictFolders, home: home)
    }
}
