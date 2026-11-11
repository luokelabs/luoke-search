import Foundation

/// What the user chose: where to search and what to skip. Kept in `<data>/settings.json`; changed from the command
/// line (the user typing it) or, through the agent, only by a plan the user tapped (`search_settings_apply`).
public struct Settings: Codable, Sendable, Equatable {
    public var folders: [String] = []
    public var skipFolders: [String] = []
    /// Disks the user chose to search (「也搜这块盘」), by UUID: searched where they're mounted (`Volumes.roots`).
    public var volumes: [ChosenVolume] = []
    public var photos = false
    /// Build the index on battery power too (new files are always read), where luoke-core isn't there to say: off
    /// unless the user turns it on. While luoke-core answers, its own rule decides instead (it pauses background work
    /// on battery unless the user lets it run there; `Resident.backlogHeld`), and luoke-search never sends
    /// `allow_battery`, which is for batch work the user started by hand (luoke-search#46, defect 2; 11-01).
    public var onBattery = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case folders
        case skipFolders = "skip_folders"
        case volumes
        case photos
        case onBattery = "on_battery"
    }

    /// Each key read on its own, missing ones at their defaults: a key added in a later version, or left out when the
    /// file was written by hand, doesn't make the whole file unreadable (review A-05).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folders = try container.decodeIfPresent([String].self, forKey: .folders) ?? []
        skipFolders = try container.decodeIfPresent([String].self, forKey: .skipFolders) ?? []
        volumes = try container.decodeIfPresent([ChosenVolume].self, forKey: .volumes) ?? []
        photos = try container.decodeIfPresent(Bool.self, forKey: .photos) ?? false
        onBattery = try container.decodeIfPresent(Bool.self, forKey: .onBattery) ?? false
    }

    /// The settings: the defaults when there's no file yet, nil when there's one that can't be read. Whatever acts on
    /// them (syncing, pruning, taking photos out) does nothing on nil, never taking it for "nothing chosen".
    public static func read(_ directory: DataDirectory) -> Settings? {
        guard FileManager.default.fileExists(atPath: directory.settingsFile.path) else { return Settings() }
        guard let data = try? Data(contentsOf: directory.settingsFile) else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }

    /// Whether the settings were ever saved (else they are the defaults).
    public static func saved(_ directory: DataDirectory) -> Bool {
        FileManager.default.fileExists(atPath: directory.settingsFile.path)
    }

    /// Said when the file can't be read (a newer version's, or edited by hand).
    public static let unreadable = "螺壳搜索的设置文件（settings.json）读不了：先修好它，在那之前不按设置建索引、不改设置。"

    /// For showing them: the defaults stand in for a file that can't be read.
    public static func load(_ directory: DataDirectory) -> Settings {
        read(directory) ?? Settings()
    }

    public func save(_ directory: DataDirectory) throws {
        try directory.prepare()
        try Stored.write(self, to: directory.settingsFile)
    }

    /// The folders to walk: the chosen ones, only those `searchable` when `restricted` (the app as it ships). Judged
    /// again at every walk: `settings.json` can be written by any process of this user, and a folder allowed when it
    /// was chosen may be a link to another since (pre-release review, should-fix 9, and its review).
    /// The chosen disks are searched where they're mounted now (`mounted`, asked only when there are any).
    public func searched(restricted: Bool, home: String = NSHomeDirectory(),
                         mounted: @autoclosure () -> [MountedVolume] = Volumes.external()) -> [String] {
        let disks = volumes.isEmpty ? [] : Volumes.roots(volumes, mounted: mounted()).filter { !folders.contains($0) }
        let all = folders + disks
        return restricted ? all.filter { Settings.searchable($0, home: home) } : all
    }

    /// What a prune keeps: every folder chosen, and each chosen disk where it was and where it's mounted now (one
    /// unplugged, or out of the way of another disk mounted at its place, keeps what was read of it).
    /// `restricted`: only folders `searchable` (the app as it ships), as for `searched`: one that isn't any more (a
    /// link to elsewhere since) has its items removed.
    public func keptRoots(restricted: Bool = false, home: String = NSHomeDirectory(),
                          mounted: @autoclosure () -> [MountedVolume] = Volumes.external()) -> [String] {
        let chosen = restricted ? folders.filter { Settings.searchable($0, home: home) } : folders
        guard !volumes.isEmpty else { return chosen }
        let now = Volumes.roots(volumes, mounted: mounted())
        return chosen + volumes.map(\.path) + now.filter { !volumes.map(\.path).contains($0) }
    }

    /// Each chosen disk mounted at another path now ("备份 1" while another "备份" was there) is kept at that path
    /// from now on: what was read at the old one is pruned, not left to be opened on whatever disk mounts there
    /// next. Written under the data directory's lock; whether anything changed.
    @discardableResult
    public static func followDisks(_ directory: DataDirectory, mounted: [MountedVolume]) throws -> Bool {
        try Stored.locked(directory) {
            guard var settings = Settings.read(directory), !settings.volumes.isEmpty else { return false }
            var moved = false
            for index in settings.volumes.indices {
                if let here = mounted.first(where: { $0.uuid == settings.volumes[index].uuid }),
                   here.path != settings.volumes[index].path {
                    settings.volumes[index].path = here.path
                    moved = true
                }
            }
            if moved { try settings.save(directory) }
            return moved
        }
    }

    /// What the app searches unless the user takes it out (11-10): the whole home folder (the walk leaves out what
    /// isn't the user's: hidden folders, ~/Library, Music, tools' folders) and iCloud Drive (the only part of
    /// ~/Library searched; other cloud storage isn't).
    public static func homeScope(home: String = NSHomeDirectory()) -> [String] {
        let home = Crawler.canonical(home)
        return [home, home + "/" + iCloudDrive]
    }

    /// iCloud Drive, under the home folder: what Finder shows as 「iCloud 云盘」 (its own folder and the apps').
    public static let iCloudDrive = "Library/Mobile Documents"

    /// Where a folder may be searched (pre-release review, should-fix 9): the home folder and what's inside it, and
    /// what's on another volume (`/Volumes/<name>/…`); none of it hidden (a part starting with "."), and inside
    /// `~/Library` only iCloud Drive (`Library/Mobile Documents`). Not "/", system folders, other users' homes,
    /// `/Volumes` itself, nor Time Machine's backups and snapshots. Links are followed first (a link in the home folder to /etc is /etc), and ".." taken away.
    public static func searchable(_ folder: String, home: String) -> Bool {
        // realpath(3) of the deepest part that's there, the rest as given: Foundation's resolvingSymlinksInPath
        // drops "/private" only when what's left exists, so a folder not made yet came out unlike its home.
        func real(_ path: String) -> String {
            var there = URL(fileURLWithPath: path).standardizedFileURL.path, rest: [String] = []
            while true {
                if let resolved = realpath(there, nil) {
                    defer { free(resolved) }
                    return rest.reversed().reduce(String(cString: resolved)) { ($0 as NSString).appendingPathComponent($1) }
                }
                guard there != "/" else { return path }
                rest.append((there as NSString).lastPathComponent)
                there = (there as NSString).deletingLastPathComponent
            }
        }
        let path = real(folder), home = real(home)
        let rest: Substring
        if path == home {
            rest = ""
        } else if path.hasPrefix(home + "/") {
            rest = path.dropFirst(home.count + 1)
            let parts = rest.split(separator: "/")
            if parts.first == "Library", parts.dropFirst().first != "Mobile Documents" { return false }
        } else if path.hasPrefix("/Volumes/"), !path.hasPrefix("/Volumes/com.apple.TimeMachine.") {
            rest = path.dropFirst("/Volumes/".count)
            if rest.split(separator: "/").contains("Backups.backupdb") { return false }   // Time Machine's
        } else {
            return false
        }
        return !rest.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// A folder as the user names it: a path (`~` allowed), or one of the usual places by name.
    public static func folder(named name: String, home: String = NSHomeDirectory()) -> String {
        let places = ["desktop": "Desktop", "documents": "Documents", "downloads": "Downloads", "pictures": "Pictures",
                      "movies": "Movies", "music": "Music", "桌面": "Desktop", "文稿": "Documents", "文档": "Documents",
                      "下载": "Downloads", "图片": "Pictures", "影片": "Movies", "音乐": "Music"]
        if let place = places[name.lowercased()] { return home + "/" + place }
        // The two the app searches by default, spelled as the walk spells them (as "~" is).
        if ["home", "个人文件夹", "主文件夹"].contains(name.lowercased()) { return Crawler.canonical(home) }
        if ["icloud", "icloud drive", "icloud 云盘", "icloud云盘"].contains(name.lowercased()) { return homeScope(home: home)[1] }
        // "~" is the home given (a test's own), as it is for the real one; "~someone" as macOS says.
        let expanded = name == "~" || name.hasPrefix("~/") ? home + name.dropFirst() : (name as NSString).expandingTildeInPath
        // Spelled as stored ("Documents/工作/" is "…/Documents/工作"), so it compares equal (review C-21).
        return Crawler.canonical(expanded.hasPrefix("/") ? expanded : home + "/" + expanded)
    }
}

