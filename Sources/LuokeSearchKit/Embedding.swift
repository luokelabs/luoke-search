import Foundation

/// EmbeddingGemma 2's retrieval prompts (its model card). luoke-core doesn't add them: the caller does (V1 §2).
/// Unchanged from digup, so the reference vectors and digup's indexes stay comparable.
public enum Prompts {
    public static func query(_ text: String) -> String { "task: search result | query: \(text)" }

    public static func document(title: String?, text: String) -> String {
        "title: \((title?.isEmpty ?? true) ? "none" : title!) | text: \(text)"
    }
}

/// Fills in the vectors segments are waiting for, from luoke-core, in the background. Reading never waits for this:
/// keyword search works meanwhile. luoke-core's rules (V1 §2, DESIGN §6) are kept: background requests, at most
/// `batch` texts and `max_total_chars` a request, and when turned away, ask again only after `retry_after`.
public final class VectorFiller {
    public struct Report: Sendable, Equatable {
        public var embedded = 0
        /// Pictures and sound windows that got vectors, and those that never will (luoke-core couldn't read them, or
        /// they failed too many times).
        public var embeddedMedia = 0
        public var mediaFailed = 0
        /// Pictures and sound that couldn't be made or embedded this time: tried again next run (a few times).
        public var mediaRetrying = 0
        /// Why it stopped with segments still waiting (nil: none left, or `shouldStop`).
        public var stoppedBy: HubError?
        /// Segments that waited again because luoke-core's vector space changed.
        public var spaceChanged = 0
        /// The most picture and sound inputs (and their bytes) held at once: they're made one at a time and sent a
        /// request's worth at a time (review B-03).
        public var heldAtMost = 0
        public var heldBytesAtMost = 0
    }

    let store: IndexStore
    let hub: Hub
    /// How long to wait in total for a busy luoke-core when told to wait (`index --wait`).
    public var patience: TimeInterval = 3600
    /// How long luoke-core's short rests after each batch may add up to without a vector made in between.
    public var restLimit: TimeInterval = 600
    /// The Photos library, for Photos items' pictures and sound; without it they keep waiting.
    public var photos: PhotoSource?
    /// Told when a file's pictures and sound are being made again (a PDF's page, a video's frame…): it stops the
    /// process when one runs away, as reading does (`ReadWatchdog`).
    public var watchdog: ReadWatchdog?
    /// Whether a file's contents are only in iCloud (as `Crawler.isDataless`); swapped in tests.
    var isDataless: (stat) -> Bool = { $0.st_flags & Crawler.datalessFlag != 0 }
    /// The next of an item's pictures and sound; swapped in tests.
    var next: (MediaInputs.Source) -> MediaInputs.Outcome? = { $0.next() }
    /// Items whose waiting pictures and sound are looked up at once.
    public var mediaItemsPerRound = 8
    /// The most bytes of pictures or sound one request carries.
    public var maxRequestBytes = 32 << 20
    /// Sleeping `seconds`, a little at a time, ending early when asked to stop; swapped out in tests.
    var sleep: (_ seconds: TimeInterval, _ shouldStop: () -> Bool) -> Void = { seconds, shouldStop in
        var left = seconds
        while left > 0, !shouldStop() {
            Thread.sleep(forTimeInterval: min(left, 0.5))
            left -= 0.5
        }
    }

    public init(store: IndexStore, hub: Hub) {
        self.store = store
        self.hub = hub
    }

    /// Busy reasons that are a short rest after each piece of work (a power profile's pause, the embedding lane's):
    /// waited out on the spot even without `wait`, as they come right after every batch (digup 73eddf2), however long
    /// luoke-core says (review B-07), up to `restLimit` without progress.
    static let rests: Set<String> = ["power_cooldown", "lane_busy"]
    /// Per-input errors that mean never (luoke-core can't read it); any other failure is tried again.
    static let unreadable: Set<String> = ["image_unreadable", "audio_unreadable"]

    /// How to go on after luoke-core turned a request away: wait (how long it says; doubled only while nothing gets
    /// through at all, up to 300 s), or stop.
    struct Pacer {
        let wait: Bool
        let patience: TimeInterval
        let restLimit: TimeInterval
        var waited: TimeInterval = 0
        var rested: TimeInterval = 0
        var lastDelay: TimeInterval = 0
        var madeSinceRefusal = true

