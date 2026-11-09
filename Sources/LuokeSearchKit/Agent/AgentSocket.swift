import Foundation

/// The agent's way in (agent tool protocol §2): HTTP/1.1 on a Unix socket in the data directory, one JSON-RPC message
/// per `POST /mcp`. The socket's folder is 700 and the socket 600: only this account gets in. One process serves it;
/// a socket left behind by one that died is removed, one that someone still answers on is not touched. The socket
/// file goes when serving stops.
public final class AgentSocket: @unchecked Sendable {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        /// Another process answers on this socket: this one can't start, and nothing is wrong with it.
        public var alreadyServing = false
    }

    /// The exit code of a run that found another one serving, so whoever started it can tell that from a failure.
    public static let alreadyServingExitCode: Int32 = 3

    static let maxBody = 1 << 20
    static let maxHead = 16 << 10
    /// Requests answered at once; more are turned away (503) rather than each holding a thread and a descriptor.
    var maxConnections = 32
    /// How long one request may take to arrive, all of it.
    var requestDeadline: TimeInterval = 30
    /// How long its answer may take to be taken, all of it: a client that never reads it is let go (pre-release
    /// review, should-fix 10: 32 such clients held every connection, and new requests got 503, for as long as they
    /// liked).
    var answerDeadline: TimeInterval = 30
    private var open = 0

    public let path: String
    let server: MCPServer
    private var listener: Int32 = -1
    private var inode: ino_t = 0
    private let lock = NSLock()
    private var stopped = false

    public init(path: String, server: MCPServer) {
        self.path = path
        self.server = server
    }

    /// Starts answering on a thread of its own.
    public func start() throws {
        try Self.prepare(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failure(description: "can't make a socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= UnixHTTP.maxPathBytes else { throw Failure(description: "socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // Every connection accepted inherits this: a client gone before its answer is written gets EPIPE, not the
        // whole process SIGPIPE (pre-release review, must-fix 1).
        guard bound == 0, Self.noSignal(listener), listen(listener, 16) == 0 else {
            close(listener)
            throw Failure(description: "can't listen on \(path)")
        }
        chmod(path, 0o600)
        var info = stat()
        lstat(path, &info)
        inode = info.st_ino
        let thread = Thread { [self] in serve() }
        thread.name = "luoke-search agent socket"
        thread.start()
    }

    /// Stops answering and removes the socket file (if it's still ours).
    public func stop() {
        let first = lock.withLock { () -> Bool in defer { stopped = true }; return !stopped }
        guard first, listener >= 0 else { return }
        _ = try? UnixHTTP.request(socket: path, method: "GET", target: "/", timeout: 1)   // wakes the accept loop
        close(listener)
        var info = stat()
        if lstat(path, &info) == 0, info.st_ino == inode { unlink(path) }
    }

    /// The folder made private; a socket nobody answers on any more removed; one in use refused.
    static func prepare(_ path: String) throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK else { throw Failure(description: "\(path) exists and isn't a socket") }
        do {
            _ = try UnixHTTP.request(socket: path, method: "GET", target: "/", timeout: 1)
            throw Failure(description: "another luoke-search is already serving on \(path)", alreadyServing: true)
        } catch UnixHTTP.Failure.notListening {
            unlink(path)   // left behind: nobody listens
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(description: "another luoke-search is already serving on \(path)", alreadyServing: true)
        }
    }

    /// Only stopping ends this loop: a failed accept (interrupted, a client gone, out of descriptors) is waited out.
    private func serve() {
        while true {
            let connection = accept(listener, nil, nil)
            let failure = errno
            if lock.withLock({ stopped }) {
                if connection >= 0 { close(connection) }
                return
            }
            if connection < 0 {
                if failure == EBADF || failure == EINVAL { return }   // the listener is gone
                if [EMFILE, ENFILE, ENOBUFS, ENOMEM].contains(failure) { usleep(100_000) }
                continue
            }
            // Before anything is written to it, 503 included. It fails (EINVAL) only on a connection whose client
            // has already gone: nothing to answer there.
            guard Self.noSignal(connection) else {
                close(connection)
                continue
            }
            let admitted = lock.withLock { () -> Bool in
                guard open < maxConnections else { return false }
                open += 1
                return true
            }
            guard admitted else {
                reply(connection, 503)
                close(connection)
                continue
            }
            let thread = Thread { [self] in
                answer(connection)
                close(connection)
                lock.withLock { open -= 1 }
            }
            // Room for what runs on it: a thread's default 512 KB isn't (pre-release review, must-fix 2).
            thread.stackSize = 4 << 20
            thread.start()
        }
    }

    /// SO_NOSIGPIPE on `socket`; false if it can't be set.
    static func noSignal(_ socket: Int32) -> Bool {
        var on: Int32 = 1
        return setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private func answer(_ connection: Int32) {
        var wait = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let incoming = read(connection)
        guard case let .request(method, target, body) = incoming else {
            // Not a word at all (a probe, a client that changed its mind): nobody to answer.
            if case .bad = incoming { reply(connection, 400) }
            return
        }
        guard target == "/mcp" else { return reply(connection, 404) }
        guard method == "POST" else { return reply(connection, 405) }
        guard !body.isEmpty else { return reply(connection, 400) }
        guard body.count <= Self.maxBody else { return reply(connection, 413) }
        if let answer = server.handle(json: body) {
            reply(connection, 200, answer, type: "application/json")
        } else {
            reply(connection, 202)
        }
    }

    /// What came in on a connection.
    private enum Incoming {
        /// Not a byte before the client closed.
        case nothing
        /// Not a request: no end to the head, a head too large, too slow.
        case bad
        /// The method, the target and the body (one byte over the limit: too large to read).
        case request(String, String, Data)
    }

    /// The request line and the body. The head may be 16 KB, the whole request may take `requestDeadline`: a client
    /// that never finishes is let go.
    private func read(_ connection: Int32) -> Incoming {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var expected: Int?
        var head = ""
        let deadline = Self.now() + requestDeadline
        while true {
            let left = deadline - Self.now()
            guard left > 0 else { return .bad }
            var wait = Self.timeout(left)
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            let count = Darwin.read(connection, &buffer, buffer.count)
            if count == 0, data.isEmpty { return .nothing }   // closed before a byte came
            if count <= 0 { break }
            let before = data.count
            data.append(buffer, count: count)
            // Only where the new bytes are can the end of the head have arrived.
            if expected == nil,
               let end = data[max(0, before - 3)...].firstRange(of: Data("\r\n\r\n".utf8)) {
                head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
                let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                if length > Self.maxBody {
                    let parts = head.split(separator: " ")
                    return parts.count >= 2 ? .request(String(parts[0]), String(parts[1]), Data(count: Self.maxBody + 1)) : .bad
                }
                expected = end.upperBound + length
            }
            if let expected, data.count >= expected { break }
            if expected == nil, data.count > Self.maxHead { return .bad }
        }
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return .bad }
        let parts = head.split(separator: " ")
        guard parts.count >= 2 else { return .bad }
        return .request(String(parts[0]), String(parts[1]), Data(data[end.upperBound...]))
    }

    /// Seconds on a clock the time of day being set back doesn't move (deadlines).
    static func now() -> TimeInterval { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }

    /// A socket's wait for what's left of a deadline: at most 10 s, and never 0, which would be no limit at all.
    static func timeout(_ left: TimeInterval) -> timeval {
        let wait = min(max(left, 0.001), 10)
        return timeval(tv_sec: Int(wait), tv_usec: Int32(wait.truncatingRemainder(dividingBy: 1) * 1_000_000))
    }

    private func reply(_ connection: Int32, _ status: Int, _ body: Data = Data(), type: String = "text/plain") {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed",
                      413: "Payload Too Large", 503: "Service Unavailable"][status] ?? "Error"
        var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        let deadline = Self.now() + answerDeadline
        out.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                // A write waits at most what's left of the deadline (SO_SNDTIMEO), then gives up the connection.
                let left = deadline - Self.now()
                guard left > 0 else { return }
                var wait = Self.timeout(left)
                setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
                let sent = write(connection, raw.baseAddress! + offset, raw.count - offset)
                if sent > 0 {
                    offset += sent
                } else if sent < 0, errno == EAGAIN || errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}
