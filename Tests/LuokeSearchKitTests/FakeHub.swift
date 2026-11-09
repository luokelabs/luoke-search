import Foundation
@testable import LuokeSearchKit

/// A stand-in for luoke-core on its own Unix socket, answering as V1 §2 says: `GET /tasks` and `/v1/embed`, with
/// refusals queued up by the test. Its vectors are fake (words hashed into 768 dimensions): they test the plumbing,
/// never the search quality. Never the real hub: the socket is a fresh path in /tmp (AF_UNIX paths must be short).
final class FakeHub: @unchecked Sendable {
    struct Request {
        let method: String
        let target: String
        let headers: [String: String]
        let body: Data
    }

    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var _requests: [Request] = []
    private var _refusals: [(status: Int, json: [String: Any])] = []
    private var _tasksRefusals: [(status: Int, json: [String: Any])] = []
    private var _status = "available"
    private var _reason: String?
    private var _space: String? = "embeddinggemma-2/1"
    private var _tasksVersion = "v1"
    private var _batch = 32
    private var _maxChars = 32_000
    private var _maxTotalChars = 320_000
    private var stopped = false
    private var _takesMedia = false
    private var _imageBudgets = [70, 140, 280, 560, 1120]
    private var _failAudio = false
    private var _failImages: String?
    private var _answerSpace: String?
    private var _answersOtherSpace = false
    private var _zeroVectors = false
    private var _batchChange: (after: Int, to: Int)?
    private var _spaceChange: (after: Int, to: String?)?
    private var _embeds = 0
    private var _background: (state: String, reasons: [String])?
    /// Reads a request 4 KB at a time, this long apart (a server busy elsewhere); 0: at once.
    private var _readPause: TimeInterval = 0
    var readPause: TimeInterval {
        get { lock.withLock { _readPause } }
        set { lock.withLock { _readPause = newValue } }
    }
    /// How long each embedding request takes.
    private var _delay: TimeInterval = 0
    var delay: TimeInterval {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }

    var requests: [Request] { lock.withLock { _requests } }
    var embedRequests: [Request] { requests.filter { $0.target.hasSuffix("/v1/embed") } }
    var status: String {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    /// Why the task is as it is (`/tasks` → `reason`): "battery", a download's progress…
    var reason: String? {
        get { lock.withLock { _reason } }
        set { lock.withLock { _reason = newValue } }
    }
    /// The machine's background state (`/tasks` → `background`); nil: not in the answer at all.
    var background: (state: String, reasons: [String])? {
        get { lock.withLock { _background } }
        set { lock.withLock { _background = newValue } }
    }
    var tasksRequests: Int { requests.filter { $0.method == "GET" && $0.target == "/tasks" }.count }
    var space: String? {
        get { lock.withLock { _space } }
        set { lock.withLock { _space = newValue; _tasksVersion += "+" } }
    }
    /// Changing a parameter changes the tasks version every answer carries, as luoke-core does.
    var batch: Int {
        get { lock.withLock { _batch } }
        set { lock.withLock { _batch = newValue; _tasksVersion += "+" } }
    }
    var maxChars: Int {
        get { lock.withLock { _maxChars } }
        set { lock.withLock { _maxChars = newValue; _tasksVersion += "+" } }
    }
    /// After this many embed requests, the batch becomes `to` (a tier change on battery, mid-run).
    func changeBatch(to batch: Int, afterRequests count: Int) {
        lock.withLock { _batchChange = (count, batch) }
    }
    /// Every picture fails on its own with this error (`embed_failed`: the engine failed for now).
    var failImages: String? {
        get { lock.withLock { _failImages } }
        set { lock.withLock { _failImages = newValue } }
    }
    /// Embed answers say this vector space, whatever `/tasks` says.
    func answerSpace(_ space: String?) {
        lock.withLock { _answerSpace = space; _answersOtherSpace = true }
    }
    /// After this many embed requests, answers say this vector space instead (the model swapped again, mid-run).
    func changeAnswerSpace(to space: String?, afterRequests count: Int) {
        lock.withLock { _spaceChange = (count, space) }
    }
    /// Text vectors come back all zeros (a broken engine).
    var zeroVectors: Bool {
        get { lock.withLock { _zeroVectors } }
        set { lock.withLock { _zeroVectors = newValue } }
    }
    var embedSpace: String? { lock.withLock { _answersOtherSpace ? _answerSpace : _space } }
    var maxTotalChars: Int {
        get { lock.withLock { _maxTotalChars } }
        set { lock.withLock { _maxTotalChars = newValue } }
    }

    /// Takes pictures and sound as luoke-core's multimodal draft says (`image_batch` 8, `audio_batch` 2).
    var takesMedia: Bool {
        get { lock.withLock { _takesMedia } }
        set { lock.withLock { _takesMedia = newValue; _tasksVersion += "+" } }
    }
    var imageBudgets: [Int] {
        get { lock.withLock { _imageBudgets } }
        set { lock.withLock { _imageBudgets = newValue } }
    }
    /// Every sound input fails on its own (`audio_unreadable`), as one luoke-core can't decode would.
    var failAudio: Bool {
        get { lock.withLock { _failAudio } }
        set { lock.withLock { _failAudio = newValue } }
    }
    var inputRequests: [[[String: Any]]] {
        requests.compactMap { (try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any])?["inputs"] as? [[String: Any]] }
    }

