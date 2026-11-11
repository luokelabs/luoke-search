import Foundation
import LuokeSearchKit

// luoke-search: the command line. Every command takes `--index DIR` (the data directory; default ~/.luoke-search,
// or $LUOKE_SEARCH_HOME). Development and tests always pass their own (.dev/<name>), never the real one.
//
// luoke-core: `$LUOKE_HUB_SOCKET`, else — for the real data directory only — the installed hub's socket. A run with its
// own `--index` and no `LUOKE_HUB_SOCKET` doesn't ask any hub: it reads and searches by words only.

let usage = """
    用法：
      luoke-search index <文件夹>... [--exclude 文件夹]... [--prune] [--wait] [--no-vectors] [--allow-battery] [--json]
      luoke-search search <问题> [--kind 类型]... [-n 10] [--since 日期] [--until 日期] [--json]
      luoke-search status [--json]
      luoke-search eval <题库.json>... [--testbed 文件夹] [-n 10] [--refusal | --hits] [--scoring a|b|d|c<k>]
                        [--no-cutoff] [--timing] [--json]
                                            --refusal：量拒答门槛（题库里 expect 为空的是"没有答案"的题）
                                            --hits：每题每条结果的分数、z、余弦、字词占比和对错（JSON）
                                            --no-cutoff：用 11-09 以前的门槛（问照片时 z ≥ 1、没有余弦门槛、
                                                         不去掉不到第一名一半的），只供对比
                                            --scoring：按意思打分的做法，只供对比
                                            --timing：每题搜索的用时（p50 / p90 / 最长，打在 stderr）
      luoke-search open <结果编号> [--reveal]
      luoke-search settings [--add-folder 文件夹]... [--remove-folder 文件夹]... [--skip-folder 文件夹]...
                            [--photos on|off] [--on-battery on|off] [--json]
      luoke-search mcp                      在标准输入输出上提供 MCP（任何 MCP 客户端都能接）
      luoke-search serve [--socket 路径] [--no-watch] [--resident] [--parent-pid 进程号]
                                            在 <数据目录>/run/agent.sock 上给螺壳提供 MCP，并跟着文件夹的变化更新索引
      luoke-search index --job              第一遍建索引（给螺壳的空闲任务用：能停能续，SIGTERM 停在做完的那一步）
      luoke-search photos-probe [--access] [--sample 2000] [--originals 300]
                                            只出汇总数字：这台 Mac 的照片图库能给螺壳搜索多少（真图库测试用；
                                            只在开发版 app 里或设了 LUOKE_SEARCH_PHOTOS=system 时能用，发布版不做；
                                            不问权限，不从 iCloud 下载）
      luoke-search probe-audio <题库.json>... [--testbed 文件夹] [--transcripts 文件] [--json]
                                            问录音的题：每个窗口送了什么、余弦、排第几、写成文字又如何（要连螺壳）
    index 不给文件夹时，搜设置里的文件夹。
    每条命令都可以加 --index <数据目录>（默认 ~/.luoke-search）。

    类型：doc pdf screenshot image video audio photo
    日期：2026-09-01 或 2026-09-01T10:00:00+08:00
    """

typealias Arguments = CommandArguments

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A path made absolute without requiring it to exist yet.
func absolute(_ path: String) -> String { CommandArguments.absolute(path) }

func printJSON<T: Encodable>(_ value: T) throws {
    print(try JSONOutput.string(value))
}

/// "2026-09-01" (the start of that day, or its end for `--until`) or a full ISO 8601 time.
func parseDate(_ text: String, endOfDay: Bool) throws -> Double {
    if let date = try? Date(text, strategy: .iso8601) { return date.timeIntervalSince1970 }
    let day = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
    guard let date = try? Date(text, strategy: day) else { throw Failure("看不懂的日期：\(text)") }
    return date.timeIntervalSince1970 + (endOfDay ? 86_400 - 0.001 : 0)
}

func describe(_ error: HubError) -> String {
    switch error {
    case .refused(let code, let reason, let retryAfter):
        return "螺壳现在没空（\(code)\(reason.map { "，\($0)" } ?? "")），\(retryAfter.map { "\(Int($0.rounded(.up))) 秒后" } ?? "过一会儿")再补"
    default:
        return QueryMeaning.note(error).replacingOccurrences(of: "，只按字词搜", with: "")
    }
}