        /// The seconds to sleep before trying again, or nil to stop.
        mutating func delay(after error: HubError) -> TimeInterval? {
            guard case .refused(let code, let reason, let retryAfter) = error else { return nil }
            if code == "busy", reason.map(VectorFiller.rests.contains) == true {
                let delay = max(retryAfter ?? 1, 0.25)
                guard rested + delay <= restLimit else { return nil }
                rested += delay
                return delay
            }
            guard wait else { return nil }
            var delay = max(retryAfter ?? 1, 0.25)
            if !madeSinceRefusal { delay = max(delay, min(lastDelay * 2, 300)) }
            guard waited + delay <= patience else { return nil }
            waited += delay
            lastDelay = delay
            madeSinceRefusal = false
            return delay
        }

        mutating func madeSome() {
            madeSinceRefusal = true
            rested = 0
        }
    }

    func pause(_ seconds: TimeInterval, _ shouldStop: () -> Bool) {
        sleep(seconds, shouldStop)
    }

    /// Embeds waiting segments until none are left: text first, then pictures and sound if luoke-core takes them.
    /// With `wait`, a busy or paused luoke-core is waited for (up to `patience`); without, the first refusal that
    /// isn't a short rest ends the run.
    public func run(wait: Bool, shouldStop: () -> Bool = { false }) -> Report {
        var report = Report()
        var task: HubTask
        do {
            task = try hub.embedTask(refresh: true)
            guard task.status == .available else {
                report.stoppedBy = task.status == .unsupported ? .unsupported(task.reason) : .unavailable(task.reason)
                return report
            }
            if try store.vectorSpace != task.vectorSpace, task.vectorSpace != nil {
                report.spaceChanged = try store.adoptVectorSpace(task.vectorSpace)
            }
        } catch {
            report.stoppedBy = error as? HubError ?? .failed("\(error)")
            return report
        }
        var pacer = Pacer(wait: wait, patience: patience, restLimit: restLimit)
        var adopted = false
        fillText(&task, &pacer, &report, &adopted, shouldStop)
        if report.stoppedBy == nil, !shouldStop(), task.takesImages || task.takesAudio {
            fillMedia(&task, &pacer, &report, shouldStop)
        }
        return report
    }

    /// Reads the task again (its parameters changed), keeping the vector space this run settled on if it names none.
    private func refreshed(_ task: HubTask) -> HubTask? {
        guard var fresh = try? hub.embedTask(refresh: true) else { return nil }
        if fresh.vectorSpace == nil { fresh.vectorSpace = task.vectorSpace }
        return fresh
    }

    private func fillText(_ task: inout HubTask, _ pacer: inout Pacer, _ report: inout Report, _ adopted: inout Bool,
                          _ shouldStop: () -> Bool) {
        var batch = task.batch
        while !shouldStop() {
            let todos: [IndexStore.TextTodo]
            do { todos = try store.textTodos(limit: batch) } catch { report.stoppedBy = .failed("\(error)"); return }
            if todos.isEmpty { return }
            let (prompts, used) = Self.prompts(todos, task: task)
            do {
                // A pool per request: what encoding and decoding it leaves behind is let go here, not when the run
                // ends (a first pass of 10,000 files grew to 3 GB without).
                let result = try autoreleasepool { try hub.embed(prompts, priority: .background) }
                if let returned = result.vectorSpace, returned != task.vectorSpace {
                    if task.vectorSpace == nil, try store.vectorSpace.map({ $0 == returned }) ?? true {
                        task.vectorSpace = returned   // /tasks didn't name it; the answer does (review B-05)
                    } else if !adopted {
                        // The space changed under us: once a run, start again in the new one.
                        adopted = true
                        task = refreshed(task) ?? task
                        if task.vectorSpace != returned { task.vectorSpace = returned }
                        report.spaceChanged += try store.adoptVectorSpace(task.vectorSpace)
                        continue
                    } else {
                        report.stoppedBy = .failed("luoke-core's vector space keeps changing")
                        return
                    }
                }
                try store.setVectors(zip(used, result.vectors).map { ($0.segment, $1) }, space: task.vectorSpace)
                report.embedded += used.count
                pacer.madeSome()
                if result.tasksChanged { task = refreshed(task) ?? task }
                batch = task.batch
            } catch HubError.inputTooLong, HubError.invalidRequest {
                // The limits may have changed under us (a smaller batch on battery): read them again first, and only
                // when they're the same, halve the batch, and drop a single text (review B-06).
                if let fresh = refreshed(task), (fresh.batch, fresh.maxChars, fresh.maxTotalChars)
                    != (task.batch, task.maxChars, task.maxTotalChars) {
                    task = fresh
                    batch = task.batch
                    continue
                }
                if used.count > 1 { batch = max(1, used.count / 2) } else if let only = used.first {
                    try? store.giveUpVector(segment: only.segment)
                }
            } catch let error as HubError {
                guard let delay = pacer.delay(after: error) else { report.stoppedBy = error; return }
                pause(delay, shouldStop)
            } catch {
                report.stoppedBy = .failed("\(error)")
                return
            }
        }
    }

