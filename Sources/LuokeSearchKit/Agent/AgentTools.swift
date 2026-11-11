import Foundation

/// luoke-search's MCP tools and outbox (agent tool protocol version 1; luoke-agent#1 agreed on them). The
/// manifest's `capabilities` list the reports, the actions that need the user's tap, and what the window shows
/// besides cards (§1a, luoke-agent#3: a summary, one base page and the Photos permission; no window of its own), and
/// which action the window's global search calls (§1b: `search_query`, its `hits` in the window's shape).
public enum AgentTools {
    public static let outboxURI = "luoke://luoke-search/outbox"

    /// For the accessory manifest (`Contents/Resources/luoke-accessory.json`).
    public static var manifestCapabilities: [String: Any] { [
        "protocol": 1,
        "socket": "~/.luoke-search/run/agent.sock",
        "reports": [
            ["kind": "needs-setup", "title": "螺壳搜索还没选要搜的地方", "urgency": "normal"],
            ["kind": "needs-access", "title": "螺壳搜索需要你允许读取", "urgency": "low"],
            ["kind": "index-ready", "title": "第一遍索引建好了", "urgency": "low"],
        ],
        "actions": [
            ["name": "search_settings_apply", "title": "改螺壳搜索的设置（搜哪些地方、跳过哪些、要不要外接盘和照片图库）", "writes": true],
            ["name": "search_open", "title": "在 Mac 上打开搜到的文件，或在访达中显示", "writes": true],
        ],
        "service": ["summary": true, "pages": [["id": SearchService.overviewPage, "title": "概览"]],
                    "ask": ["search": "search_query"]],
        "permissions": [
            ["id": "photos", "kind": "system", "owner": "luoke", "tcc": "Photos", "title": "照片图库",
             "facts": ["仅在开启照片搜索时读取", "只读，不修改图库", "不从 iCloud 下载",
                       "数据不离开本机"],
             "without": "degrade"],
            ["id": "folders", "kind": "each-time", "title": "读你的个人文件夹和 iCloud 云盘",
             "facts": ["默认读个人文件夹和 iCloud 云盘，可以去掉", "外接盘要你点了才读", "首次读取时由 macOS 询问", "数据不离开本机"]],
            ["id": "quicktime", "kind": "each-time", "title": "让 QuickTime Player 跳到视频的那一秒",
             "facts": ["仅在播放视频片段时使用", "首次使用时由 macOS 询问"]],
        ],
        "listing": ["tagline": "在这台 Mac 上找文件和照片，答案带出处", "category": "效率"],
    ] }

    /// `sheet` is the window's kind for spreadsheets (`windowHit`); the index files them under `doc`, so it filters as `doc`.
    static let kinds = ItemKind.allCases.map(\.rawValue) + [sheetKind]

    /// The window's filter by where results are from; a video file is a file, a video in the library is `photos`.
    static var sourcesSchema: [String: Any] { [
        "type": "array", "items": ["type": "string", "enum": ItemSource.allCases.map(\.rawValue)],
        "description": "只要这几处的（筛选）：files 是选的文件夹里的文件，photos 是照片图库",
    ] }

    /// `sources` as given; nil (every source) when it names none this tool knows.
    static func sources(_ arguments: [String: Any]) -> Set<ItemSource>? {
        let parsed = (arguments["sources"] as? [String] ?? []).compactMap(ItemSource.init(rawValue:))
        return parsed.isEmpty ? nil : Set(parsed)
    }