// MARK: Commands

func index(_ arguments: Arguments) throws {
    try arguments.only(["--index", "--exclude", "--prune", "--wait", "--no-vectors", "--allow-battery", "--json", "--job"])
    if arguments.flags.contains("--job") { try job(arguments) }
    let directory = try arguments.dataDirectory()
    guard let settings = Settings.read(directory) else { throw Failure(Settings.unreadable) }
    let folders = arguments.positional.isEmpty ? settings.searched(restricted: arguments.shipped) : arguments.positional
    guard !folders.isEmpty else {
        throw Failure("还没选要搜的文件夹：给出文件夹，或者先 luoke-search settings --add-folder <文件夹>")
    }
    let store = try IndexStore(directory: directory)
    let indexer = Indexer(store: store, crawler: Crawler(excludedFolders: arguments.values("--exclude")
                                                        + (arguments.positional.isEmpty ? settings.skipFolders : [])))
    let watchdog = ReadWatchdog(directory: directory)
    watchdog.start()
    indexer.watchdog = watchdog
    if arguments.positional.isEmpty { indexer.readFirst = Indexer.usualFirst() }
    try indexer.noteStopped(directory)
    let json = arguments.json
    var report = try indexer.sync(folders)
    if arguments.flags.contains("--prune") || arguments.positional.isEmpty {
        report.removed += try indexer.prune(keeping: arguments.positional.isEmpty ? settings.keptRoots(restricted: arguments.shipped) : folders)
    }
    if !json {
        print("同步：新 \(report.added)，改过 \(report.changed)，移动 \(report.moved)，删掉 \(report.removed)，没变 \(report.unchanged)")
        for root in report.unreachable { print("读不了：\(root)") }
        for (reason, count) in report.skipped.sorted(by: { $0.key < $1.key }) { print("跳过 \(count) 个：\(reason)") }
    }
    var failed = 0
    let read = try indexer.readPending(progress: { item, reading in
        guard !json else { return }
        switch reading.outcome {
        case .done: print("读了 \(item.kind.rawValue)  \(item.path)（\(reading.pieces.count) 段）")
        case .failed(let why): failed += 1; print("读不了 \(item.path)：\(why)")
        case .skipped(let why): print("跳过 \(item.path)：\(why)")
        }
    })
    if !json { print("读了 \(read) 个\(failed > 0 ? "，其中 \(failed) 个读不了" : "")。") }
    let away = try store.counts().notOnThisMac
    if !json, away > 0 { print("不在这台 Mac 上 \(away) 个，这次没读（只在 iCloud、盘拔了这些），回到这台 Mac 上再读。") }
    // Long files: the rest of them, now that every file has been read through once.
    let rest = try indexer.readRest()
    if !json, rest > 0 { print("长文件又读了 \(rest) 步（PDF 30 页一步，文档剩下的一步读完）。") }

    var vectors: VectorFiller.Report?
    var vectorNote: String?
    if arguments.flags.contains("--no-vectors") {
        vectorNote = "没有补向量（--no-vectors）"
    } else if let hub = arguments.hub(for: directory) {
        let filler = VectorFiller(store: store, hub: hub)
        filler.watchdog = watchdog
        let filled = filler.run(wait: arguments.flags.contains("--wait"))
        vectors = filled
        vectorNote = filled.stoppedBy.map(describe)
    } else {
        vectorNote = "没有连螺壳（开发时要设 LUOKE_HUB_SOCKET），向量以后再补"
    }
    try ToolState.noteFirstPassAfterIndex(arguments, directory: directory, store: store)
    let counts = try store.counts()
    if json {
        struct Output: Encodable {
            let sync: Indexer.SyncReport
            let read: Int
            let embedded: Int
            let embeddedMedia: Int
            let mediaFailed: Int
            let vectorNote: String?
            let counts: IndexStore.Counts
        }
        return try printJSON(Output(sync: report, read: read, embedded: vectors?.embedded ?? 0,
                                    embeddedMedia: vectors?.embeddedMedia ?? 0, mediaFailed: vectors?.mediaFailed ?? 0,
                                    vectorNote: vectorNote,
                                    counts: counts))
    }
    if let vectors {
        var line = "算了 \(vectors.embedded) 段文字向量"
        if vectors.embeddedMedia > 0 { line += "、\(vectors.embeddedMedia) 个图片和声音向量" }
        if vectors.mediaFailed > 0 { line += "；\(vectors.mediaFailed) 个图片或声音螺壳读不了" }
        print(line + "。")
    }
    if let vectorNote { print("\(vectorNote)；还有 \(counts.waitingForVectors) 段在等向量。") }
}