/// A change to the settings, proposed by `search_settings` and carried out by `search_settings_apply` only when
/// the user tapped it (agent tool protocol §5: a tool only carries out plans it made itself). Plans are kept in
/// `<data>/state.json` (`ToolState.plans`) so a tap hours later, after a restart, still works.
public struct SettingsPlan: Codable, Sendable, Equatable {
    public var id: String
    public var made: Double
    /// The settings it was made against: if they changed since, the plan is stale.
    public var basis: Settings
    public var addFolders: [String] = []
    public var removeFolders: [String] = []
    public var skipFolders: [String] = []
    /// Skipped folders searched again.
    public var unskipFolders: [String] = []
    public var addVolumes: [ChosenVolume] = []
    /// By UUID.
    public var removeVolumes: [String] = []
    public var photos: Bool?
    public var onBattery: Bool?
    /// Whether `settings` are still what the plan was made against. One made before building on battery power was
    /// off unless the user turns it on (luoke-search#46, defect 2), with no settings saved, has the old default, on:
    /// while none are saved it still fits, or a card shown before the upgrade would be stale for it (review 11-02).
    public func fits(_ settings: Settings, saved: Bool) -> Bool {
        if basis == settings { return true }
        guard !saved, basis.onBattery, !settings.onBattery else { return false }
        var old = settings
        old.onBattery = true
        return basis == old
    }

