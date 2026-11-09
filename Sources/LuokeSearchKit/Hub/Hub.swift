import Foundation
import Security

public enum LuokeSearch {
    /// The accessory id (luoke-core V1 §8) and the version sent with every request to the hub.
    public static let accessory = "luoke-search"
    public static let version = "0.1.14"
    public static let bundleID = "ai.luoke.search"

    /// Whether this process runs 螺壳搜索.app's code: its bundle says so, or — run through a link placed outside
    /// the bundle, which hides the bundle from `Bundle.main` — its signature does (codesign named it by the bundle id).
    /// macOS's privacy checks go by the code, not the path it was started by (the review of should-fix 8).
    public static let isApp = Bundle.main.bundleIdentifier == bundleID || signingIdentifier() == bundleID

    /// The bundle id this process counts as: the app's when it's the app's code (`isApp`), else `Bundle.main`'s.
    public static var bundleIdentifier: String? { isApp ? bundleID : Bundle.main.bundleIdentifier }

    /// What macOS calls the one holding this program's permissions, in what the user is told: the app's own name when
    /// this is 螺壳搜索.app, 「螺壳」 when it's the program inside 螺壳.app (`Contents/Helpers`, `scripts/build_helper.sh`):
    /// macOS charges a helper's access to the app around it, and that's the row System Settings lists.
    public static let holder = holder(bundle: Bundle.main.bundleIdentifier, signing: signingIdentifier())

    static func holder(bundle: String?, signing: String?) -> String {
        bundle != bundleID && signing == bundleID ? "螺壳" : "螺壳搜索"
    }

    /// The identifier in this process's code signature, if it has one.
    static func signingIdentifier() -> String? {
        var code: SecCode?, staticCode: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String
    }
}

/// What luoke-core says about the embedding task (`GET /tasks`).
public struct HubTask: Sendable, Equatable {
    public enum Status: String, Sendable {
        case available, needsDownload = "needs_download", downloading, paused, unsupported
        /// A status this version doesn't know: not now, for a reason in `reason`.
        case unavailable
    }

    public var status: Status
    public var reason: String?
    public var progress: Double?
    /// Identifies the space the vectors are in; compared for equality only, never parsed (luoke-core V1 §2).
    public var vectorSpace: String?
    /// Texts per request.
    public var batch = 32
    /// Characters per text, and per request. Over them the hub refuses (`input_too_long`): it doesn't cut.
    public var maxChars = 32_000
    public var maxTotalChars = 320_000
    /// Pictures and sound (luoke-core's multimodal draft): taken only when the task's parameters say so. A tier
    /// that only takes text has none of these.
    public var imageBatch = 0
    /// The picture budgets this tier allows (70, 140, 280, 560, 1120); missing: any.
    public var imageBudgets: Set<Int>?
    public var audioBatch = 0
    public var maxImageBytes: Int?
    public var maxAudioBytes: Int?
    public var maxAudioSecs = 30.0

    public var takesImages: Bool { imageBatch > 0 }
    public var takesAudio: Bool { audioBatch > 0 }

    public init(status: Status, reason: String? = nil, progress: Double? = nil, vectorSpace: String? = nil,
                batch: Int = 32, maxChars: Int = 32_000, maxTotalChars: Int = 320_000) {
        self.status = status
        self.reason = reason
        self.progress = progress
        self.vectorSpace = vectorSpace
        self.batch = batch
        self.maxChars = maxChars
        self.maxTotalChars = maxTotalChars
    }
}

/// Why the hub didn't give vectors.
public enum HubError: Error, Equatable, Sendable {
    /// luoke-core isn't installed or isn't running.
    case notRunning
    /// This luoke-core doesn't know luoke-search (403): an older version.
    case unknownAccessory
    /// This Mac doesn't offer the task (404 `unsupported`), or it isn't available yet (404 `task_unavailable`:
    /// downloading, paused…).
    case unsupported(String?)
    case unavailable(String?)
    /// Turned away for now (503 `busy`, `paused`, `not_ready`, `needs_user`, `engine_failed`): try again after
    /// `retryAfter` seconds. `reason` says why (`power_cooldown`, `lane_busy`, `interactive`, `battery`…).
    case refused(code: String, reason: String?, retryAfter: Double?)
    case inputTooLong
    case invalidRequest(String?)
    /// Anything else: an answer we couldn't use.
    case failed(String)

