import Foundation

/// What the window shows of this tool besides cards (agent tool protocol §1a, luoke-agent#3, top-level ADR 0014's
/// 10-27 revision): the summary by the sidebar and the state of the Photos permission, read over the same socket as
/// the outbox by relative id (`summary`, `permissions`), and one base page (`page/overview`): how far the index is,
/// what's searched, what was read lately, and a switch for the Photos library. No window of its own: searching is the window's global
/// search, for every tool (agreed in luoke-agent#3).
extension SearchService {
    /// The base page's id: a tap on it carries this as its surface (agent tool protocol §1a).
    public static let overviewPage = "overview"

    /// The app's page. Folders by name, and numbers: never a file's name, what's in it, or anything searched for.
    public func overview() throws -> [[String: Any]] {
        let status = try status()
        guard let settings = Settings.read(directory) else {
            return Cards.note("概览", Settings.unreadable, surfaceID: Self.overviewPage)
        }
        let shown = pageStatus(status)
        return Cards.overview(exact: shown.exact, semantic: shown.semantic, note: shown.note,
                              folders: settings.searched(restricted: restrictFolders, home: home).map(quietName),
                              photos: status["photos"] as? String ?? "off",
                              photosRefused: permissionStates()["photos"] == "denied",
                              lastRead: try store.lastRead(),
                              photosSwitch: ToolState.load(directory).foldersChosen != nil)
    }

    /// A folder's name without asking Finder: the page is read each time it's opened, and `display` may look inside a
    /// folder macOS protects, which would ask the user (review C-09). Credentials masked, as `display` does.
    func quietName(_ folder: String) -> String {
        Self.placeNames.first { home + "/" + $0.key == folder }?.value ?? Secrets.mask((folder as NSString).lastPathComponent)
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