func searchOptions(_ arguments: Arguments) throws -> SearchOptions {
    var options = SearchOptions(limit: try arguments.count("-n", default: 10))
    let kinds = try arguments.values("--kind").flatMap { $0.split(separator: ",") }.map { name in
        guard let kind = ItemKind(rawValue: String(name)) else { throw Failure("没有这种类型：\(name)") }
        return kind
    }
    if !kinds.isEmpty { options.kinds = Set(kinds) }
    options.since = try arguments.value("--since").map { try parseDate($0, endOfDay: false) }
    options.until = try arguments.value("--until").map { try parseDate($0, endOfDay: true) }
    return options
}

/// Searches as MCP's `search_query` does: the query's vector from luoke-core if it can, words in any case. Without
/// `search_query`'s budget for the vector: a model loading for an eval's first question is waited for.
func runSearch(_ text: String, searcher: Searcher, hub: Hub?, options: SearchOptions) throws -> SearchAnswer {
    let started = Date()
    let (meaning, note) = QueryMeaning.make(text, hub: hub)
    return try searcher.search(text, options: options, meaning: meaning, meaningNote: note, started: started)
}

func search(_ arguments: Arguments) throws {
    try arguments.only(["--index", "--kind", "-n", "--since", "--until", "--json"])
    let text = arguments.positional.joined(separator: " ")
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure("要给一个问题") }
    let directory = try arguments.dataDirectory()
    let store = try IndexStore(directory: directory)
    let answer = try runSearch(text, searcher: Searcher(store: store), hub: arguments.hub(for: directory),
                               options: try searchOptions(arguments))
    if arguments.json { return try printJSON(answer) }
    if answer.hits.isEmpty { print("没有找到对得上的。") }
    for (rank, hit) in answer.hits.enumerated() {
        var line = "\(rank + 1). \(hit.title)  \(hit.kind.rawValue)"
        if let place = hit.where.flatMap(place) { line += " · \(place)" }
        line += " · \(hit.date.prefix(10))"
        print(line)
        if let path = hit.path { print("   \(path)") }
        if let snippet = hit.snippet { print("   \(snippet)") }
        print("   \(hit.why)" + (hit.score > 0 ? " · 分数 \(hit.score)\(hit.strong ? "" : "（可能相关）")" : ""))
    }
    print("（\(answer.tookMs) ms\(answer.partialReason.map { "；\($0)" } ?? "")）")
}

func place(_ location: Location) -> String? {
    if let page = location.page { return "第 \(page) 页" }
    if let part = location.part { return "第 \(part) 部分" }
    if let sheet = location.sheet { return "第 \(sheet) 个工作表" }
    if let time = location.time { return String(format: "%d:%02d", Int(time) / 60, Int(time) % 60) }
    return nil
}

