import Foundation

/// How far a way of searching is, on the page: a word, or a count with a bar.
struct SearchState: Equatable {
    let text: String
    var progress: Double?

    init(_ text: String, progress: Double? = nil) {
        self.text = text
        self.progress = progress
    }

    static func progress(_ done: Int, of total: Int) -> SearchState {
        SearchState("\(done) / \(total)", progress: total > 0 ? Double(done) / Double(total) : 0)
    }
}

/// A2UI v0.9.1 cards for luoke-agent (agent tool protocol §4), from the components of the catalog
/// `ai.luoke/a2ui/agent/1` only. Modelled on luoke-agent's `cards.py`; its `a2ui.py` checks what's made here in tests.
public struct Card {
    public static let catalog = "ai.luoke/a2ui/agent/1"
    static let version = "v0.9"
    /// The protocol's limits: 200 components a card, 2000 characters a text.
    static let maxText = 2000

    public let surfaceID: String
    private let prefix: String
    private var components: [[String: Any]] = []
    private var top: [String] = []
    private var count = 0
    /// The card's data model: what its check boxes start as (`/checks/<key>`).
    private var checks: [String: Bool] = [:]
    /// The space between the card's top-level parts, when it isn't the renderer's own.
    private let gap: Int?

    public init(surfaceID: String, idPrefix: String = "", gap: Int? = nil) {
        self.surfaceID = surfaceID
        prefix = idPrefix
        self.gap = gap
    }

    private mutating func newID(_ kind: String) -> String {
        count += 1
        return "\(prefix)\(kind)\(count)"
    }

    @discardableResult
    private mutating func add(_ component: [String: Any], top isTop: Bool = true) -> String {
        components.append(component)
        let id = component["id"] as! String
        if isTop { top.append(id) }
        return id
    }

