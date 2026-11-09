import Foundation

/// A tool that can't do what was asked: a sentence for the user and a reason code (`not_ready`, `needs_setup`,
/// `stale`, `failed`, `invalid`…), maybe with a card to put in place of the one tapped (agent tool protocol §5).
public struct ToolFailure: Error, @unchecked Sendable {
    public let code: String
    public let message: String
    public let card: [[String: Any]]?

    public init(_ code: String, _ message: String, card: [[String: Any]]? = nil) {
        self.code = code
        self.message = message
        self.card = card
    }
}

/// The MCP data-layer subset of agent tool protocol version 1 (MCP 2026-07-28, stateless): `server/discover`,
/// `resources/list`, `resources/read`, `tools/list`, `tools/call`. `initialize` and `ping` are answered too, so any
/// MCP client can use `luoke-search mcp` over stdio. Messages in, messages out: the transports (Unix socket, stdio)
/// are separate. Modelled on luoke-agent's reference `mcp.py`, answer for answer.
public final class MCPServer: @unchecked Sendable {
    public static let protocolVersion = "2026-07-28"
    static let userAction = "ai.luoke/user-action"

    public struct Tool {
        public let name: String
        public let title: String
        public let description: String
        public let schema: [String: Any]
        public let readOnly: Bool
        /// Extra `_meta` in `tools/list` (`ai.luoke/where: mac`).
        public let meta: [String: Any]
        /// Arguments and the request's `_meta` in; `text` (a sentence for the user) and `structured` out.
        public let run: ([String: Any], [String: Any]) throws -> (text: String, structured: [String: Any])

        public init(name: String, title: String, description: String, schema: [String: Any], readOnly: Bool = true,
                    meta: [String: Any] = [:],
                    run: @escaping ([String: Any], [String: Any]) throws -> (text: String, structured: [String: Any])) {
            self.name = name
            self.title = title
            self.description = description
            self.schema = schema
            self.readOnly = readOnly
            self.meta = meta
            self.run = run
        }

        var spec: [String: Any] {
            var spec: [String: Any] = ["name": name, "title": title, "description": description, "inputSchema": schema,
                                       "annotations": ["readOnlyHint": readOnly, "destructiveHint": false]]
            if !meta.isEmpty { spec["_meta"] = meta }
            return spec
        }
    }

    public struct Resource {
        public let uri: String
        public let name: String
        public let read: () throws -> Any
    }

    /// Resources of bytes under a prefix (`thumb/<id>`), answered as `blob` (base64). Not listed: their ids come in
    /// other answers. `find` runs inside the one-request lock (it may look at the index) and gives what makes the
    /// bytes, which runs outside it (it may take a while); nil from either: there's no such one.
    public struct Blobs {
        public let prefix: String
        public let mimeType: String
        public let find: (String) -> (() -> Data?)?
    }

