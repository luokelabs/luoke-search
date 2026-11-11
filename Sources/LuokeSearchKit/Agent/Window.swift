import CryptoKit
import Foundation

/// What the window shows of this tool besides cards (agent tool protocol §1a, luoke-agent#3, top-level ADR 0014's
/// 10-27 revision): the summary by the sidebar and the state of the Photos permission, read over the same socket as
/// the outbox by relative id (`summary`, `permissions`), and one base page (`page/overview`): how far the index is,
/// what's searched (each folder with 「不搜了」), what was read lately, and a switch for the Photos library. No window
/// of its own: searching is the window's global search, for every tool (agreed in luoke-agent#3).
extension SearchService {
    /// The base page's id: a tap on it carries this as its surface (agent tool protocol §1a).
    public static let overviewPage = "overview"

    /// The app's page. Folders by name (two of the same name with the folder they're in), and numbers: never a path,
    /// a file's name, what's in it, or anything searched for. A folder's 「不搜了」 carries its `folderID`, not its path.
    public func overview() throws -> [[String: Any]] {
        let status = try status()
        guard let settings = Settings.read(directory) else {
            return Cards.note("概览", Settings.unreadable, surfaceID: Self.overviewPage)
        }
        let shown = pageStatus(status)
        let mounted = mountedVolumes()
        let searched = settings.searched(restricted: restrictFolders, home: home, mounted: mounted)
        let names = searched.map(quietName)
        let repeated = Set(names.filter { name in names.count { $0 == name } > 1 })
        let folders = zip(searched, names).map { folder, name in
            (name: repeated.contains(name) ? "\(name)（\(quietName((folder as NSString).deletingLastPathComponent))）" : name,
             id: Self.folderID(folder))
        }
        // A disk chosen but not plugged in says so, as does one whose place something else has taken (not searched,
        // its 不搜了 still there); one plugged in and not chosen is offered.
        let named = zip(folders, searched).map { folder, path in
            settings.volumes.contains(where: { $0.path == path }) && !FileManager.default.fileExists(atPath: path)
                ? (name: folder.name + "（没接上）", id: folder.id) : folder
        } + settings.volumes.filter { volume in
            !searched.contains(volume.path) && !mounted.contains { $0.uuid == volume.uuid }
        }.map { (name: quietName($0.path) + "（没接上）", id: Self.folderID($0.path)) }
        let offered = mounted.filter { disk in
            !settings.volumes.contains { $0.uuid == disk.uuid } && !searched.contains(disk.path)
        }.map { (name: Secrets.mask($0.name), id: Self.diskID($0.uuid)) }
        let skipped = settings.skipFolders.map { (name: quietName($0), id: Self.folderID($0)) }
        return Cards.overview(exact: shown.exact, semantic: shown.semantic, note: shown.note, folders: named,
                              inHome: homeFolders(settings, searched: searched).map { (name: quietName($0), id: Self.folderID($0)) },
                              skipped: skipped, disks: offered,
                              photos: status["photos"] as? String ?? "off",
                              photosRefused: permissionStates()["photos"] == "denied",
                              lastRead: try store.lastRead(),
                              changeable: ToolState.load(directory).foldersChosen != nil)
    }