    /// The limit counts code points (as the agent's a2ui.py does), not what Swift calls characters.
    static func clip(_ text: String) -> String {
        guard text.unicodeScalars.count > maxText else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.prefix(maxText - 1))
        return String(scalars) + "…"
    }

    func textComponent(_ id: String, _ text: String, variant: String? = nil) -> [String: Any] {
        var component: [String: Any] = ["id": id, "component": "Text", "text": Self.clip(text)]
        if let variant { component["variant"] = variant }
        return component
    }

    public mutating func heading(_ text: String) {
        let id = newID("h")
        add(textComponent(id, text, variant: "h4"))
    }

    public mutating func text(_ text: String, caption: Bool = false) {
        let id = newID("t")
        add(textComponent(id, text, variant: caption ? "caption" : nil))
    }

    public struct Button {
        let label: String
        let event: String
        let context: [String: Any]
        let primary: Bool
        /// Drawn as a switch, on or off (`variant: switch`): a tap is still the button's action, and the page drawn
        /// again says what it is now. A window that doesn't know the variant draws the label on a plain button.
        let switchedOn: Bool?

        public init(_ label: String, event: String, context: [String: Any] = [:], primary: Bool = false,
                    switchedOn: Bool? = nil) {
            self.label = label
            self.event = event
            self.context = context
            self.primary = primary
            self.switchedOn = switchedOn
        }
    }

    /// A button's components (not yet placed anywhere); returns its id.
    private mutating func component(_ button: Button) -> String {
        let id = newID("b"), label = id + "-text"
        var component: [String: Any] = ["id": id, "component": "Button", "child": label,
                                        "action": ["event": ["name": button.event, "context": button.context]]]
        if button.primary { component["variant"] = "primary" }
        if let on = button.switchedOn {
            component["variant"] = "switch"
            component["on"] = on
        }
        add(component, top: false)
        add(textComponent(label, button.label), top: false)
        return id
    }

    /// The components of a row of buttons (not yet placed anywhere); returns the row's id.
    private mutating func row(_ buttons: [Button]) -> String {
        let ids = buttons.map { component($0) }
        let id = newID("r")
        add(["id": id, "component": "Row", "children": ids], top: false)
        return id
    }

    /// One line of a list: the name on the left; on the right what it is, and a button if there's one.
    public mutating func line(_ name: String, _ value: String?, progress: Double? = nil, buttons: [Button] = []) {
        let nameID = newID("t")
        add(textComponent(nameID, name), top: false)
        var children = [nameID]
        if let progress {
            let barID = newID("p")
            add(["id": barID, "component": "ProgressBar", "value": min(max(progress, 0), 1)], top: false)
            children.append(barID)
        }
        if let value {
            let valueID = newID("t")
            add(textComponent(valueID, value), top: false)
            children.append(valueID)
        }
        children += buttons.map { component($0) }
        add(["id": newID("r"), "component": "Row", "justify": "spaceBetween", "children": children])
    }

    public mutating func divider() {
        add(["id": newID("d"), "component": "Divider"])
    }

    public mutating func buttons(_ buttons: Button...) {
        top.append(row(buttons))
    }

    /// A check box bound to `/checks/<key>` in the card's data model; a button's context takes them all with
    /// `["path": "/checks"]` (as the agent's `cards.py` does).
    public mutating func checkbox(_ key: String, label: String, value: Bool) {
        checks[key] = value
        add(["id": "\(prefix)k-\(key)", "component": "CheckBox", "label": Self.clip(label),
             "value": ["path": "/checks/\(key)"]])
    }

    /// One result: a `Card` holding its title, a line of where and when, the snippet, and buttons.
    public mutating func result(title: String, line: String, snippet: String?, buttons: [Button]) {
        var children: [String] = []
        let titleID = newID("t")
        add(textComponent(titleID, title), top: false)
        children.append(titleID)
        let lineID = newID("t")
        add(textComponent(lineID, line, variant: "caption"), top: false)
        children.append(lineID)
        if let snippet, !snippet.isEmpty {
            let snippetID = newID("t")
            add(textComponent(snippetID, snippet), top: false)
            children.append(snippetID)
        }
        if !buttons.isEmpty { children.append(row(buttons)) }
        let column = newID("c")
        add(["id": column, "component": "Column", "children": children], top: false)
        let card = newID("k")
        add(["id": card, "component": "Card", "child": column])
    }

    var allComponents: [[String: Any]] {
        var root: [String: Any] = ["id": "root", "component": "Column", "children": top]
        if let gap { root["gap"] = gap }
        return [root] + components
    }

    /// A new card: `createSurface`, then its components and data model.
    public func messages() -> [[String: Any]] {
        [["version": Self.version, "createSurface": ["surfaceId": surfaceID, "catalogId": Self.catalog]]]
            + updateMessages()
    }

    /// The same card redrawn (after an action: the result in place of the plan). `data: false` leaves the data model
    /// as it is: what the user ticked stays ticked.
    public func updateMessages(data: Bool = true) -> [[String: Any]] {
        var messages: [[String: Any]] = [["version": Self.version,
                                          "updateComponents": ["surfaceId": surfaceID, "components": allComponents]]]
        if data, !checks.isEmpty {
            messages.append(["version": Self.version,
                             "updateDataModel": ["surfaceId": surfaceID, "path": "/", "value": ["checks": checks]]])
        }
        return messages
    }
}

/// The cards luoke-search shows through the agent.
enum Cards {
    /// Over the results when none of the rows shown is sure.
    static let noneSure = "没有很对得上的，下面这些可能相关。"

    /// Results: the first five, each with [打开] and [在访达中显示] (both `search_open`: on the user's tap only, Mac only).
    /// `searched`: with none, the folders that were looked in (`SearchService.searchedNote`).
    static func results(_ answer: SearchAnswer, query: String, searched: String? = nil,
                        surfaceID: String) -> [[String: Any]] {
        var card = Card(surfaceID: surfaceID)
        let shown = answer.hits.prefix(5)
        card.heading(answer.hits.isEmpty ? "没有找到对得上的" : "找到 \(answer.hits.count) 条")
        if let reason = answer.partialReason { card.text(reason, caption: true) }
        // `strong` is a result's own (the name holds the words, or it's close in meaning), not its place in the list,
        // and a sure one may rank below the rows shown: judged on those. When none is, one line says so rather than a
        // 「可能相关」 on every row; a listing of the newest (score 0) isn't an answer and says neither.
        let anySure = shown.contains(where: \.strong)
        if !anySure, shown.contains(where: { $0.score > 0 }) { card.text(Self.noneSure, caption: true) }
        if answer.hits.isEmpty, let searched { card.text(searched, caption: true) }
        for hit in shown {
            var line = [hit.kind.label]
            if let place = hit.where.flatMap(Cards.place) { line.append(place) }
            line.append(String(hit.date.prefix(10)))
            if anySure, !hit.strong { line.append("可能相关") }
            let buttons = openings(hit).enumerated().map { index, opening in
                Card.Button(opening.label, event: "search_open", context: opening.args, primary: index == 0)
            }
            card.result(title: hit.title, line: line.joined(separator: " · "), snippet: hit.snippet, buttons: buttons)
        }
        if answer.hits.count > shown.count { card.text("还有 \(answer.hits.count - shown.count) 条没列出", caption: true) }
        return card.messages()
    }