    /// Asking again later can work.
    public var isTemporary: Bool {
        if case .refused = self { return true }
        return false
    }
}

/// The client for luoke-core's task layer (luoke-core V1 §2): `GET /tasks` and `POST /tasks/<task>/v1/embed`, over
/// its Unix socket. Blocking calls; one connection per request.
public final class Hub: @unchecked Sendable {
    public enum Priority: String, Sendable {
        case userWaiting = "user-waiting"
        case background
    }

    /// The task luoke-search asks for. `LUOKE_SEARCH_EMBED_TASK` can point a development run at another of
    /// luoke-search's own (luoke-core lists an accessory only its own tasks, so not `digup.embed`).
    public let task: String
    public let socket: String
    public var allowBattery = false
    private let lock = NSLock()
    private var tasksVersion: String?
    private var cachedTask: HubTask?

    public init(socket: String, task: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.socket = socket
        self.task = task ?? environment["LUOKE_SEARCH_EMBED_TASK"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(LuokeSearch.accessory).embed"
    }

    /// luoke-core's socket: `$LUOKE_HUB_SOCKET` if set; else the installed hub's, but only for the app itself
    /// (螺壳搜索.app, as for the Photos library) on the standard data directory. A development build, a test, or a
    /// run with its own `--index` never falls back to the hub the Mac uses every day (review B-10).
    public static func socket(for directory: DataDirectory,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              bundle: String? = LuokeSearch.bundleIdentifier) -> String? {
        if let socket = environment["LUOKE_HUB_SOCKET"], !socket.isEmpty { return socket }
        guard directory.isStandard, bundle == LuokeSearch.bundleID else { return nil }
        return installedSocket
    }

    /// The socket of the luoke-core installed on this Mac.
    public static var installedSocket: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/luoke-core/run/hub.sock").path
    }

    var headers: [String: String] {
        var headers = ["X-Luoke-Accessory": "\(LuokeSearch.accessory)/\(LuokeSearch.version)"]
        if allowBattery { headers["X-Luoke-Allow-Battery"] = "1" }
        return headers
    }

    // MARK: Tasks

    /// The task's state and parameters, read again whenever the hub says its parameters changed
    /// (`X-Luoke-Tasks-Version`).
    public func embedTask(refresh: Bool = false, timeout: TimeInterval = 10) throws -> HubTask {
        if !refresh, let cached = lock.withLock({ cachedTask }) { return cached }
        guard let task = try tasks(timeout: timeout).task else { throw HubError.unknownAccessory }
        return task
    }

    /// The machine's background state: "running", or "paused" with why (luoke-core's reasons: "battery",
    /// "low_power", "thermal", "memory").
    public typealias Background = (state: String, reasons: [String])

    /// `GET /tasks`, once: the task's state and parameters as `embedTask` takes them (nil: luoke-core lists no such
    /// task), and the machine's background state (nil: the answer has none).
    public func tasks(timeout: TimeInterval = 10) throws -> (task: HubTask?, background: Background?) {
        let response = try send("GET", "/tasks", body: nil, timeout: timeout)
        try check(response)
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let tasks = json["tasks"] as? [String: Any] else { throw HubError.failed("unreadable /tasks") }
        guard let entry = tasks[task] as? [String: Any] else { return (nil, Self.background(json)) }
        let params = entry["params"] as? [String: Any] ?? [:]
        // A status this version doesn't know (one added later) is "not now", never "never" (review B-14).
        let said = entry["status"] as? String
        let status = HubTask.Status(rawValue: said ?? "") ?? (said == nil ? .unsupported : .unavailable)
        var task = HubTask(status: status, reason: entry["reason"] as? String ?? (status == .unavailable ? said : nil),
                           progress: (entry["progress"] as? NSNumber)?.doubleValue,
                           vectorSpace: entry["vector_space"] as? String ?? params["vector_space"] as? String)
        if let batch = (params["batch"] as? NSNumber)?.intValue, batch > 0 { task.batch = batch }
        if let chars = (params["max_chars"] as? NSNumber)?.intValue, chars > 0 { task.maxChars = chars }
        if let total = (params["max_total_chars"] as? NSNumber)?.intValue, total > 0 { task.maxTotalChars = total }
        task.imageBatch = (params["image_batch"] as? NSNumber)?.intValue ?? 0
        task.audioBatch = (params["audio_batch"] as? NSNumber)?.intValue ?? 0
        if let budgets = params["image_budgets"] as? [NSNumber] { task.imageBudgets = Set(budgets.map(\.intValue)) }
        task.maxImageBytes = (params["max_image_bytes"] as? NSNumber)?.intValue
        task.maxAudioBytes = (params["max_audio_bytes"] as? NSNumber)?.intValue
        if let seconds = (params["max_audio_secs"] as? NSNumber)?.doubleValue, seconds > 0 { task.maxAudioSecs = seconds }
        lock.withLock {
            cachedTask = task
            tasksVersion = response.headers["x-luoke-tasks-version"] ?? (json["tasks_version"] as? String)
        }
        return (task, Self.background(json))
    }