func status(_ arguments: Arguments) throws {
    try arguments.only(["--index", "--json"])
    let directory = try arguments.dataDirectory()
    let store = try IndexStore(directory: directory)
    let counts = try store.counts()
    var hubState = "not_connected", hubNote: String? = "没有连螺壳"
    let hub = arguments.hub(for: directory)
    var background: Hub.Background?, listed: HubTask?
    if let hub {
        do {
            let answer = try hub.tasks()
            listed = answer.task
            background = answer.background
            guard let task = answer.task else { throw HubError.unknownAccessory }
            hubState = task.status.rawValue
            hubNote = task.status == .available ? nil : task.reason
        } catch let error as HubError {
            hubState = { if case .notRunning = error { return "not_running" }; return "unavailable" }()
            hubNote = describe(error)
        }
    }
    let settings = Settings.load(directory)
    // The library as this process sees it (none in a terminal): the app's own resident may see it otherwise, so with
    // only Photos items waiting this can say nothing while the app is held.
    let paused = Resident.paused(store, counts: counts, photos: FirstPass.usable(SystemPhotos.current, settings) != nil,
                                 task: listed, background: background, onBattery: settings.onBattery)
    if arguments.json {
        struct Output: Encodable {
            let index: String
            let bytes: Int64
            let excludedFromBackup: Bool
            let vectorSpace: String?
            let hub: [String: String?]
            let counts: IndexStore.Counts
            let paused: Resident.Paused?
            let datasetFolders: [String: Int]
        }
        return try printJSON(Output(index: store.file.path, bytes: store.size,
                                    excludedFromBackup: DataDirectory.isExcludedFromBackup(directory.url),
                                    vectorSpace: try store.vectorSpace,
                                    hub: ["state": hubState, "note": hubNote], counts: counts, paused: paused,
                                    datasetFolders: try store.datasetFolders()))
    }
    let total = counts.items.values.reduce(0, +)
    print("索引：\(store.file.path)（\(ByteCountFormatter.string(fromByteCount: store.size, countStyle: .file))）")
    print("已索引 \(total) 个：" + counts.items.sorted(by: { $0.key < $1.key }).map { "\($0.key) \($0.value)" }
        .joined(separator: "，"))
    print("等着读 \(counts.waitingToRead)，长文件还没读完 \(counts.waitingForRest)，读不了 \(counts.failed)，跳过 \(counts.skipped)")
    if counts.notOnThisMac > 0 { print("不在这台 Mac 上 \(counts.notOnThisMac) 个（只在 iCloud、盘拔了这些），回到这台 Mac 上再读") }
    print("向量：已有 \(counts.vectors) 段，等文字向量 \(counts.waitingForVectors) 段，等图片和声音 \(counts.waitingForMedia) 个")
    if let paused { print(SearchService.words(paused)) }
    let datasets = try store.datasetFolders()
    if !datasets.isEmpty {
        print("像数据集的文件夹，里面的图片、录音、视频没读（\(datasets.count) 个，共 \(datasets.values.reduce(0, +)) 个文件）：")
        for (folder, files) in datasets.sorted(by: { $0.key < $1.key }) { print("  \(folder)（\(files) 个）") }
    }
    print("螺壳：\(hubState)\(hubNote.map { "（\($0)）" } ?? "")")
    print(DataDirectory.isExcludedFromBackup(directory.url) ? "不进 Time Machine 备份" : "注意：没有排除出 Time Machine")
}