    /// A result's buttons, on its card and in the window's list: [打开], and for a file [在访达中显示].
    static func openings(_ hit: Hit) -> [(label: String, args: [String: Any])] {
        var openings: [(label: String, args: [String: Any])] = [("打开", ["id": hit.id])]
        if hit.path != nil { openings.append(("在访达中显示", ["id": hit.id, "reveal": true])) }
        return openings
    }

    static func place(_ location: Location) -> String? {
        if let page = location.page { return "第 \(page) 页" }
        if let part = location.part { return "第 \(part) 部分" }
        if let sheet = location.sheet { return "第 \(sheet) 个工作表" }
        if let time = location.time { return Searcher.clock(time) }
        return nil
    }

    /// A settings plan: what would change, [好] (`search_settings_apply`) and [算了] (`agent.dismiss`).
    /// A folder goes by the name the user knows; its full path is in the small print under it. At most 20 lines
    /// (a card holds 200 components: review C-14). `note` and a button to `settingsPane` when something must be
    /// allowed first; `update` to draw it again in place (review C-13).
    static func plan(_ plan: SettingsPlan, lines: [SearchService.PlanLine], surfaceID: String, update: Bool = false,
                     note: String? = nil, settingsPane: String? = nil) -> [[String: Any]] {
        var card = Card(surfaceID: surfaceID, idPrefix: update ? "again-" : "")
        card.heading("要这样改螺壳搜索的设置吗")
        let shown = lines.count > maxPlanLines ? Array(lines.prefix(maxPlanLines - 1)) : lines
        for line in shown {
            card.text(line.text)
            if let path = line.path { card.text(path, caption: true) }
        }
        if shown.count < lines.count { card.text("另外 \(lines.count - shown.count) 项") }
        if let note { card.text(note, caption: true) }
        let apply = Card.Button("好", event: "search_settings_apply", context: ["plan_id": plan.id], primary: true)
        if let settingsPane {
            card.buttons(apply, Card.Button("打开系统设置", event: "search_open_system_settings",
                                            context: ["pane": settingsPane]),
                         Card.Button("算了", event: "agent.dismiss"))
        } else {
            card.buttons(apply, Card.Button("算了", event: "agent.dismiss"))
        }
        return update ? card.updateMessages() : card.messages()
    }

    static let maxPlanLines = 20

    /// One tick on the `needs-setup` card: the plan's choice it sets, what it says, whether it starts ticked.
    struct Choice {
        let key: String
        let label: String
        let on: Bool
    }

    /// Nothing chosen yet (`needs-setup`): the usual places ticked, the Photos library not. [好] carries out the plan
    /// with what's ticked (`search_settings_apply` with `checks`), [算了] puts it down. `note` and a button to
    /// `settingsPane` when something must be allowed first; `update` to draw it again in place, the ticks as the user
    /// left them.
    static func setup(planID: String, choices: [Choice], protected: Bool, surfaceID: String, update: Bool = false,
                      note: String? = nil, settingsPane: String? = nil) -> [[String: Any]] {
        var card = Card(surfaceID: surfaceID, idPrefix: update ? "again-" : "")
        card.heading("让螺壳搜索搜哪些地方")
        card.text("勾上要搜的，点「好」以后在后台慢慢建索引。")
        for choice in choices { card.checkbox(choice.key, label: choice.label, value: choice.on) }
        if protected { card.text("macOS 会先问你让不让读这几个文件夹。", caption: true) }
        if let note { card.text(note, caption: true) }
        let apply = Card.Button("好", event: "search_settings_apply",
                                context: ["plan_id": planID, "checks": ["path": "/checks"]], primary: true)
        if let settingsPane {
            card.buttons(apply, Card.Button("打开系统设置", event: "search_open_system_settings",
                                            context: ["pane": settingsPane]),
                         Card.Button("算了", event: "agent.dismiss"))
        } else {
            card.buttons(apply, Card.Button("算了", event: "agent.dismiss"))
        }
        return update ? card.updateMessages(data: false) : card.messages()
    }