    public static func server(_ service: SearchService) -> MCPServer {
        let server = MCPServer(name: LuokeSearch.accessory, version: LuokeSearch.version)

        server.add(MCPServer.Tool(
            name: "search_query", title: "在这台 Mac 上找文件和照片",
            description: """
                按字词和按意思搜用户这台 Mac 上的文件（文档、PDF 含扫描件、截图、图片、视频、录音）。用户要找一份文件、\
                一张照片或截图、某份文档里写的内容、某段录音或视频时用。时间范围（"上个月"）请换成 since / until 传进来；\
                只给时间（或只给类型、来源）不给 query，列出最新的。\
                答复里每条结果有出处（第几页、第几秒）和片段；片段和标题里的密码、验证码、密钥遮成〔密码〕这样，\
                卡号、证件号只留后 4 位（〔卡号 ****1111〕）；\
                strong 为真表示这条本身就很对得上（名字里有要找的字，或意思很近），不看它排第几；为假的是可能相关、不一定是答案；confident 为 false 表示没找到，为 null 表示有结果但还说不准；\
                skipped 列出这次没搜或没搜全的地方（照片还没允许、拒绝过、没开搜照片图库）；\
                totals 是各来源一共对上几条（files、photos，不受 limit 和 sources 限制）。
                """,
            schema: ["type": "object", "properties": [
                "query": ["type": "string", "description": "用户的原话，或改写过的；只按时间或类型列出时可以不带"],
                "kinds": ["type": "array", "items": ["type": "string", "enum": kinds], "description": "只要这几类（筛选）；sheet（表格：xlsx、csv、tsv）算在 doc 里，筛的是全部 doc"],
                "sources": sourcesSchema,
                "since": ["type": "string", "description": "ISO 8601 日期或时间：条目的时间不早于它（拍摄时间，没有就按修改时间）"],
                "until": ["type": "string", "description": "ISO 8601 日期或时间：不晚于它"],
                "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "最多几条，默认 10"],
            ] as [String: Any]]) { arguments, _ in
                // The window's global search may give only a time (§1b): no words, or none at all, is fine then.
                let given = arguments["query"] ?? NSNull()
                guard given is NSNull || given is String else { throw ToolFailure("invalid", "要搜什么？") }
                let query = given as? String ?? ""
                var options = SearchOptions(limit: min(max((arguments["limit"] as? Int) ?? 10, 1), 50))
                if let kinds = arguments["kinds"] as? [String] {
                    let parsed = kinds.compactMap { ItemKind(rawValue: $0 == sheetKind ? ItemKind.doc.rawValue : $0) }
                    if !parsed.isEmpty { options.kinds = Set(parsed) }
                }
                options.sources = sources(arguments)
                options.since = try (arguments["since"] as? String).map { try date($0, endOfDay: false) }
                options.until = try (arguments["until"] as? String).map { try date($0, endOfDay: true) }
                if Searcher.isBlank(query), options.since == nil, options.until == nil, options.kinds == nil,
                   options.sources == nil {
                    throw ToolFailure("invalid", "要搜什么？")
                }
                let answer = try service.search(query, options: options)
                var structured = try json(answer)
                structured["hits"] = try answer.hits.map { try windowHit($0) }
                // Nothing found: which folders were looked in, on the card and for the model (it may offer to add one).
                let searched = answer.hits.isEmpty ? service.searchedNote(sources: options.sources) : nil
                structured["card"] = Cards.results(answer, query: query, searched: searched,
                                                   surfaceID: "q-" + UUID().uuidString.prefix(8).lowercased())
                // What wasn't looked in (the window's row under the results): an empty list, not missing.
                let skipped = service.skippedSources(kinds: options.kinds, sources: options.sources)
                structured["skipped"] = skipped
                return (summary(answer) + (searched.map { "\n（\($0)）" } ?? "") + SearchService.skippedSentence(skipped),
                        structured)
            })

        // What else is like a result: read-only, only vectors already in the index. Not a button on the window's hits:
        // a hit's button answers in one sentence (agent tool protocol §1b), and this one answers with new results.
        server.add(MCPServer.Tool(
            name: "search_similar", title: "找和一条结果相似的",
            description: """
                按 search_query 给的编号，找这台 Mac 上和那条结果意思或画面相近的别的文件和照片（只用已经算好的向量，\
                不再问螺壳）。编号指到第几页、第几秒时，按那一处找。答复和 search_query 一样：hits、片段遮凭证、\
                skipped、totals，sources 也一样能筛；那条还没算出向量时 hits 为空，partial_reason 说明。
                """,
            schema: ["type": "object", "required": ["id"], "properties": [
                "id": ["type": "string", "description": "search_query 结果里的 id"],
                "sources": sourcesSchema,
                "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "最多几条，默认 10"],
            ] as [String: Any]]) { arguments, _ in
                guard let id = arguments["id"] as? String else { throw ToolFailure("invalid", "缺少编号") }
                let options = SearchOptions(sources: sources(arguments),
                                            limit: min(max((arguments["limit"] as? Int) ?? 10, 1), 50))
                guard let answer = try service.similar(id, options: options) else {
                    throw ToolFailure("stale", "这条结果已经不在索引里了。")
                }
                var structured = try json(answer)
                structured["hits"] = try answer.hits.map { try windowHit($0) }
                structured["card"] = Cards.results(answer, query: "",
                                                   surfaceID: "q-" + UUID().uuidString.prefix(8).lowercased())
                // The same shape as a search's: the window redraws its list, the row under it included.
                let skipped = service.skippedSources(kinds: nil, sources: options.sources)
                structured["skipped"] = skipped
                let text = answer.hits.isEmpty && answer.partialReason != nil
                    ? answer.partialReason! + "。" : summary(answer)
                return (text + SearchService.skippedSentence(skipped), structured)
            })

        // Opening hands the file to its default app, which may go online (an .html, an .svg): only on the user's tap
        // (§5), never on the agent's own say (luoke-audit#25 §8, luoke-agent#3).
        server.add(MCPServer.Tool(
            name: "search_open", title: "在 Mac 上打开一条结果",
            description: "按 search_query 给的编号在 Mac 上打开文件（视频、录音从那一刻开始），reveal 为真时在访达中显示。只在 Mac 上有用。只在用户在卡片上点了以后调。",
            schema: ["type": "object", "required": ["id"], "properties": [
                "id": ["type": "string", "description": "search_query 结果里的 id"],
                "reveal": ["type": "boolean", "description": "在访达中显示，而不是打开"],
            ] as [String: Any]],
            readOnly: false, meta: ["ai.luoke/where": "mac"]) { arguments, _ in
                guard let id = arguments["id"] as? String else { throw ToolFailure("invalid", "缺少编号") }
                return (try service.open(id, reveal: arguments["reveal"] as? Bool ?? false), [:])
            })

        server.add(MCPServer.Tool(
            name: "search_status", title: "螺壳搜索的状态",
            description: "索引了多少、还在等什么（停着的说为什么：在用电池、螺壳暂停了后台等）、螺壳能不能算向量、在搜哪些文件夹。",
            schema: ["type": "object", "properties": [String: Any]()]) { _, _ in
                let status = try service.status()
                return (service.statusSentence(status), status)
            })

        server.add(MCPServer.Tool(
            name: "search_settings", title: "看或提议改螺壳搜索的设置",
            description: """
                不带 change：答复现在的设置（搜哪些地方、跳过哪些、要不要照片图库、用电池时建不建索引：默认不建，\
                连着螺壳时听螺壳的电池设置）。默认搜整个个人文件夹和 iCloud 云盘。带 change：\
                出一个方案和一张确认卡片，用户在卡片上点了"好"才会改（search_settings_apply）。文件夹可以写路径，\
                也可以写 home（个人文件夹）、icloud（iCloud 云盘）、desktop、documents、downloads、pictures、movies、music。\
                不想搜个人文件夹里的某个文件夹，用 skip_folders；跳过的再搜，用 unskip_folders。\
                外接盘要用户在螺壳搜索的页面上点「也搜这块盘」；不搜了可以写在 remove_folders 里（写盘的路径）。
                """,
            schema: ["type": "object", "properties": [
                "change": ["type": "object", "properties": [
                    "add_folders": ["type": "array", "items": ["type": "string"]],
                    "remove_folders": ["type": "array", "items": ["type": "string"]],
                    "skip_folders": ["type": "array", "items": ["type": "string"]],
                    "unskip_folders": ["type": "array", "items": ["type": "string"]],
                    "photos": ["type": "boolean"],
                    "on_battery": ["type": "boolean"],
                ] as [String: Any]],
            ] as [String: Any]]) { arguments, _ in
                let settings = Settings.load(service.directory)
                guard let raw = arguments["change"] as? [String: Any] else {
                    // By the names the user knows, without asking Finder (it may look inside a protected folder).
                    let folders = settings.searched(restricted: service.restrictFolders, home: service.home)
                        .map(service.quietName).joined(separator: "、")
                    let skipped = settings.skipFolders.map(service.quietName).joined(separator: "、")
                    return ("现在搜\(folders.isEmpty ? "的文件夹还没选" : "：\(folders)")"
                            + (skipped.isEmpty ? "" : "；跳过：\(skipped)")
                            + "；照片图库\(settings.photos ? "开着" : "没开")。",
                            ["settings": try json(settings)])
                }
                var change = SearchService.Change()
                change.addFolders = raw["add_folders"] as? [String] ?? []
                change.removeFolders = raw["remove_folders"] as? [String] ?? []
                change.skipFolders = raw["skip_folders"] as? [String] ?? []
                change.unskipFolders = raw["unskip_folders"] as? [String] ?? []
                change.photos = raw["photos"] as? Bool
                change.onBattery = raw["on_battery"] as? Bool
                let (plan, lines) = try service.plan(change)
                guard !plan.isEmpty else { return ("设置本来就是这样，不用改。", ["settings": try json(settings)]) }
                let card = Cards.plan(plan, lines: lines, surfaceID: "s-" + plan.id)
                return ("打算这样改：" + lines.map(\.text).joined(separator: "；") + "。要你在卡片上点「好」。",
                        ["plan_id": plan.id, "changes": lines.map(\.text), "card": card])
            })

        server.add(MCPServer.Tool(
            name: "search_settings_apply", title: "改螺壳搜索的设置",
            description: "执行 search_settings 出的方案（或 outbox 里\"还没选要搜的地方\"那张卡片上的）。只在用户在卡片上点了以后调。"
                + "不带 plan_id、带 photos、folder、skip、unskip 或 disk：螺壳搜索页面上的开关、「不搜了」「跳过」「不跳过了」「也搜这块盘」，只在用户在页面上点了以后调；"
                + "用户在对话里要改设置，用 search_settings。",
            schema: ["type": "object", "properties": [
                "plan_id": ["type": "string"],
                "photos": ["type": "boolean", "description": "页面上的开关：搜不搜照片图库"],
                "folder": ["type": "string", "description": "页面上的「不搜了」：按钮带的文件夹编号"],
                "skip": ["type": "string", "description": "页面上的「跳过」：按钮带的文件夹编号"],
                "unskip": ["type": "string", "description": "页面上的「不跳过了」：按钮带的文件夹编号"],
                "disk": ["type": "string", "description": "页面上的「也搜这块盘」：按钮带的盘的编号"],
                "checks": ["type": "object", "additionalProperties": ["type": "boolean"],
                           "description": "卡片上勾选框的值（只有带勾选框的方案才有）"],
            ] as [String: Any]],
            readOnly: false) { arguments, meta in
                let taps = ["photos", "folder", "skip", "unskip", "disk"].filter { arguments[$0] != nil }
                if arguments["plan_id"] == nil, taps.count > 1 {
                    throw ToolFailure("invalid", "页面上一次只点一个。")
                }
                for key in ["skip", "unskip", "disk"] where arguments["plan_id"] == nil && arguments[key] != nil {
                    guard let id = arguments[key] as? String, !id.isEmpty, id.utf8.count <= 64 else {
                        throw ToolFailure("invalid", "页面上点的是哪一个？")
                    }
                    let surface = (meta[MCPServer.userAction] as? [String: Any])?["surfaceId"] as? String
                    let text = switch key {
                    case "skip": try service.skipFolder(id, surfaceID: surface)
                    case "unskip": try service.unskipFolder(id, surfaceID: surface)
                    default: try service.searchDisk(id, surfaceID: surface)
                    }
                    return (text, ["done": true])
                }
                if arguments["plan_id"] == nil, let on = arguments["photos"] as? Bool {
                    let surface = (meta[MCPServer.userAction] as? [String: Any])?["surfaceId"] as? String
                    return (try service.flipPhotos(on, surfaceID: surface), ["done": true])
                }
                if arguments["plan_id"] == nil, let given = arguments["folder"] {
                    guard let folder = given as? String, !folder.isEmpty, folder.utf8.count <= 64 else {
                        throw ToolFailure("invalid", "要不搜哪个文件夹？")
                    }
                    let surface = (meta[MCPServer.userAction] as? [String: Any])?["surfaceId"] as? String
                    return (try service.stopSearching(folder, surfaceID: surface), ["done": true])
                }
                guard let planID = arguments["plan_id"] as? String else { throw ToolFailure("invalid", "缺少方案编号") }
                var ticks: [String: Bool] = [:]
                if let given = arguments["checks"] {
                    guard let given = given as? [String: Any] else { throw ToolFailure("invalid", "勾选要是一组真假") }
                    for (key, value) in given {
                        guard let on = value as? Bool else { throw ToolFailure("invalid", "勾选要是一组真假") }
                        ticks[key] = on
                    }
                }
                let surface = (meta[MCPServer.userAction] as? [String: Any])?["surfaceId"] as? String
                let text = try service.apply(planID: planID, surfaceID: surface, ticks: ticks)
                var structured: [String: Any] = ["done": true]
                if let surface { structured["card"] = Cards.done(text, surfaceID: surface, idPrefix: "done-") }
                return (text, structured)
            })

        server.add(MCPServer.Tool(
            name: "search_open_system_settings", title: "打开系统设置里的隐私页",
            description: "打开 macOS 系统设置里允许读取的地方：files（文件和文件夹）、full_disk（完全磁盘访问权限）、photos（照片）。",
            schema: ["type": "object", "properties": [
                "pane": ["type": "string", "enum": ["files", "full_disk", "photos"]],
            ] as [String: Any]],
            meta: ["ai.luoke/where": "mac"]) { arguments, _ in
                let pane = arguments["pane"] as? String ?? "files"
                let anchor = ["files": "Privacy_FilesAndFolders", "full_disk": "Privacy_AllFiles",
                              "photos": "Privacy_Photos"][pane] ?? "Privacy_FilesAndFolders"
                service.opener.openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
                return (service.opener.isDry ? "已打开系统设置。（演习）" : "已打开系统设置。", [:])
            })

        server.add(MCPServer.Tool(
            name: "outbox_ack", title: "outbox 里的一件事说过了",
            description: "agent 告诉螺壳搜索 outbox 里的一件事已经给用户看过（shown）、答过（answered）或放下了（dismissed）。",
            schema: ["type": "object", "required": ["id", "state"], "properties": [
                "id": ["type": "string"],
                "state": ["type": "string", "enum": ["shown", "answered", "dismissed"]],
            ] as [String: Any]]) { arguments, _ in
                try service.acknowledge(arguments["id"] as? String ?? "", state: arguments["state"] as? String ?? "")
                return ("记下了。", [:])
            })

        server.add(MCPServer.Resource(uri: outboxURI, name: "螺壳搜索想告诉你的事") { service.outbox() })
        // §1a: relative ids, the outbox under both.
        server.add(MCPServer.Resource(uri: "outbox", name: "螺壳搜索想告诉你的事") { service.outbox() })
        server.add(MCPServer.Resource(uri: "summary", name: "概况") { service.summary() })
        server.add(MCPServer.Resource(uri: "permissions", name: "权限的状态") { service.permissionStates() })
        server.add(MCPServer.Resource(uri: "page/" + SearchService.overviewPage, name: "概览") { try service.overview() })
        server.add(MCPServer.Blobs(prefix: SearchService.thumbPrefix, mimeType: "image/jpeg") { service.findThumb($0) })
        return server
    }