    /// The folders right in a searched home folder that the walk goes into, for 「跳过」: the usual places first.
    /// Only the home folder's own list is read (macOS doesn't protect it): never what's inside the desktop, documents
    /// or iCloud Drive, which would have macOS ask the user each time the page is opened.
    func homeFolders(_ settings: Settings, searched: [String]) -> [String] {
        let home = Crawler.canonical(self.home)
        guard searched.map(Crawler.canonical).contains(home),
              let names = try? FileManager.default.contentsOfDirectory(atPath: home) else { return [] }
        let skipped = settings.skipFolders.map(Crawler.canonical)
        // One chosen on its own (an earlier version's desktop) is searched whatever's skipped: its own 「不搜了」 is
        // what takes it out.
        let roots = Set(searched.map(Crawler.canonical))
        let usual = ["Desktop", "Documents", "Downloads", "Pictures", "Movies"]
        return names.filter { name in
            guard !roots.contains(home + "/" + name) else { return false }
            let url = URL(fileURLWithPath: home + "/" + name)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]),
                  values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true else { return false }
            return Rules.skipReason(folder: url, home: home, excluded: skipped) == nil
        }.sorted { a, b in
            let (i, j) = (usual.firstIndex(of: a) ?? usual.count, usual.firstIndex(of: b) ?? usual.count)
            return i != j ? i < j : a.localizedStandardCompare(b) == .orderedAscending
        }.map { home + "/" + $0 }
    }

    /// 「跳过」 on a folder in the home folder tapped: found again by its id among them, skipped by the same plan the
    /// command line makes, at once (its entries leave the index at the next walk). Only a tap on the page itself.
    public func skipFolder(_ id: String, surfaceID: String?) throws -> String {
        let settings = try pageTapped(surfaceID)
        let searched = settings.searched(restricted: restrictFolders, home: home, mounted: mountedVolumes())
        guard let folder = homeFolders(settings, searched: searched).first(where: { Self.folderID($0) == id }) else {
            return "已经跳过了，或者不在个人文件夹里了。"
        }
        var change = Change()
        change.skipFolders = [folder]
        try carryOut(change)
        return "跳过「\(quietName(folder))」了，里面的内容会移出索引。"
    }

    /// 「不跳过了」 on a skipped folder tapped: searched again from the next walk.
    public func unskipFolder(_ id: String, surfaceID: String?) throws -> String {
        let settings = try pageTapped(surfaceID)
        guard let folder = settings.skipFolders.first(where: { Self.folderID($0) == id }) else { return "已经不跳过了。" }
        var change = Change()
        change.unskipFolders = [folder]
        try carryOut(change)
        return "不再跳过「\(quietName(folder))」了，里面的内容会在后台读进来。"
    }

    /// 「也搜这块盘」 tapped: the disk of that UUID, plugged in now, searched from the next walk. macOS asks the user
    /// first (removable volumes): the tap is the user's own, as for a folder added on a card.
    public func searchDisk(_ id: String, surfaceID: String?) throws -> String {
        let settings = try pageTapped(surfaceID)
        guard !settings.volumes.contains(where: { Self.diskID($0.uuid) == id }) else { return "已经在搜这块盘了。" }
        guard let disk = mountedVolumes().first(where: { Self.diskID($0.uuid) == id }) else {
            throw ToolFailure("invalid", "这块盘现在没接在这台 Mac 上。")
        }
        var change = Change()
        change.addVolumes = [disk.uuid]
        try carryOut(change)
        return "也搜「\(Secrets.mask(disk.name))」了，盘上的文件会在后台慢慢读进来。"
    }

    /// What a disk's 「也搜这块盘」 carries: its UUID hashed, as a folder's path is (a UUID names one device for good).
    static func diskID(_ uuid: String) -> String { folderID("disk:" + uuid) }

    /// The settings, when the tap was on the page itself and something was chosen before (else the setup card asks).
    func pageTapped(_ surfaceID: String?) throws -> Settings {
        guard surfaceID == Self.overviewPage else {
            throw ToolFailure("needs_user_action", "这个操作要你在螺壳搜索的页面上点过才能执行。")
        }
        guard ToolState.load(directory).foldersChosen != nil else { throw ToolFailure("needs_setup", "先选好要搜的地方。") }
        guard let settings = Settings.read(directory) else { throw ToolFailure("needs_setup", Settings.unreadable) }
        return settings
    }

    /// A change from the page, planned and carried out at once; a plan that fails isn't left for a card (nobody saw it).
    @discardableResult
    func carryOut(_ change: Change) throws -> Bool {
        let (plan, _) = try plan(change)
        guard !plan.isEmpty else { return false }
        do {
            _ = try apply(planID: plan.id, surfaceID: nil)
        } catch {
            // Not left for a card to carry out: nobody saw this plan.
            try? ToolState.update(directory) { $0.plans.removeAll { $0.id == plan.id } }
            throw error
        }
        return true
    }

    /// A folder's name without asking Finder: the page is read each time it's opened, and `display` may look inside a
    /// folder macOS protects, which would ask the user (review C-09). Credentials masked, as `display` does.
    func quietName(_ folder: String) -> String {
        special(folder) ?? inHome(folder).flatMap { Self.placeNames[$0] }
            ?? Secrets.mask((folder as NSString).lastPathComponent)
    }

    /// The page's switch tapped: carried out as the same plan the command line makes, so with the same checks.
    /// Only a tap on the page itself says so: one on a card is about that card (review C-16).
    /// `onBattery` has no switch here: while luoke-core answers its own rule decides (`Resident.backlogHeld`), and in
    /// 螺壳 it nearly always does, so it would change nothing.
    public func flipPhotos(_ on: Bool, surfaceID: String?) throws -> String {
        guard surfaceID == Self.overviewPage else {
            throw ToolFailure("needs_user_action", "这个操作要你在螺壳搜索的页面上点过才能执行。")
        }
        // Before anything's chosen there's a `needs-setup` card, and a change here would end it for good (`chose`):
        // the page can't choose folders, so the card must stay.
        guard ToolState.load(directory).foldersChosen != nil else {
            throw ToolFailure("needs_setup", "先选好要搜的地方。")
        }
        var change = Change()
        change.photos = on
        let (plan, _) = try plan(change)
        return plan.isEmpty ? "已经是这样了。" : try apply(planID: plan.id, surfaceID: nil)
    }

    /// What a folder's 「不搜了」 carries: its path as the settings keep it, hashed. The page never sends a path (a
    /// credential in one would go out whole), a tap names one folder, and it's found as stored, however spelled.
    static func folderID(_ folder: String) -> String {
        SHA256.hash(data: Data(folder.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// A 「不搜了」 on the page tapped: the folder of that `folderID` in the settings, taken out by the same plan the
    /// command line makes, carried out at once: its entries leave the index. No card to confirm: the tap is on the
    /// folder's own line. Only a tap on the page itself says so, as for the switch.
    public func stopSearching(_ id: String, surfaceID: String?) throws -> String {
        guard surfaceID == Self.overviewPage else {
            throw ToolFailure("needs_user_action", "这个操作要你在螺壳搜索的页面上点过才能执行。")
        }
        guard ToolState.load(directory).foldersChosen != nil else {
            throw ToolFailure("needs_setup", "先选好要搜的地方。")
        }
        guard let settings = Settings.read(directory) else { throw ToolFailure("needs_setup", Settings.unreadable) }
        let mounted = mountedVolumes()
        if settings.folders.first(where: { Self.folderID($0) == id }) == nil,
           let disk = settings.volumes.first(where: { volume in
               ([volume.path] + Volumes.roots([volume], mounted: mounted)).contains { Self.folderID($0) == id }
           }) {
            var change = Change()
            change.removeVolumes = [disk.uuid]
            guard try carryOut(change) else { return "已经不搜了。" }
            return "不再搜「\(quietName(disk.path))」这块盘了，盘上的内容已移出索引。"
        }
        guard let folder = settings.folders.first(where: { Self.folderID($0) == id }) else { return "已经不搜了。" }
        var change = Change()
        change.removeFolders = [folder]
        guard try carryOut(change) else { return "已经不搜了。" }
        // Inside another folder still searched: its files stay (`prune` keeps them), so say that.
        if let outer = settings.searched(restricted: restrictFolders, home: home)
            .first(where: { $0 != folder && folder.hasPrefix($0 + "/") }) {
            return "不再单独搜「\(quietName(folder))」了：它在「\(quietName(outer))」里面，照样搜得到。"
        }
        return "不再搜「\(quietName(folder))」了，里面的内容已移出索引。"
    }

    /// Under an empty result: the folders that were looked in, and that others can be added. Not "only": the Photos
    /// library may have been searched too. Nothing when the search asked only for the Photos library (`sources`), or
    /// the settings can't be read.
    public func searchedNote(sources: Set<ItemSource>?) -> String? {
        guard sources?.contains(.files) ?? true, let settings = Settings.read(directory) else { return nil }
        let names = settings.searched(restricted: restrictFolders, home: home).map(quietName)
        guard !names.isEmpty else { return "现在一个文件夹都不搜；要搜的话，跟螺壳说要搜哪个。" }
        let shown = names.count <= 3 ? names.joined(separator: "、")
            : names.prefix(3).joined(separator: "、") + " 等 \(names.count) 个"
        return "找过的文件夹：\(shown)。要搜别的文件夹，跟螺壳说一声。"
    }

    /// The outbox kinds that wait for the user (the summary's `count`); `index-ready` only tells.
    static let waitingKinds: Set<String> = ["needs-setup", "needs-access"]

    /// `{"count", "text"}`: what waits for the user and one sentence on how far the index is.
    public func summary() -> [String: Any] {
        let items = outbox()["items"] as? [[String: Any]] ?? []
        let waiting = items.count { Self.waitingKinds.contains($0["kind"] as? String ?? "") }
        // Not "nothing chosen": the resident doesn't index by a file it can't read (review A-05).
        guard let settings = Settings.read(directory) else { return ["count": waiting, "text": "设置文件读不了"] }
        guard chosen(settings) else { return ["count": waiting, "text": "还没选要搜的地方"] }
        // Photos only when they're really read: on, and allowed.
        let readsPhotos = settings.photos && photos?.access == .allowed
        let counts = (try? store.counts()) ?? IndexStore.Counts()
        let total = counts.items.values.reduce(0, +)
        var text: String
        if settings.searched(restricted: restrictFolders, home: home).isEmpty, !readsPhotos {
            // Only photos chosen, and not read: nothing is being indexed (not "已读 0 个").
            text = photos?.access == .notAsked ? "要你允许读照片" : "读不了照片"
        } else if ToolState.load(directory).firstPassDone == nil {
            text = "正在建索引：已读 \(total) 个" + (counts.waitingToRead > 0 ? "，还有 \(counts.waitingToRead) 个" : "")
        } else {
            text = "已索引 \(total) 个文件" + (readsPhotos ? "和照片" : "")
        }
        if waiting > 0 { text += "，\(waiting) 件要你处理" }
        return ["count": waiting, "text": text]
    }

    /// Each permission in the manifest as this app may use it now (macOS and the user's say), asked without prompting.
    /// Photos: denied too when this process can't read the library at all (development runs); never guessed from an
    /// earlier answer.
    public func permissionStates() -> [String: String] {
        let photos: String = switch self.photos?.access {
        case .allowed: "granted"
        case .notAsked: "ask"
        case .denied, nil: "denied"
        }
        return ["photos": photos]
    }

    /// What this search didn't look in, or only partly, for the window's row under the results (§1b, "照片还没允许搜"):
    /// the Photos library while it isn't searched (not chosen in the settings, not allowed yet, refused), or while only
    /// what was read before it was refused is (the resident takes photos out only when they're turned off). Nothing
    /// when this process doesn't read Photos (the command line), the settings can't be read, or the search asks only
    /// for kinds or sources the library doesn't have. Each has a `text` and a line under it, `detail`. Whether macOS allows it only the resident judges (`judgesAccess`): another
    /// process with the library has its own answer, a terminal's.
    public func skippedSources(kinds: Set<ItemKind>?, sources: Set<ItemSource>? = nil) -> [[String: Any]] {
        guard let photos, kinds.map({ !$0.isDisjoint(with: [.photo, .video]) }) ?? true,
              sources?.contains(.photos) ?? true,
              let settings = Settings.read(directory) else { return [] }
        guard settings.photos else {
            return [["source": "photos", "why": "off", "text": "没在搜照片图库", "detail": "要搜的话，在螺壳搜索的设置里打开照片图库"]]
        }
        guard judgesAccess, photos.access != .allowed else { return [] }
        if photos.access == .notAsked {
            return [["source": "photos", "why": "needs_access", "permission": "photos", "text": "照片还没允许搜",
                     "detail": "允许以后，照片里的字和画面也能搜到"]]
        }
        if (try? store.hasPhotos()) == true {
            return [["source": "photos", "why": "not_updated", "permission": "photos",
                     "text": "照片没允许读了，只搜得到以前读过的", "detail": "再允许以后，新拍的照片也能搜到"]]
        }
        return [["source": "photos", "why": "denied", "permission": "photos", "text": "照片没允许读，要在系统设置里允许",
                 "detail": "在 系统设置 › 隐私与安全性 › 照片 里允许以后，照片里的字和画面也能搜到"]]
    }

    /// The sentence for the answer's text: what the agent's model should know, the settings' own choice (`off`) not
    /// repeated with every search.
    static func skippedSentence(_ skipped: [[String: Any]]) -> String {
        skipped.filter { $0["why"] as? String != "off" }.compactMap { $0["text"] as? String }
            .map { "\n（\($0)）" }.joined()
    }
}