    /// Pictures and sound: each item's waiting frames, pages and windows made again from its file, one at a time
    /// (`MediaInputs.Source`), and sent as soon as a request's worth is ready: at most `image_batch` pictures or
    /// `audio_batch` windows, and `maxRequestBytes`. An input luoke-core can't read never gets a vector; one that
    /// failed for now is tried again next run (a few times); one this tier doesn't take waits for one that does.
    /// Items are gone through once a run, in order (review B-20).
    private func fillMedia(_ task: inout HubTask, _ pacer: inout Pacer, _ report: inout Report,
                           _ shouldStop: () -> Bool) {
        var after: Int64 = 0
        var pictures: [MediaInputs.Made] = [], sound: [MediaInputs.Made] = []
        func bytes(_ inputs: [MediaInputs.Made]) -> Int {
            inputs.reduce(0) { total, made in
                switch made.input {
                case .image(let data, _), .audio(let data): total + data.count
                case .text(let text): total + text.utf8.count
                }
            }
        }
        while !shouldStop() {
            let items = store.mediaTodos(limit: mediaItemsPerRound, pictures: task.takesImages, sound: task.takesAudio,
                                         after: after)
            if items.isEmpty { break }
            for item in items {
                after = item.id
                let wanted = item.wanted.filter { MediaInputs.taken($0, kind: item.kind, by: task) }
                // Nothing this tier takes, a Photos item with no library here, a file not on this Mac now (its drive
                // unplugged, its contents only in iCloud: `MediaInputs.Source`): nothing is made, nothing counted.
                if wanted.isEmpty || (PhotoPath.id(item.path) != nil ? photos == nil
                                      : !MediaInputs.isHere(item.path, isDataless: isDataless)) { continue }
                // Making them ended the process twice before with nothing written down (a crash, the system taking
                // its memory), as reading gives up after two (`Indexer.maxAttempts`): its pictures and sound get no
                // vectors; one waiting to be read again is passed over until it is. Otherwise counted from here until
                // it's over, however it ends; not made at all when the count can't be written (the index busy).
                guard let tries = try? store.startMedia(item.id) else { continue }
                if tries >= Indexer.maxAttempts {
                    if (try? store.giveUpMedia(item: item.id, why: "making them ended the process \(tries) times")) == true {
                        report.mediaFailed += item.wanted.count
                    }
                    continue
                }
                defer { if (try? store.finishedMedia(item.id)) == nil { try? store.finishedMedia(item.id) } }
                let source = MediaInputs.Source(path: item.path, kind: item.kind, wanted: wanted, task: task,
                                                photos: photos, inode: item.inode)
                source.isDataless = isDataless
                // Watched from here to the item's end: its memory from the start (one document stays open for all
                // its pictures); its time only while they're made, not sent, `Reader.pdfStep` of them a step.
                watchdog?.begin(item.path, mtime: item.mtime, size: item.size, stage: ReadWatchdog.media,
                                pages: wanted.count)
                defer { watchdog?.end() }
                var count = 0
                func made() -> MediaInputs.Outcome? {
                    if count > 0, count % Reader.pdfStep == 0 { watchdog?.newStep() }
                    count += 1
                    watchdog?.resume()
                    defer { watchdog?.pause() }
                    return autoreleasepool { next(source) }
                }
                while let outcome = made() {
                    if shouldStop() { return }
                    switch outcome {
                    case .made(let made):
                        if case .audio = made.input { sound.append(made) } else { pictures.append(made) }
                        report.heldAtMost = max(report.heldAtMost, pictures.count + sound.count)
                        report.heldBytesAtMost = max(report.heldBytesAtMost, bytes(pictures) + bytes(sound))
                        if pictures.count >= max(task.imageBatch, 1) || bytes(pictures) >= maxRequestBytes {
                            guard send(pictures, &task, &pacer, &report, shouldStop) else { return }
                            pictures = []
                        }
                        if sound.count >= max(task.audioBatch, 1) || bytes(sound) >= maxRequestBytes {
                            guard send(sound, &task, &pacer, &report, shouldStop) else { return }
                            sound = []
                        }
                    case .impossible(let segment, _):
                        try? store.giveUpVector(segment: segment)
                        report.mediaFailed += 1
                    case .failedForNow(let segment, _):
                        triedAgainLater(segment, &report)
                    case .later:
                        break
                    }
                }
            }
        }
        for rest in [pictures, sound] where !rest.isEmpty && !shouldStop() {
            guard send(rest, &task, &pacer, &report, shouldStop) else { return }
        }
    }