    /// What the user may tick and untick on the plan's card before tapping [好] (the `needs-setup` report), keyed
    /// `folder<n>` (`addFolders[n]`) and `photos`, each with what it starts as. Nil: the plan is carried out as it is.
    public var choices: [String: Bool]?

    enum CodingKeys: String, CodingKey {
        case id, made, basis
        case addFolders = "add_folders"
        case removeFolders = "remove_folders"
        case skipFolders = "skip_folders"
        case unskipFolders = "unskip_folders"
        case addVolumes = "add_volumes"
        case removeVolumes = "remove_volumes"
        case photos
        case onBattery = "on_battery"
        case choices
    }

    public init(id: String, made: Double, basis: Settings) {
        self.id = id
        self.made = made
        self.basis = basis
    }

    /// Keys added later read as empty: a plan kept by an earlier version is still one.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        made = try container.decode(Double.self, forKey: .made)
        basis = try container.decode(Settings.self, forKey: .basis)
        addFolders = try container.decodeIfPresent([String].self, forKey: .addFolders) ?? []
        removeFolders = try container.decodeIfPresent([String].self, forKey: .removeFolders) ?? []
        skipFolders = try container.decodeIfPresent([String].self, forKey: .skipFolders) ?? []
        unskipFolders = try container.decodeIfPresent([String].self, forKey: .unskipFolders) ?? []
        addVolumes = try container.decodeIfPresent([ChosenVolume].self, forKey: .addVolumes) ?? []
        removeVolumes = try container.decodeIfPresent([String].self, forKey: .removeVolumes) ?? []
        photos = try container.decodeIfPresent(Bool.self, forKey: .photos)
        onBattery = try container.decodeIfPresent(Bool.self, forKey: .onBattery)
        choices = try container.decodeIfPresent([String: Bool].self, forKey: .choices)
    }

    public var isEmpty: Bool {
        addFolders.isEmpty && removeFolders.isEmpty && skipFolders.isEmpty && unskipFolders.isEmpty && addVolumes.isEmpty
            && removeVolumes.isEmpty && photos == nil && onBattery == nil
    }

    static func folderChoice(_ index: Int) -> String { "folder\(index)" }

    /// The plan with only what's ticked: `ticks` from the card, the rest as they started. Nil when `ticks` names
    /// something that isn't on the card (agent tool protocol §5: the user may only change the plan's own options).
    /// The Photos library is a choice only (`photos` stays nil until ticked): a version that knows no choices
    /// carries the plan out as it started, without it.
    public func ticked(_ ticks: [String: Bool]) -> SettingsPlan? {
        guard let choices else { return ticks.isEmpty ? self : nil }
        guard Set(ticks.keys).isSubset(of: choices.keys) else { return nil }
        let on = choices.merging(ticks) { $1 }
        var out = self
        out.addFolders = addFolders.indices.filter { on[Self.folderChoice($0)] ?? true }.map { addFolders[$0] }
        if choices["photos"] != nil { out.photos = on["photos"] == true ? true : nil }
        out.choices = nil
        return out
    }

    public func applied(to settings: Settings) -> Settings {
        var out = settings
        for folder in addFolders where !out.folders.contains(folder) { out.folders.append(folder) }
        out.folders.removeAll { removeFolders.contains($0) }
        for folder in skipFolders where !out.skipFolders.contains(folder) { out.skipFolders.append(folder) }
        out.skipFolders.removeAll { unskipFolders.contains($0) }
        for volume in addVolumes where !out.volumes.contains(where: { $0.uuid == volume.uuid }) { out.volumes.append(volume) }
        out.volumes.removeAll { removeVolumes.contains($0.uuid) }
        if let photos { out.photos = photos }
        if let onBattery { out.onBattery = onBattery }
        return out
    }
}