    /// The next embed requests are refused with these, in order.
    func refuse(_ status: Int, _ json: [String: Any], times: Int = 1) {
        lock.withLock { for _ in 0..<times { _refusals.append((status, json)) } }
    }

    /// The next `GET /tasks` is refused with this (luoke-core too busy to say).
    func refuseTasks(_ status: Int, _ json: [String: Any]) {
        lock.withLock { _tasksRefusals.append((status, json)) }
    }

    init() throws {
        path = "/tmp/lsfh-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 16) == 0 else { throw Database.Failure(message: "fake hub: bind failed") }
        Thread { [self] in serve() }.start()
    }

    deinit { stop() }

    func stop() {
        let first = lock.withLock { () -> Bool in defer { stopped = true }; return !stopped }
        guard first else { return }
        // Wake the accept loop with one last connection, then close.
        _ = try? UnixHTTP.request(socket: path, method: "GET", target: "/stop", timeout: 1)
        close(listener)
        unlink(path)
    }

    private func serve() {
        while true {
            let connection = accept(listener, nil, nil)
            if connection < 0 { return }
            if lock.withLock({ stopped }) { close(connection); return }
            // A client that gave up (its timeout) has closed: answering it must not kill the tests with SIGPIPE.
            var noSignal: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            handle(connection)
            close(connection)
        }
    }

    private func handle(_ connection: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var expected: Int?
        let pause = readPause
        while true {
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
            let count = read(connection, &buffer, pause > 0 ? 4096 : buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
            if expected == nil, let end = data.firstRange(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).lowercased()
                let length = head.components(separatedBy: "\r\n")
                    .first { $0.hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                expected = end.upperBound + length
            }
            if let expected, data.count >= expected { break }
        }
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return }
        var lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let request = Request(method: String(first[0]), target: String(first[1]), headers: headers,
                              body: Data(data[end.upperBound...]))
        lock.withLock { _requests.append(request) }
        let (status, json) = answer(request)
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let version = lock.withLock { _tasksVersion }
        var response = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        response += "X-Luoke-Contract: 1\r\nX-Luoke-Tasks-Version: \(version)\r\nConnection: close\r\n\r\n"
        var out = Data(response.utf8)
        out.append(body)
        out.withUnsafeBytes { _ = write(connection, $0.baseAddress!, $0.count) }
    }