    private func triedAgainLater(_ segment: Int64, _ report: inout Report) {
        if (try? store.failedForNow(segment: segment)) == true { report.mediaFailed += 1 } else { report.mediaRetrying += 1 }
    }

    /// One request of pictures or sound; false to stop the run.
    private func send(_ inputs: [MediaInputs.Made], _ task: inout HubTask, _ pacer: inout Pacer, _ report: inout Report,
                      _ shouldStop: () -> Bool) -> Bool {
        var request = inputs.filter { MediaInputs.taken($0.input, by: task) }   // the tier may have changed
        while !request.isEmpty {
            if shouldStop() { return false }
            do {
                let result = try autoreleasepool { try hub.embed(inputs: request.map(\.input), priority: .background) }
                if let returned = result.vectorSpace, returned != task.vectorSpace {
                    // Made in another space: not stored; the next run starts again in it (review B-19).
                    report.stoppedBy = .failed("luoke-core's vector space changed")
                    return false
                }
                var done: [(segment: Int64, vector: [Float])] = []
                for (made, (vector, error)) in zip(request, zip(result.vectors, result.errors)) {
                    if let vector {
                        done.append((made.segment, vector))
                    } else if let error, Self.unreadable.contains(error) {
                        try? store.giveUpVector(segment: made.segment)
                        report.mediaFailed += 1
                    } else {
                        triedAgainLater(made.segment, &report)   // embed_failed, too long for this tier…
                    }
                }
                try store.setVectors(done, space: task.vectorSpace)
                report.embeddedMedia += done.count
                pacer.madeSome()
                if result.tasksChanged { task = refreshed(task) ?? task }
                return true
            } catch HubError.inputTooLong, HubError.invalidRequest {
                // Read the limits again; send what's left a half at a time; one alone is tried again later.
                task = refreshed(task) ?? task
                request = request.filter { MediaInputs.taken($0.input, by: task) && MediaInputs.tooBig($0.input, task: task) == nil }
                if request.count > 1 {
                    let half = request.count / 2
                    guard send(Array(request[..<half]), &task, &pacer, &report, shouldStop) else { return false }
                    request = Array(request[half...])
                } else if let only = request.first {
                    triedAgainLater(only.segment, &report)
                    return true
                }
            } catch let error as HubError {
                guard let delay = pacer.delay(after: error) else { report.stoppedBy = error; return false }
                pause(delay, shouldStop)
            } catch {
                report.stoppedBy = .failed("\(error)")
                return false
            }
        }
        return true
    }