/// Plans and the outbox's bookkeeping, in the data directory (private, out of backups).
public struct ToolState: Codable, Sendable {
    public var plans: [SettingsPlan] = []
    /// Outbox items the agent said were answered or dismissed (`outbox_ack`): not shown again.
    public var closed: [String] = []
    /// When the first pass over the folders finished (the `index-ready` report).
    public var firstPassDone: Double?
    /// When folders (or the Photos library) were first chosen: from then on there's no `needs-setup` report, even
    /// once they're all taken out again (that was the user's own doing).
    public var foldersChosen: Double?
    /// The number in the Photos `needs-access` item's id, a new one each time asking is needed again (turned on again,
    /// access taken back): the agent never shows an id again once it's done or gone (review of PR #42, must-fix 1).
    /// The time it was needed, or one more than the last.
    public var photosItem = 0
    /// Whether asking was needed at the last look (photos on, not allowed).
    public var photosNeeded = false
    /// The number in each searched folder's `needs-access` item's id, kept while macOS won't let the resident read it.
    /// A folder that could be read again, or was taken out of the settings, is let go: the next time it gets a new
    /// number (from `folderItem`), as the Photos item does. Only folders searched now, so never longer than the
    /// settings' list.
    public var folderItems: [String: Int] = [:]
    /// The last number given to a folder's item: the time it was needed, or one more than the last (a folder let go
    /// and needing the user again never gets an old one, nor after the state file was lost).
    public var folderItem = 0

    enum CodingKeys: String, CodingKey {
        case plans, closed
        case firstPassDone = "first_pass_done"
        case foldersChosen = "folders_chosen"
        case photosItem = "photos_item"
        case photosNeeded = "photos_needed"
        case folderItems = "folder_items"
        case folderItem = "folder_item"
    }

    public init() {}