    /// The window's kind for a table (`Rules.isSheet`): not one of `ItemKind`, so not a filter of `search_query`.
    static let sheetKind = "sheet"

    /// One result as the window's list draws it (§1b): ours as it was, plus which part of luoke-search it's from (the
    /// window's filter), its kind as the user calls it, a line of where in it, its thumbnail if it has one, and its
    /// buttons: opening it and showing it in Finder only. A hit's button answers in one sentence (agent tool protocol
    /// §1b), so 「找相似的」, which answers with new results, isn't one.
    static func windowHit(_ hit: Hit) throws -> [String: Any] {
        var shaped = try json(hit)
        shaped["source"] = hit.path == nil ? "photos" : "files"
        // What kind it is, as the user calls it ("截图"): the window can't tell from `kind`, and shows it where the
        // name doesn't say. A table is a document to the index, and its own kind to the window (「表格」).
        shaped["kind_label"] = hit.kind.label
        if hit.kind == .doc, let path = hit.path, Rules.isSheet(path) {
            shaped["kind"] = sheetKind
            shaped["kind_label"] = "表格"
        }
        if let line = hit.where.flatMap(Cards.place) { shaped["line"] = line }
        if let thumb = SearchService.thumbID(hit) { shaped["thumb"] = thumb }
        shaped["actions"] = Cards.openings(hit).enumerated().map { index, opening in
            ["name": "search_open", "title": opening.label, "args": opening.args, "primary": index == 0]
        }
        return shaped
    }