    /// macOS doesn't let luoke-search read somewhere: where to allow it, and a button to open that place. `dismiss`:
    /// 「算了」 too (Photos refused: the user may leave it at that, and the card would otherwise stay for good).
    static func needsAccess(_ what: String, pane: String, surfaceID: String, dismiss: Bool = false) -> [[String: Any]] {
        var card = Card(surfaceID: surfaceID)
        card.heading("螺壳搜索读不了「\(what)」")
        card.text(pane == "photos" ? "要在 系统设置 › 隐私与安全性 › 照片 里允许\(LuokeSearch.holder)读取照片。"
                  : "要在 系统设置 › 隐私与安全性 › 文件和文件夹 里允许\(LuokeSearch.holder)读取它。")
        let open = Card.Button("打开系统设置", event: "search_open_system_settings", context: ["pane": pane],
                               primary: true)
        if dismiss { card.buttons(open, Card.Button("算了", event: "agent.dismiss")) } else { card.buttons(open) }
        return card.messages()
    }

    /// Photos on, never asked (§1a): what reading them means, and where to allow it. Nothing here asks macOS: the
    /// permission is luoke's (`owner` in the manifest), and luoke's own program asks in its own window.
    static func askForPhotos(surfaceID: String) -> [[String: Any]] {
        var card = Card(surfaceID: surfaceID)
        card.heading("螺壳搜索要你允许读「照片」")
        card.text("你让螺壳搜索也搜照片图库里的照片和视频。点「允许」，螺壳会问你。")
        card.text("只读，不修改图库；不从 iCloud 下载；数据不离开本机。", caption: true)
        // luoke's window takes this button (`host_ask`); with no such window it opens the same page as the other card
        card.buttons(Card.Button("允许", event: "search_open_system_settings", context: ["pane": "photos"], primary: true),
                     Card.Button("算了", event: "agent.dismiss"))
        return card.messages()
    }

    /// Folders the page lists, each on its own line: beyond them, how many more (a card holds 200 components).
    static let maxFoldersShown = 20
    /// The same for the home folder's own folders (「跳过」), the skipped ones and the disks offered.
    static let maxInHomeShown = 10, maxSkippedShown = 5, maxDisksShown = 3

    /// A folder on the app's page: what the user knows it as, and what a 「不搜了」 tap carries (`folderID`).
    typealias PageFolder = (name: String, id: String)