func eval(_ arguments: Arguments) throws {
    try arguments.only(["--index", "--testbed", "-n", "--json", "--refusal", "--hits", "--scoring", "--timing", "--no-cutoff"])
    guard !arguments.positional.isEmpty else { throw Failure("要给题库文件") }
    let directory = try arguments.dataDirectory()
    let searcher = Searcher(store: try IndexStore(directory: directory))
    searcher.cutsWeakHits = !arguments.flags.contains("--no-cutoff")
    if let text = arguments.value("--scoring") {
        guard let scale = MeaningScale(text) else { throw Failure("--scoring 是 a、b、d 或 c 加一个数（如 c20）") }
        searcher.meaningScale = scale
    }
    let hub = arguments.hub(for: directory)
    let limit = try arguments.count("-n", default: 10)
    let testbed = arguments.value("--testbed").map(absolute)
        ?? ProcessInfo.processInfo.environment["LUOKE_SEARCH_TESTBED"]
    if arguments.flags.contains("--hits") {
        guard !arguments.flags.contains("--refusal") else { throw Failure("--hits 和 --refusal 只能用一个") }
        let sets = try arguments.positional.map { try EvalSet.load(URL(fileURLWithPath: absolute($0))) }
        return try printJSON(try Evaluation.hits(sets, testbed: testbed, limit: limit) { query in
            try runSearch(query, searcher: searcher, hub: hub, options: SearchOptions(limit: limit))
        })
    }
    if arguments.flags.contains("--refusal") {
        let sets = try arguments.positional.map { try EvalSet.load(URL(fileURLWithPath: absolute($0))) }
        let report = try Evaluation.refusal(sets, testbed: testbed, limit: limit) { query in
            try runSearch(query, searcher: searcher, hub: hub, options: SearchOptions(limit: limit))
        }
        if arguments.json { return try printJSON(report) }
        func number(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "-" }
        print("== 没有答案的题：最高分、意思 z、余弦（模态）、字词占比、结果（strong）→ 第一条")
        for record in report.records where !record.answerable {
            print("   \(record.q)（\(record.tag ?? "-")）：\(number(record.score))  z \(number(record.z))"
                  + "  余弦 \(number(record.cosine))（\(record.modality ?? "-")）  字词 \(number(record.share))"
                  + "  \(record.hits) 条（\(record.strong)）  → \(record.top ?? "没有结果")")
        }
        let right = report.records.filter { $0.answerable && $0.rank == 1 }.compactMap(\.score).sorted()
        if !right.isEmpty {
            print("== 有答案、第一条就对的 \(right.count) 题：最高分 最低 \(number(right.first))、"
                  + "中位 \(number(right[right.count / 2]))；最低的五个 \(right.prefix(5).map { number($0) }.joined(separator: " "))")
        }
        print("== 规则：没答案的拒了多少（近似题）｜有答案、第一条对却被拒｜有答案被拒")
        for rule in report.rules {
            print("   \(rule.rule)：\(number(rule.refusedWithoutAnswer))（\(number(rule.refusedNearMisses))）"
                  + "｜\(number(rule.wronglyRefused))｜\(number(rule.refusedWithAnswer))")
        }
        return
    }
    var reports: [String: EvalReport] = [:]
    var took: [Int] = []
    for file in arguments.positional {
        let set = try EvalSet.load(URL(fileURLWithPath: absolute(file)))
        let report = try Evaluation.run(set, testbed: testbed, limit: limit) { query in
            let answer = try runSearch(query, searcher: searcher, hub: hub, options: SearchOptions(limit: limit))
            took.append(answer.tookMs)
            return answer
        }
        reports[(file as NSString).lastPathComponent] = report
        guard !arguments.json else { continue }
        print("== \(file)：\(report.all.count) 题  第一名 \(report.all.top1)  前五 \(report.all.top5)  前十 \(report.all.top10)  MRR \(report.all.mrr)")
        for (tag, line) in report.byTag.sorted(by: { $0.key < $1.key }) {
            print("   \(tag)：\(line.count) 题  \(line.top1) / \(line.top5)")
        }
        for miss in report.misses {
            print("   没在第一：\(miss.q)（\(miss.tag ?? "-")）→ \(miss.rank.map { "第 \($0)" } ?? "没找到")；前三：\(miss.top.joined(separator: "、"))")
        }
        for note in report.notes { print("   注意：\(note)") }
    }
    if arguments.flags.contains("--timing"), let first = took.first {
        // The first search also loads the vectors; each one includes asking luoke-core for the question's vector.
        let rest = took.dropFirst().sorted()
        let line = rest.isEmpty ? "用时：只有一题，\(first) ms"
            : "用时：第一题 \(first) ms（含读向量），之后 \(rest.count) 题 p50 \(rest[rest.count / 2]) ms、"
                + "p90 \(rest[min(rest.count - 1, rest.count * 9 / 10)]) ms、最长 \(rest.last!) ms"
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
    if arguments.json { try printJSON(reports) }
}

func open(_ arguments: Arguments) throws {
    try arguments.only(["--index", "--reveal"])
    guard let id = arguments.positional.first else { throw Failure("要给结果编号（search --json 里的 id）") }
    let directory = try arguments.dataDirectory()
    // The library too, where there's one (the app's own program): a Photos item opens Photos (luoke-search#46).
    let service = try SearchService(directory: directory, hub: nil, opener: .current, photos: SystemPhotos.current)
    do {
        print(try service.open(id, reveal: arguments.flags.contains("--reveal")))
    } catch let failure as ToolFailure {
        throw Failure(failure.message)
    }
}

/// The user typing a change (`SettingsCommand`): the app as it ships too, its folders judged as the agent's are.
func settings(_ arguments: Arguments) throws {
    try arguments.only(SettingsCommand.options)
    print(try SettingsCommand.run(arguments, directory: try arguments.dataDirectory()))
}

/// MCP over stdio: one JSON-RPC message a line in, one a line out. Nothing else is written to stdout.
func mcp(_ arguments: Arguments) throws {
    try arguments.only(["--index"])
    let directory = try arguments.dataDirectory()
    let service = try SearchService(directory: directory, hub: arguments.hub(for: directory), opener: .current,
                                    photos: SystemPhotos.current)
    service.restrictFolders = arguments.shipped
    let server = AgentTools.server(service)
    while let line = readLine(strippingNewline: true) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
        guard let answer = server.handle(json: Data(line.utf8)) else { continue }
        FileHandle.standardOutput.write(answer + Data("\n".utf8))
    }
}