    /// A few lines of plain text for the answer's `content`: what was found, where.
    static func summary(_ answer: SearchAnswer) -> String {
        guard !answer.hits.isEmpty else {
            return "没有找到对得上的。" + (answer.partialReason.map { "（\($0)）" } ?? "")
        }
        var lines = ["找到 \(answer.hits.count) 条："]
        for (rank, hit) in answer.hits.prefix(3).enumerated() {
            var line = "\(rank + 1). \(hit.title)"
            if let place = hit.where.flatMap(Cards.place) { line += "（\(place)）" }
            if let snippet = hit.snippet { line += "：\(snippet)" }
            lines.append(line)
        }
        if let reason = answer.partialReason { lines.append("（\(reason)）") }
        return lines.joined(separator: "\n")
    }

    static func json<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    /// "2026-09-01" (the start of that day, or its end), a full ISO 8601 time, or one without its zone
    /// ("2026-09-01T10:00:00", "2026-09-01T10:00": this Mac's time), not taken for the whole day.
    public static func date(_ text: String, endOfDay: Bool) throws -> Double {
        if let date = try? Date(text, strategy: .iso8601) { return date.timeIntervalSince1970 }
        let local = Date.ISO8601FormatStyle(timeZone: .current).year().month().day().time(includingFractionalSeconds: false)
        let minutes = text.count == 16 && text.dropFirst(10).first == "T" ? text + ":00" : text
        if let date = try? Date(minutes, strategy: local) { return date.timeIntervalSince1970 }
        let day = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        guard text.count == 10, let date = try? Date(text, strategy: day) else {
            throw ToolFailure("invalid", "看不懂的日期：\(MCPServer.shown(text))")
        }
        return date.timeIntervalSince1970 + (endOfDay ? 86_400 - 0.001 : 0)
    }
}