    /// The machine's background state as luoke-core sees it (`GET /tasks` → `background`). Nil when it can't be
    /// asked.
    public func background() -> Background? {
        guard let response = try? send("GET", "/tasks", body: nil, timeout: 10), response.status == 200,
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else { return nil }
        return Self.background(json)
    }

    static func background(_ json: [String: Any]) -> Background? {
        guard let background = json["background"] as? [String: Any], let state = background["state"] as? String else {
            return nil
        }
        return (state, background["reasons"] as? [String] ?? [])
    }

    /// Asks luoke-core to open luoke-search at login (V1 §8: accessories don't register login items of their own).
    public func declareResident(_ resident: Bool) throws {
        let body = try JSONSerialization.data(withJSONObject: ["resident": resident])
        try check(try send("PUT", "/accessory/resident", body: body, extra: headers, timeout: 10))
    }

    /// Tells luoke-core this is a normal exit, not a crash to restart from.
    public func exiting() throws {
        try check(try send("POST", "/accessory/exiting", body: Data("{}".utf8), extra: headers, timeout: 5))
    }

    // MARK: Embedding

    public struct Vectors: Sendable {
        public let vectors: [[Float]]
        public let vectorSpace: String?
        /// luoke-core's parameters changed since they were read (`X-Luoke-Tasks-Version`): read them again.
        public var tasksChanged = false
    }

    /// Vectors for `texts` (already prompted, within the task's limits), in order. Full 768 dimensions, L2-normalized.
    public func embed(_ texts: [String], priority: Priority, timeout: TimeInterval? = nil) throws -> Vectors {
        let body = try JSONSerialization.data(withJSONObject: ["texts": texts])
        var headers = ["X-Luoke-Priority": priority.rawValue]
        headers.merge(self.headers) { first, _ in first }
        // 45 s for the request and 2 s more for each text: a batch of long chunks takes a few seconds.
        let response = try send("POST", "/tasks/\(task)/v1/embed", body: body, extra: headers,
                                timeout: timeout ?? (45 + 2 * Double(texts.count)))
        let changed = noteTasksVersion(response)
        try check(response)
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let rows = json["vectors"] as? [[NSNumber]] else { throw HubError.failed("unreadable vectors") }
        guard rows.count == texts.count else { throw HubError.failed("\(rows.count) vectors for \(texts.count) texts") }
        var vectors: [[Float]] = []
        for row in rows {
            guard let vector = Self.usable(row.map(\.floatValue)) else {
                throw HubError.failed("a vector of \(row.count) dimensions, or all zeros")
            }
            vectors.append(vector)
        }
        return Vectors(vectors: vectors, vectorSpace: json["vector_space"] as? String, tasksChanged: changed)
    }

    /// A vector as stored: 768 finite numbers, not all (nearly) zero (review B-15), normalized.
    static func usable(_ vector: [Float]) -> [Float]? {
        guard vector.count == VectorMath.dimension, vector.allSatisfy(\.isFinite) else { return nil }
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-6 else { return nil }
        return VectorMath.normalized(vector)
    }

    /// One input of a multimodal request (luoke-core's draft): bytes, never a path (luoke-core doesn't read the
    /// user's files).
    public enum Input: Sendable {
        case text(String)
        /// A PNG or JPEG, and its token budget (70, 140, 280…).
        case image(Data, budget: Int)
        /// A 16 kHz mono 16-bit WAV.
        case audio(Data)