/// luoke-search in the background: the agent's socket (agent tool protocol §2) and the resident loop that keeps the
/// index in step with the folders (`Resident`), until SIGTERM or SIGINT. `--resident`: started by 螺壳 (as a child of
/// 螺壳.app, with `--parent-pid`): it tells luoke-core it wants to keep running, and that it's leaving when it quits.
/// `--no-watch`: the socket only. `--parent-pid`: it ends with that process, however that one went, as on SIGTERM.
/// Left running, the next 螺壳 would find this one holding the socket and its own copy couldn't start.
func serve(_ arguments: Arguments) throws {
    if !asApp { try arguments.only(["--index", "--socket", "--no-watch", "--resident", "--parent-pid"]) }
    let parent = try arguments.parentPID()
    let directory = try arguments.dataDirectory()
    try directory.prepare()
    let hub = arguments.hub(for: directory, background: true)
    let openedByCore = arguments.flags.contains("--resident")
    // Signals first: a quit asked for while starting up still ends cleanly (review C-11). The handler runs on the
    // main queue, so only once everything below is set up.
    let running = Running()
    // A peer gone mid-write is an error on that write, never the end of the service (pre-release review, must-fix 1).
    signal(SIGPIPE, SIG_IGN)
    let quit: @Sendable () -> Void = {
        // 螺壳 kills a quit stuck on the item in hand after 5 s, but only while it's there. Set here, whichever way
        // the quit was asked for: a quit in progress holds the main queue, where news of 螺壳 going would come in.
        if parent != nil { DispatchQueue.global().asyncAfter(deadline: .now() + 15) { _exit(0) } }
        // Before waiting for the item in hand: luoke-core kills a quitting accessory after 15 s (螺壳搜索.app; 5 s for the
        // program inside 螺壳), sooner than a long read ends, and then neither the file nor this quit may count as the
        // process ending (luoke-search#65).
        running.watchdog?.noteAskedToStop()
        running.resident?.askToStop()   // no new item while luoke-core is told
        if openedByCore { try? hub?.exiting() }
        running.resident?.stop()
        running.socket?.stop()
        exit(0)
    }
    var sources: [DispatchSourceSignal] = []
    for number in [SIGTERM, SIGINT] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler(handler: quit)
        source.resume()
        sources.append(source)
    }
    let watch = parent.map { ParentWatch(pid: $0, queue: .main, gone: quit) }
    let service = try SearchService(directory: directory, hub: hub, opener: .current, photos: SystemPhotos.current)
    service.restrictFolders = arguments.shipped
    service.judgesAccess = true   // the app's own access, not a terminal's
    service.releaseVectorsWhenIdle(after: 600)
    let server = AgentTools.server(service)
    if arguments.shipped {
        // Only the agent core, with the token 螺壳 gave it, gets answers (FromApp.token); none given: no one does.
        server.needsToken = true
        server.token = FromApp.token
        if FromApp.token == nil {
            FileHandle.standardError.write(Data("luoke-search: 螺壳没给口令，工具 socket 上的请求一律拒\n".utf8))
        }
    }
    let given = arguments.value("--socket").map(absolute)
    let socket = AgentSocket(path: given ?? directory.agentSocket.path, server: server)
    try socket.start()
    running.socket = socket
    Opener.tellHostUp()
    // The path only when given (development): the real one has the user's name in it (review B-23).
    FileHandle.standardError.write(Data("luoke-search: serving MCP on \(given ?? "the agent socket")\n".utf8))
    if !arguments.flags.contains("--no-watch") {
        let loop = try Resident(directory: directory, hub: hub, photos: SystemPhotos.current)
        loop.restrictFolders = arguments.shipped
        let watchdog = ReadWatchdog(directory: directory)
        watchdog.start()
        loop.watchdog = watchdog
        running.watchdog = watchdog
        service.onSettingsChanged = { loop.settingsChanged() }
        loop.start()
        running.resident = loop
    }
    if openedByCore { DispatchQueue.global().async { try? hub?.declareResident(true) } }
    withExtendedLifetime((sources, watch)) { dispatchMain() }
}

/// What a quit has to stop, set up as serving starts.
final class Running: @unchecked Sendable {
    var socket: AgentSocket?
    var resident: Resident?
    var watchdog: ReadWatchdog?
}