    /// The app's page (`SearchService.overview`). `photos`: `status()`'s word for them. `photosRefused`: macOS was
    /// asked and said no, so it won't ask again. `changeable`: something's been chosen, so the page may change the
    /// settings (the Photos switch, 「不搜了」).
    /// `inHome`: the folders right in a searched home folder (each with 「跳过」); `skipped`: the folders skipped (each
    /// with 「不跳过了」); `disks`: disks plugged in and not searched (「也搜这块盘」, carrying the disk's UUID).
    static func overview(exact: SearchState, semantic: SearchState, note: String?, folders: [PageFolder],
                         inHome: [PageFolder] = [], skipped: [PageFolder] = [], disks: [PageFolder] = [], photos: String,
                         photosRefused: Bool = false, lastRead: Double?, changeable: Bool) -> [[String: Any]] {
        var card = Card(surfaceID: SearchService.overviewPage, gap: 12)
        card.line("精确搜索", exact.text, progress: exact.progress)
        card.divider()
        card.line("语义搜索", semantic.text, progress: semantic.progress)
        if let note { card.text(note, caption: true) }
        card.divider()

        // Each folder on a line of its own, with 「不搜了」 once something's chosen (before that the setup card asks, and
        // a change here would end it: `flipPhotos`). The tap names the folder by its id, looked up in the settings
        // again (`stopSearching`).
        card.line("文件夹", folders.isEmpty ? "还没选" : "\(folders.count) 个")
        for folder in folders.prefix(maxFoldersShown) {
            card.line(folder.name, nil, buttons: changeable ? [
                Card.Button("不搜了", event: "search_settings_apply", context: ["folder": folder.id])] : [])
        }
        if folders.count > maxFoldersShown {
            card.text("还有 \(folders.count - maxFoldersShown) 个没列出；要不搜哪个，在对话里说", caption: true)
        }
        card.divider()

        // The home folder's own folders, each skippable, and what's skipped, each searchable again (11-10).
        if changeable, !inHome.isEmpty {
            card.line("个人文件夹里", "不想搜的可以跳过")
            for folder in inHome.prefix(maxInHomeShown) {
                card.line(folder.name, nil, buttons: [
                    Card.Button("跳过", event: "search_settings_apply", context: ["skip": folder.id])])
            }
            if inHome.count > maxInHomeShown {
                card.text("还有 \(inHome.count - maxInHomeShown) 个没列出；要跳过哪个，在对话里说", caption: true)
            }
            card.divider()
        }
        if changeable, !skipped.isEmpty {
            card.line("跳过的", "\(skipped.count) 个")
            for folder in skipped.prefix(maxSkippedShown) {
                card.line(folder.name, nil, buttons: [
                    Card.Button("不跳过了", event: "search_settings_apply", context: ["unskip": folder.id])])
            }
            if skipped.count > maxSkippedShown {
                card.text("还有 \(skipped.count - maxSkippedShown) 个没列出；要改的话，在对话里说", caption: true)
            }
            card.divider()
        }
        // Disks plugged in: not searched until the user says so (11-10).
        if changeable, !disks.isEmpty {
            card.line("外接盘", "默认不搜")
            for disk in disks.prefix(maxDisksShown) {
                card.line(disk.name, nil, buttons: [
                    Card.Button("也搜这块盘", event: "search_settings_apply", context: ["disk": disk.id])])
            }
            if disks.count > maxDisksShown {
                card.text("还有 \(disks.count - maxDisksShown) 块没列出；先拔掉不用的再来点", caption: true)
            }
            card.divider()
        }

        let on = photos != "off"
        // Chosen but not allowed: what to do about it, on the line that says photos are searched. The permission is
        // luoke's (`owner` in the manifest): `permission` marks the button for its window, which asks in its own
        // window (`host_ask`); with no such window it opens the same page as the other card.
        let allow = !on || photos == "on" ? [] : [
            Card.Button(photosRefused ? "去系统设置" : "允许", event: "search_open_system_settings",
                        context: ["pane": "photos", "permission": "photos"])]
        if changeable {
            card.line("搜照片图库", nil, buttons: allow + [
                // Turning it on needs the permission first (`needs`): luoke asks for what's missing, then this runs.
                Card.Button(on ? "不再搜照片" : "也搜照片", event: "search_settings_apply",
                            context: on ? ["photos": false] : ["photos": true, "needs": "photos"], switchedOn: on)])
        } else {
            card.line("搜照片图库", allow.isEmpty ? (on ? "开" : "关") : nil, buttons: allow)
        }
        card.divider()

        card.line("最近读入", lastRead.map(moment) ?? "还没有")
        return card.messages()
    }

    /// A day and a moment as people say them, on this Mac's clock.
    static func day(_ seconds: Double) -> String {
        let date = Calendar.current.dateComponents([.month, .day], from: Date(timeIntervalSince1970: seconds))
        return "\(date.month ?? 0) 月 \(date.day ?? 0) 日"
    }

    static func moment(_ seconds: Double) -> String {
        let time = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: seconds))
        return day(seconds) + String(format: " %02d:%02d", time.hour ?? 0, time.minute ?? 0)
    }

    static func done(_ text: String, surfaceID: String, idPrefix: String) -> [[String: Any]] {
        var card = Card(surfaceID: surfaceID, idPrefix: idPrefix)
        card.text(text)
        return card.updateMessages()
    }

    static func note(_ title: String, _ body: String, surfaceID: String) -> [[String: Any]] {
        var card = Card(surfaceID: surfaceID)
        card.heading(title)
        card.text(body)
        return card.messages()
    }
}

extension ItemKind {
    /// What to call the kind in a sentence for the user.
    public var label: String {
        switch self {
        case .doc: "文档"
        case .pdf: "PDF"
        case .screenshot: "截图"
        case .image: "图片"
        case .video: "视频"
        case .audio: "录音"
        case .photo: "照片"
        }
    }
}