        var json: [String: Any] {
            switch self {
            case .text(let text): ["text": text]
            case .image(let data, let budget): ["image": data.base64EncodedString(), "budget": budget]
            case .audio(let data): ["audio": data.base64EncodedString()]
            }
        }
    }

    public struct InputVectors: Sendable {
        /// In the order of the inputs; nil where that input failed.
        public let vectors: [[Float]?]
        /// Why each failed input did (`image_unreadable`, `audio_unreadable`, `audio_too_long`, `embed_failed`).
        public let errors: [String?]
        public let vectorSpace: String?
        public var tasksChanged = false
    }

    /// Vectors for pictures and sound (and text) in one request; each input succeeds or fails on its own.
    public func embed(inputs: [Input], priority: Priority) throws -> InputVectors {
        let body = try JSONSerialization.data(withJSONObject: ["inputs": inputs.map(\.json)])
        var headers = ["X-Luoke-Priority": priority.rawValue]
        headers.merge(self.headers) { first, _ in first }
        let response = try send("POST", "/tasks/\(task)/v1/embed", body: body, extra: headers,
                                timeout: 60 + 5 * Double(inputs.count))
        let changed = noteTasksVersion(response)
        try check(response)
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let rows = json["vectors"] as? [Any], rows.count == inputs.count else {
            throw HubError.failed("unreadable vectors")
        }
        let errors = (json["errors"] as? [Any]).map { $0.map { $0 as? String } }
            ?? Array(repeating: nil, count: inputs.count)
        let vectors: [[Float]?] = rows.map { row in
            (row as? [NSNumber]).flatMap { Self.usable($0.map(\.floatValue)) }
        }
        var said = errors.count == inputs.count ? errors : Array(repeating: nil, count: inputs.count)
        for index in vectors.indices where vectors[index] == nil && said[index] == nil { said[index] = "embed_failed" }
        return InputVectors(vectors: vectors, errors: said, vectorSpace: json["vector_space"] as? String,
                            tasksChanged: changed)
    }

    /// The parameters changed since they were read: forget them, the next `embedTask()` reads them again. Noted
    /// before a refusal is turned into an error, so a refusal that came with new parameters is known as one.
    @discardableResult
    private func noteTasksVersion(_ response: UnixHTTP.Response) -> Bool {
        guard let version = response.headers["x-luoke-tasks-version"] else { return false }
        return lock.withLock {
            let changed = tasksVersion.map { $0 != version } ?? false
            if changed { cachedTask = nil }
            tasksVersion = version
            return changed
        }
    }

    // MARK: Wire

    private func send(_ method: String, _ target: String, body: Data?, extra: [String: String]? = nil,
                      timeout: TimeInterval) throws -> UnixHTTP.Response {
        do {
            return try UnixHTTP.request(socket: socket, method: method, target: target, headers: extra ?? headers,
                                        body: body, timeout: timeout)
        } catch UnixHTTP.Failure.notListening {
            throw HubError.notRunning
        } catch UnixHTTP.Failure.timedOut {
            throw HubError.refused(code: "timeout", reason: nil, retryAfter: 5)
        } catch let failure as UnixHTTP.Failure {
            throw HubError.failed("\(failure)")
        }
    }

    /// Turns a refusal (luoke-core V1 §2: status + `{code, message, retry_after, retry_after_ms, reason}`) into a
    /// `HubError`.
    func check(_ response: UnixHTTP.Response) throws {
        guard response.status >= 400 else { return }
        let json = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:]
        let code = json["code"] as? String ?? ""
        let message = json["message"] as? String
        let reason = json["reason"] as? String
        var retryAfter = (json["retry_after"] as? NSNumber)?.doubleValue
            ?? response.headers["retry-after"].flatMap(Double.init)
        if let milliseconds = (json["retry_after_ms"] as? NSNumber)?.doubleValue { retryAfter = milliseconds / 1000 }
        switch (response.status, code) {
        case (403, _): throw HubError.unknownAccessory
        case (404, "unsupported"): throw HubError.unsupported(message ?? reason)
        case (404, _): throw HubError.unavailable(message ?? reason)
        case (413, _): throw HubError.inputTooLong
        case (400, _): throw HubError.invalidRequest(message)
        case (503, _): throw HubError.refused(code: code.isEmpty ? "busy" : code, reason: reason, retryAfter: retryAfter)
        default: throw HubError.failed("HTTP \(response.status) \(code)")
        }
    }
}