/// Set from a signal handler, read between items.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    var isSet: Bool { lock.withLock { set } }
    func raise() { lock.withLock { set = true } }
}

/// `index --job`: the first pass as luoke-core's idle job (luoke-core#16). Reads the settings' folders in steps;
/// SIGTERM ends it after the item in hand, exit code 0, and the next run goes on from there. stderr gets counts only:
/// luoke-core keeps it (and its tail goes into diagnostics), so no paths and no content.
func job(_ arguments: Arguments) throws -> Never {
    let directory = try arguments.dataDirectory()
    let stop = StopFlag()
    let watchdog = ReadWatchdog(directory: directory)
    var sources: [DispatchSourceSignal] = []
    for number in [SIGTERM, SIGINT] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        // The file in hand written down first: luoke-core may kill the job before it's read (luoke-search#65).
        source.setEventHandler {
            watchdog.noteAskedToStop()
            stop.raise()
        }
        source.resume()
        sources.append(source)
    }
    let store = try IndexStore(directory: directory)
    watchdog.start()
    var pass = FirstPass(directory: directory, store: store, hub: arguments.hub(for: directory),
                         photos: SystemPhotos.current)
    pass.watchdog = watchdog
    pass.restrictFolders = arguments.shipped
    let report = try withExtendedLifetime(sources) { try pass.run(shouldStop: { stop.isSet }) }
    let counts = try store.counts()
    var line = "luoke-search job: read \(report.read) (and \(report.restSteps) steps of long files), "
        + "\(report.vectors.embedded) text vectors, \(report.vectors.embeddedMedia) picture and sound vectors; "
        + "\(counts.waitingToRead) waiting to read, \(counts.waitingForRest) long files still being read"
    if report.stopped { line += "; stopped when asked" }
    if let reason = report.vectors.stoppedBy { line += "; luoke-core: \(reason)" }
    FileHandle.standardError.write(Data((line + "\n").utf8))
    exit(0)
}

/// `probe-audio`: why questions about recordings do worse. Needs luoke-core.
func probeAudio(_ arguments: Arguments) throws {
    try arguments.only(["--index", "--testbed", "--transcripts", "--json"])
    guard !arguments.positional.isEmpty else { throw Failure("要给题库文件") }
    let directory = try arguments.dataDirectory()
    guard let hub = arguments.hub(for: directory) else { throw Failure("要连螺壳（开发时设 LUOKE_HUB_SOCKET）") }
    let sets = try arguments.positional.map { try EvalSet.load(URL(fileURLWithPath: absolute($0))) }
    let testbed = arguments.value("--testbed").map(absolute) ?? ProcessInfo.processInfo.environment["LUOKE_SEARCH_TESTBED"]
    var transcripts: [String: [AudioProbe.Part]] = [:]
    if let file = arguments.value("--transcripts") {
        transcripts = try JSONDecoder().decode([String: [AudioProbe.Part]].self,
                                               from: Data(contentsOf: URL(fileURLWithPath: absolute(file))))
    }
    let rows = try AudioProbe.run(sets, testbed: testbed, store: try IndexStore(directory: directory), hub: hub,
                                  transcripts: transcripts)
    if arguments.json { return try printJSON(rows) }
    func text(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "-" }
    func place(_ value: Int?) -> String { value.map { "第 \($0)" } ?? "不在前十" }
    for row in rows {
        print("== \(row.q)（\(row.tag ?? "-")）→ \(row.file)：搜索里\(place(row.searchRank))；最好的窗口按余弦"
              + "在全部 \(row.rows) 条里第 \(row.rankAmongAll.map(String.init) ?? "-")、在 \(row.soundRows) 段录音里"
              + "第 \(row.rankAmongSound.map(String.init) ?? "-")；同样的话写成文字会排第 \(row.textWouldRank.map(String.init) ?? "-")；"
              + "最近的是 \(row.top ?? "-")（\(text(row.topCosine))）")
        for window in row.windows {
            print("   \(String(format: "%.1f", window.from))–\(String(format: "%.1f", window.to)) s：送去 "
                  + "\(String(format: "%.1f", window.seconds)) s、\(window.sampleRate) Hz、\(window.channels) 声道、"
                  + "\(window.bits) 位、\(window.bytes) 字节，响度 \(text(window.rmsDBFS)) dBFS，静音占 \(text(window.quietShare))；"
                  + "重做的和存的向量 \(text(window.remadeVsStored))；问题对它 \(text(window.cosine))、对它的文字 "
                  + "\(text(window.transcriptCosine))；它对它的文字 \(text(window.windowVsTranscript))")
        }
    }
}