    static func chunks<T>(_ items: [T], _ size: Int) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    /// Document prompts for as many of `todos` as fit in one request: each text cut to `max_chars` (by Unicode
    /// scalars, which is how the hub counts), all of them within `max_total_chars`.
    static func prompts(_ todos: [IndexStore.TextTodo], task: HubTask) -> ([String], [IndexStore.TextTodo]) {
        var prompts: [String] = [], used: [IndexStore.TextTodo] = []
        var total = 0
        for todo in todos.prefix(task.batch) {
            var prompt = Prompts.document(title: todo.title, text: todo.text)
            if prompt.unicodeScalars.count > task.maxChars {
                prompt = String(String.UnicodeScalarView(prompt.unicodeScalars.prefix(task.maxChars)))
            }
            let size = prompt.unicodeScalars.count
            if !prompts.isEmpty && total + size > task.maxTotalChars { break }
            prompts.append(prompt)
            used.append(todo)
            total += size
        }
        return (prompts, used)
    }
}

/// A query's vector, or why there isn't one (said to the user as why results may be incomplete).
public struct QueryMeaning: Sendable {
    public let vector: [Float]
    public let space: String?

    public init(vector: [Float], space: String?) {
        self.vector = vector
        self.space = space
    }

    /// Asks luoke-core for the query's vector, someone waiting for it. A model still loading (`not_ready`) is waited
    /// for twice at most (within a budget, as long as it lasts); anything else gives keyword search only, with a
    /// sentence saying why.
    ///
    /// `budget`: at most this many seconds in all (asking for the task's limits, waiting for a model to load, the
    /// vector itself), then keyword search only. Nil: each call has its own timeout, as the command line and the evals
    /// want (a model loading for the first question still counts).
    public static func make(_ query: String, hub: Hub?, within budget: TimeInterval? = nil) -> (QueryMeaning?, note: String?) {
        guard let hub else { return (nil, "没有连螺壳，只按字词搜") }
        let deadline = budget.map { Date().addingTimeInterval($0) }
        // What a call may take: `most`, or what is left of the budget; nil when too little is left to ask at all.
        func allowed(_ most: TimeInterval) -> TimeInterval? {
            guard let deadline else { return most }
            let left = deadline.timeIntervalSinceNow
            return left >= minimumCall ? min(most, left) : nil
        }
        // Cut to the task's limit as documents are (review B-16): a long question still gets a vector.
        var prompt = Prompts.query(query)
        guard let tasksWait = allowed(10) else { return (nil, late) }
        if let limit = (try? hub.embedTask(timeout: tasksWait))?.maxChars, prompt.unicodeScalars.count > limit {
            prompt = String(String.UnicodeScalarView(prompt.unicodeScalars.prefix(limit)))
        }
        var tries = 0
        while true {
            guard let wait = allowed(10) else { return (nil, late) }
            do {
                let result = try hub.embed([prompt], priority: .userWaiting, timeout: wait)
                return (QueryMeaning(vector: result.vectors[0], space: result.vectorSpace), nil)
            } catch HubError.refused(let code, _, let retryAfter) where code == "not_ready" && (deadline != nil || tries < 2) {
                tries += 1
                let pause = min(max(retryAfter ?? 2, 0.25), 3)
                // Not worth waiting when no time would be left to ask again.
                guard allowed(.infinity).map({ $0 >= pause + minimumCall }) ?? false else { return (nil, loading) }
                Thread.sleep(forTimeInterval: pause)
            } catch HubError.refused(let code, _, _) where code == "timeout" && allowed(.infinity) == nil {
                return (nil, late)
            } catch let error as HubError {
                return (nil, note(error))
            } catch {
                return (nil, "螺壳这次没算出来，只按字词搜")
            }
        }
    }

    /// Less than this left of the budget: not worth asking (and a socket timeout of 0 would mean none at all).
    static let minimumCall: TimeInterval = 0.1
    static let late = "螺壳这次没及时算出来，只按字词搜"
    static let loading = "螺壳还在加载模型，这次只按字词搜"

    public static func note(_ error: HubError) -> String {
        switch error {
        case .notRunning: return "螺壳没有在运行，只按字词搜"
        case .unknownAccessory: return "这版螺壳还不认识螺壳搜索，只按字词搜"
        case .unsupported: return "这台 Mac 上的螺壳不提供按意思搜，只按字词搜"
        case .unavailable(let why): return "螺壳还没准备好按意思搜\(why.map { "（\($0)）" } ?? "")，只按字词搜"
        default: return "螺壳这次没算出来，只按字词搜"
        }
    }
}