    /// Notes that something is chosen to search, the first time only; the `needs-setup` card's plan goes (it isn't
    /// offered again).
    mutating func chose() {
        guard foldersChosen == nil else { return }
        foldersChosen = Date().timeIntervalSince1970
        plans.removeAll { $0.choices != nil }
    }

    /// Missing keys at their defaults, as for the settings.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plans = (try? container.decodeIfPresent([SettingsPlan].self, forKey: .plans)) ?? []
        closed = try container.decodeIfPresent([String].self, forKey: .closed) ?? []
        firstPassDone = try container.decodeIfPresent(Double.self, forKey: .firstPassDone)
        foldersChosen = try container.decodeIfPresent(Double.self, forKey: .foldersChosen)
        photosItem = try container.decodeIfPresent(Int.self, forKey: .photosItem) ?? 0
        photosNeeded = try container.decodeIfPresent(Bool.self, forKey: .photosNeeded) ?? false
        folderItems = (try? container.decodeIfPresent([String: Int].self, forKey: .folderItems)) ?? [:]
        folderItem = try container.decodeIfPresent(Int.self, forKey: .folderItem) ?? 0
    }

    public static func load(_ directory: DataDirectory) -> ToolState {
        guard let data = try? Data(contentsOf: directory.stateFile),
              let state = try? JSONDecoder().decode(ToolState.self, from: data) else { return ToolState() }
        return state
    }

    public func save(_ directory: DataDirectory) throws {
        try directory.prepare()
        try Stored.write(self, to: directory.stateFile)
    }

    /// Notes that the folders (and the Photos library, once it has been taken in) have been read through once (for
    /// the `index-ready` report), the first time only. Only folders searched count (`restricted`: as the app as it
    /// ships judges them), or folders it won't search would make "0 files indexed" done (luoke-search#46, defect 8).
    public static func noteFirstPassIfDone(_ directory: DataDirectory, store: IndexStore, restricted: Bool,
                                           home: String = NSHomeDirectory()) throws {
        guard ToolState.load(directory).firstPassDone == nil else { return }
        let settings = Settings.load(directory)
        let photos = try settings.photos
            && store.db.scalarInt("SELECT EXISTS(SELECT 1 FROM items WHERE source = 'photos')") == 1
        guard !settings.searched(restricted: restricted, home: home).isEmpty || photos,
              try store.counts().waitingToRead == 0 else { return }
        try update(directory) { state in
            if state.firstPassDone == nil { state.firstPassDone = Date().timeIntervalSince1970 }
        }
    }

    /// The same after `index` walked the folders in the settings (none given), judging them as the app does where it
    /// ships (luoke-search#46, defect 8).
    public static func noteFirstPassAfterIndex(_ arguments: CommandArguments, directory: DataDirectory,
                                               store: IndexStore, home: String = NSHomeDirectory()) throws {
        guard arguments.positional.isEmpty else { return }
        try noteFirstPassIfDone(directory, store: store, restricted: arguments.shipped, home: home)
    }

    /// Read, changed and written back under the data directory's lock (review C-17: the MCP thread, the resident
    /// queue, a job and the command line all write this file).
    public static func update(_ directory: DataDirectory, _ change: (inout ToolState) throws -> Void) throws {
        try Stored.locked(directory) {
            var state = ToolState.load(directory)
            try change(&state)
            try state.save(directory)
        }
    }
}

enum Stored {
    private static let lock = NSLock()

    /// Runs `body` holding the data directory's lock: one thread in this process (the lock isn't re-entrant: no
    /// nesting), one process on this Mac (flock on `<data>/.lock`).
    static func locked<T>(_ directory: DataDirectory, _ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try directory.prepare()
        let fd = open(directory.url.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer {
            if fd >= 0 {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }
        return try body()
    }
    /// Written whole and private (600), replacing the old file in one step.
    static func write<T: Encodable>(_ value: T, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

extension DataDirectory {
    public var settingsFile: URL { url.appendingPathComponent("settings.json") }
    public var stateFile: URL { url.appendingPathComponent("state.json") }
    public var agentSocket: URL { runFolder.appendingPathComponent("agent.sock") }
}