/// `photos-probe`: numbers about the Photos library, for a test on a real one — never an identifier, name, date,
/// place or anything in a picture. `--access`: only whether this process may read it (who it's charged to: a process
/// started by another app is that app's, unless it disclaims; see scripts/spawn_measured.c). Never asks.
func photosProbe(_ arguments: Arguments) throws {
    try arguments.only(["--access", "--sample", "--originals"])
    guard let library = SystemPhotos.current else {
        throw Failure("只有 螺壳搜索.app 本身（或设了 LUOKE_SEARCH_PHOTOS=system）能看照片图库")
    }
    if arguments.flags.contains("--access") { return print(library.access.rawValue) }
    guard library.access == .allowed else {
        throw Failure("照片图库没有允许（\(library.access.rawValue)）；这条命令不会去问")
    }
    let sample = Int(arguments.value("--sample") ?? "") ?? 2000
    let originals = Int(arguments.value("--originals") ?? "") ?? 300
    print(try JSONOutput.string(PhotoProbe.run(library, sample: sample, originals: originals)))
}

// MARK: Main

// Opened as 螺壳搜索.app (by luoke-core at login with --resident, or by hand): no command, maybe flags — it's the
// background service. LaunchServices may add a -psn_… argument; it means nothing here.
let given = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
let asApp = LuokeSearch.isApp
    && (given.first.map { $0.hasPrefix("-") && !["-h", "--help"].contains($0) } ?? true)
let command = asApp ? "serve" : given.first
#if LUOKE_SEARCH_DEV_APP
let developmentApp = true
#else
let developmentApp = false
#endif
do {
    var arguments = try Arguments(asApp ? ArraySlice(given) : given.dropFirst())
    // The app as it ships takes no development switch (`Arguments.shipped`): another data directory or home is
    // refused, the rest are gone before anything reads them.
    if Arguments.shipped(app: LuokeSearch.isApp, command: command, flags: arguments.flags,
                         developmentApp: developmentApp) {
        let environment = ProcessInfo.processInfo.environment
        if let why = arguments.shippedRefusal(command: command, environment: environment) { throw Failure(why) }
        var dropped: [String] = []
        for name in Arguments.developmentVariables where environment[name] != nil {
            if !(name == "LUOKE_HUB_SOCKET" && environment[name] == Hub.installedSocket) { dropped.append(name) }
            unsetenv(name)
        }
        if !dropped.isEmpty {
            FileHandle.standardError.write(Data("luoke-search: 发布版不认开发用的 \(dropped.joined(separator: "、"))，已忽略\n".utf8))
        }
        arguments.shipped = true
        // Everything but status and help reads under 螺壳's Full Disk Access or changes something: only 螺壳 starts it.
        if !FromApp.free.contains(command ?? "help"), let why = FromApp.check() {
            FileHandle.standardError.write(Data("luoke-search: 螺壳搜索：\(why)。\n装好的螺壳搜索只由螺壳起，请在螺壳里用；终端里能看的是 status。\n".utf8))
            exit(FromApp.refusedExitCode)
        }
    }
    switch command {
    case "index": try index(arguments)
    case "search": try search(arguments)
    case "status": try status(arguments)
    case "eval": try eval(arguments)
    case "open": try open(arguments)
    case "settings": try settings(arguments)
    case "mcp": try mcp(arguments)
    case "serve": try serve(arguments)
    case "photos-probe": try photosProbe(arguments)
    case "probe-audio": try probeAudio(arguments)
    case nil, "help", "-h", "--help": print(usage)
    default: throw Failure("没有这个命令：\(command!)\n\n\(usage)")
    }
} catch let failure as AgentSocket.Failure where failure.alreadyServing {
    FileHandle.standardError.write(Data("luoke-search: \(failure)\n".utf8))
    exit(AgentSocket.alreadyServingExitCode)
} catch {
    FileHandle.standardError.write(Data("luoke-search: \(error)\n".utf8))
    exit(1)
}