    private func answer(_ request: Request) -> (Int, [String: Any]) {
        if request.method == "GET", request.target == "/tasks" {
            if let refusal = lock.withLock({ _tasksRefusals.isEmpty ? nil : _tasksRefusals.removeFirst() }) {
                return (refusal.status, refusal.json)
            }
            return lock.withLock {
                (200, ["contract": 1, "tier": "32",
                       "background": _background.map { ["state": $0.state, "reasons": $0.reasons] as [String: Any] }
                           as Any? ?? NSNull(),
                       "tasks": ["luoke-search.embed": [
                    "kind": "embed", "main": true, "status": _status, "reason": _reason as Any? ?? NSNull(),
                    "progress": NSNull(),
                    "vector_space": _space as Any? ?? NSNull(),
                    "params": (["batch": _batch, "max_tokens": 2048, "max_chars": _maxChars,
                                "max_total_chars": _maxTotalChars] as [String: Any]).merging(_takesMedia ? [
                                    "image_batch": 8, "image_budgets": _imageBudgets, "audio_batch": 2,
                                    "max_image_bytes": 4_000_000, "max_audio_bytes": 2_000_000, "max_audio_secs": 30,
                                ] : [:]) { a, _ in a },
                ] as [String: Any]]] as [String: Any])
            }
        }
        guard request.method == "POST", request.target == "/tasks/luoke-search.embed/v1/embed" else {
            return (403, ["code": "unknown_accessory", "message": "no such task", "retry_after": NSNull()])
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.withLock {
            _embeds += 1
            if let change = _batchChange, _embeds > change.after {
                _batch = change.to
                _tasksVersion += "+"
                _batchChange = nil
            }
            if let change = _spaceChange, _embeds > change.after {
                _answerSpace = change.to
                _answersOtherSpace = true
                _spaceChange = nil
            }
        }
        if let refusal = lock.withLock({ _refusals.isEmpty ? nil : _refusals.removeFirst() }) {
            return (refusal.status, refusal.json)
        }
        if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
           let inputs = json["inputs"] as? [[String: Any]] {
            return mediaAnswer(inputs)
        }
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let texts = json["texts"] as? [String], !texts.isEmpty, texts.count <= batch else {
            return (400, ["code": "invalid_request", "message": "bad texts", "retry_after": NSNull()])
        }
        if texts.contains(where: { $0.unicodeScalars.count > maxChars })
            || texts.reduce(0, { $0 + $1.unicodeScalars.count }) > maxTotalChars {
            return (413, ["code": "input_too_long", "message": "too long", "retry_after": NSNull()])
        }
        let vectors = zeroVectors ? texts.map { _ in [Float](repeating: 0, count: 768) } : texts.map { Self.vector($0) }
        return (200, ["vectors": vectors, "dims": 768, "model": "fake",
                      "vector_space": embedSpace as Any? ?? NSNull(), "ms": 1])
    }

    /// Words (and pairs of Chinese characters) hashed into 768 signed dimensions, prompts stripped.
    static func vector(_ prompt: String) -> [Float] {
        var text = prompt
        if let range = text.range(of: "query: ") ?? text.range(of: "text: ") { text = String(text[range.upperBound...]) }
        var vector = [Float](repeating: 0, count: 768)
        vector[0] = 0.01   // never all zero
        var tokens = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !Script.hasUnspaced($0) }
        let han = Array(text.unicodeScalars.filter(Script.isUnspaced).map(Character.init))
        if han.count >= 2 { for index in 0..<(han.count - 1) { tokens.append(String(han[index...index + 1])) } }
        for token in tokens {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in token.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
            vector[Int(hash % 768)] += (hash >> 63) == 0 ? 1 : -1
        }
        return VectorMath.normalized(vector)
    }
}

extension FakeHub {
    /// The draft's answer to `inputs`: a vector per input, or null and a reason for one that fails.
    fileprivate func mediaAnswer(_ inputs: [[String: Any]]) -> (Int, [String: Any]) {
        guard takesMedia, !inputs.isEmpty else {
            return (400, ["code": "invalid_request", "message": "no inputs", "retry_after": NSNull()])
        }
        let images = inputs.filter { $0["image"] != nil }, sound = inputs.filter { $0["audio"] != nil }
        if images.count > 8 || sound.count > 2
            || images.contains(where: { !imageBudgets.contains(($0["budget"] as? Int) ?? -1) }) {
            return (400, ["code": "invalid_request", "message": "over the limits", "retry_after": NSNull()])
        }
        var vectors: [Any] = [], errors: [Any] = []
        for input in inputs {
            if input["audio"] != nil, failAudio {
                vectors.append(NSNull())
                errors.append("audio_unreadable")
                continue
            }
            if input["image"] != nil, let failure = failImages {
                vectors.append(NSNull())
                errors.append(failure)
                continue
            }
            let payload = (input["image"] ?? input["audio"] ?? input["text"]) as? String ?? ""
            // Sampled across the whole payload: pictures share their headers.
            let sample = String(payload.enumerated().filter { $0.offset % 97 == 0 }.map(\.element))
            vectors.append(Self.vector("text: " + sample))
            errors.append(NSNull())
        }
        return (200, ["vectors": vectors, "errors": errors, "dims": 768, "model": "fake",
                      "vector_space": embedSpace as Any? ?? NSNull(), "ms": 1])
    }
}