    let name: String
    let version: String
    private var tools: [String: Tool] = [:]
    private var order: [String] = []
    private var resources: [String: Resource] = [:]
    private var blobs: [Blobs] = []
    /// One request at a time: the index, its searcher and the settings are used from one thread at a time.
    private let lock = NSLock()
    /// Where a tool's own faults go: stderr is its log. A log nobody reads any more is no reason to stop, and only
    /// `serve` ignores SIGPIPE: `mcp` would die here, with the client still waiting for its answer.
    var logged: (String) -> Void = {
        _ = fcntl(STDERR_FILENO, F_SETNOSIGPIPE, 1)
        try? FileHandle.standardError.write(contentsOf: Data("luoke-search: \($0)\n".utf8))
    }

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }

    public func add(_ tool: Tool) {
        precondition(!tool.name.hasPrefix("agent."), "agent. is the agent's own")
        tools[tool.name] = tool
        order.append(tool.name)
    }

    public func add(_ resource: Resource) {
        resources[resource.uri] = resource
    }

    public func add(_ blobs: Blobs) {
        self.blobs.append(blobs)
    }

    /// One JSON-RPC message in; the answer, or nil for a notification. A blob is made after the lock.
    public func handle(_ message: Any) -> [String: Any]? {
        var later: (() -> [String: Any])?
        let answer = lock.withLock { dispatch(message, later: &later) }
        return later?() ?? answer
    }

    /// For the transports: bytes in, bytes out (nil: nothing to send back).
    public func handle(json data: Data) -> Data? {
        guard !Self.nestsDeeper(data) else { return Self.encode(Self.error(nil, -32600, "请求套得太深")) }
        guard let message = try? JSONSerialization.jsonObject(with: data) else {
            return Self.encode(Self.error(nil, -32700, "不是 JSON"))
        }
        return handle(message).flatMap(Self.encode)
    }

    /// Objects and arrays in a request nest at most this deep. Foundation's parser recurses, a level of objects at a
    /// time, and used to overflow a connection thread's stack at about 480 (pre-release review, must-fix 2); requests
    /// here are a few levels deep.
    static let maxDepth = 64

    /// Whether `data` nests objects and arrays deeper than `maxDepth`, counting outside strings only.
    static func nestsDeeper(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            var depth = 0, inString = false, escaped = false
            for byte in bytes {
                if inString {
                    if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                } else if byte == UInt8(ascii: "\"") {
                    inString = true
                } else if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                    depth += 1
                    if depth > maxDepth { return true }
                } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                    depth -= 1
                }
            }
            return false
        }
    }

    /// Never throws: an answer that isn't valid JSON (an infinite number in it) becomes an internal error.
    static func encode(_ value: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else {
            return try? JSONSerialization.data(withJSONObject: error(nil, -32603, "答复编不出来"))
        }
        return try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
    }

    /// What a request said, as an answer repeats it: at most `maxShown` code points (pre-release review, should-fix
    /// 10: an unknown method or tool name of 900 KB came back whole, in every answer). Not characters: one letter
    /// with 450 000 accents on it is one character.
    static func shown(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > maxShown else { return text }
        return String(String.UnicodeScalarView(scalars.prefix(maxShown))) + "…"
    }

    static let maxShown = 100

    /// An id is echoed back in full (JSON-RPC): a string one longer than this isn't taken.
    static let maxIDLength = 256

    /// JSON-RPC ids are strings, finite numbers or null; anything else isn't echoed back.
    static func validID(_ id: Any?) -> Bool {
        switch id {
        case nil, is NSNull: return true
        case let text as String: return text.utf16.count <= maxIDLength
        case let number as NSNumber:
            return CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.isFinite
        default: return false
        }
    }

    /// A missing or null object is an empty one (as luoke-agent's mcp.py treats it).
    static func object(_ value: Any?) -> [String: Any]? {
        switch value {
        case nil, is NSNull: return [:]
        case let object as [String: Any]: return object
        default: return nil
        }
    }

    /// `later`: set instead of answering when the answer is made outside the lock (a blob).
    private func dispatch(_ message: Any, later: inout (() -> [String: Any])?) -> [String: Any]? {
        guard let message = message as? [String: Any], message["jsonrpc"] as? String == "2.0",
              let method = message["method"] as? String else {
            let id = (message as? [String: Any])?["id"]
            return Self.error(Self.validID(id) ? id : nil, -32600, "不是 JSON-RPC 2.0 请求")
        }
        guard message.keys.contains("id") else { return nil }   // notifications: nothing to do in this subset
        let id = message["id"]
        guard Self.validID(id) else { return Self.error(nil, -32600, "id 要是不太长的字符串、数或 null") }
        guard let params = Self.object(message["params"]) else { return Self.error(id, -32602, "params 要是对象") }
        guard let meta = Self.object(params["_meta"]) else { return Self.error(id, -32602, "_meta 要是对象") }
        if let version = meta["io.modelcontextprotocol/protocolVersion"] as? String, version != Self.protocolVersion {
            return Self.error(id, -32602, "不支持这个协议版本", data: ["supportedVersions": [Self.protocolVersion]])
        }
        do {
            switch method {
            case "server/discover":
                return Self.result(id, discover())
            case "initialize":
                // The classic MCP handshake, for stdio clients; the agent's stateless subset doesn't need it.
                // Only the version spoken here is offered, whatever the client asked for.
                return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": [
                    "protocolVersion": Self.protocolVersion,
                    "capabilities": capabilities(),
                    "serverInfo": ["name": name, "version": version],
                ] as [String: Any]]
            case "ping":
                return Self.result(id, [:])
            case "resources/list":
                return Self.result(id, ["resources": resources.values.sorted { $0.uri < $1.uri }.map {
                    ["uri": $0.uri, "name": $0.name, "mimeType": "application/json"]
                }])
            case "resources/read":
                let uri = params["uri"] as? String
                let missing = Self.error(id, -32002, "没有这个资源", data: ["uri": uri.map { Self.shown($0) as Any } ?? NSNull()])
                if let uri, let blobs = blobs.first(where: { uri.hasPrefix($0.prefix) }),
                   let make = blobs.find(String(uri.dropFirst(blobs.prefix.count))) {
                    later = {
                        guard let data = make() else { return missing }
                        return Self.result(id, ["contents": [["uri": uri, "mimeType": blobs.mimeType,
                                                              "blob": data.base64EncodedString()]]])
                    }
                    return nil
                }
                guard let uri, let resource = resources[uri] else { return missing }
                let value = try resource.read()
                let text = try (value as? String) ?? String(decoding: JSONSerialization.data(
                    withJSONObject: value, options: [.withoutEscapingSlashes]), as: UTF8.self)
                return Self.result(id, ["contents": [["uri": uri, "mimeType": "application/json", "text": text]]])
            case "tools/list":
                return Self.result(id, ["tools": order.compactMap { tools[$0]?.spec }])
            case "tools/call":
                return call(id, params, meta)
            default:
                return Self.error(id, -32601, "没有这个方法：\(Self.shown(method))")
            }
        } catch {
            return fault(id, method, params, error)
        }
    }

    /// The agent is told nothing of a tool's own fault; the log gets one line, or it would be gone without a trace.
    /// The error's type and never its text, which may quote the user's files.
    private func fault(_ id: Any?, _ method: String, _ params: [String: Any], _ error: Error) -> [String: Any] {
        logged("\(which(method, params)) 出错 \(type(of: error))")
        return Self.error(id, -32603, "工具内部出错")
    }

    /// Which request that was: the method, and the tool or resource if it's one registered here. Never a string as
    /// the agent sent it, which can be anything. Only methods handled here get this far.
    func which(_ method: String, _ params: [String: Any]) -> String {
        switch method {
        case "tools/call":
            return (params["name"] as? String).flatMap { tools[$0] }.map { "\(method) \($0.name)" } ?? method
        case "resources/read":
            return (params["uri"] as? String).flatMap { resources[$0] }.map { "\(method) \($0.uri)" } ?? method
        default:
            return method
        }
    }

    private func capabilities() -> [String: Any] {
        var capabilities: [String: Any] = [:]
        if !tools.isEmpty { capabilities["tools"] = [String: Any]() }
        if !resources.isEmpty { capabilities["resources"] = [String: Any]() }
        return capabilities
    }

    private func discover() -> [String: Any] {
        ["supportedVersions": [Self.protocolVersion], "capabilities": capabilities(),
         "_meta": ["io.modelcontextprotocol/serverInfo": ["name": name, "version": version]]]
    }

    private func call(_ id: Any?, _ params: [String: Any], _ meta: [String: Any]) -> [String: Any] {
        guard let name = params["name"] as? String, let tool = tools[name] else {
            return Self.error(id, -32602, "没有这个工具：\(Self.shown(params["name"] as? String ?? ""))")
        }
        guard let arguments = Self.object(params["arguments"]) else { return Self.error(id, -32602, "arguments 要是对象") }
        // Calls that change something come only from the user's tap on a card (§5).
        if !tool.readOnly && !Self.validUserAction(meta[Self.userAction]) {
            return Self.result(id, Self.toolError("needs_user_action", "这个操作要你在卡片上点过才能执行。"))
        }
        let missing = (tool.schema["required"] as? [String] ?? []).filter { arguments[$0] == nil }
        if !missing.isEmpty {
            return Self.result(id, Self.toolError("invalid", "缺少参数：" + missing.joined(separator: "、")))
        }
        do {
            let (text, structured) = try tool.run(arguments, meta)
            var result: [String: Any] = ["content": [["type": "text", "text": text]], "isError": false]
            if !structured.isEmpty { result["structuredContent"] = structured }
            return Self.result(id, result)
        } catch let failure as ToolFailure {
            return Self.result(id, Self.toolError(failure.code, failure.message, card: failure.card))
        } catch {
            return fault(id, "tools/call", params, error)
        }
    }

    static func validUserAction(_ value: Any?) -> Bool {
        guard let action = value as? [String: Any] else { return false }
        return ["surfaceId", "componentId", "at"].allSatisfy { (action[$0] as? String)?.isEmpty == false }
    }

    static func toolError(_ code: String, _ message: String, card: [[String: Any]]? = nil) -> [String: Any] {
        var structured: [String: Any] = ["code": code]
        if let card { structured["card"] = card }
        return ["content": [["type": "text", "text": message]], "structuredContent": structured, "isError": true]
    }

    static func result(_ id: Any?, _ result: [String: Any]) -> [String: Any] {
        var result = result
        result["resultType"] = "complete"
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    static func error(_ id: Any?, _ code: Int, _ message: String, data: Any? = nil) -> [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": error]
    }
}
