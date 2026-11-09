import Foundation

/// HTTP/1.1 over a Unix domain socket, one request per connection (luoke-core answers `Connection: close`).
/// URLSession can't reach a Unix socket, so this is a small blocking client on POSIX sockets.
enum UnixHTTP {
    struct Response {
        let status: Int
        /// Header names in lower case.
        let headers: [String: String]
        let body: Data
    }

    enum Failure: Error, Equatable {
        /// Nothing listens there: the socket file is missing, or no one accepts on it.
        case notListening
        case timedOut
        case malformed(String)
    }

    /// AF_UNIX paths are limited to 104 bytes on macOS (with the terminating zero).
    static let maxPathBytes = 103

    static func request(socket path: String, method: String, target: String, headers: [String: String] = [:],
                        body: Data? = nil, timeout: TimeInterval) throws -> Response {
        // For the whole request, sending included: a server reading a little now and then can't stretch it (each
        // write would otherwise get the full timeout again).
        let deadline = Date().addingTimeInterval(timeout)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.notListening }
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var wait = Self.wait(timeout)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathBytes else { throw Failure.malformed("socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure.notListening }

        var head = "\(method) \(target) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        var allHeaders = headers
        if let body {
            allHeaders["Content-Type"] = allHeaders["Content-Type"] ?? "application/json"
            allHeaders["Content-Length"] = String(body.count)
        }
        for (name, value) in allHeaders.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var request = Data(head.utf8)
        if let body { request.append(body) }
        // A server may answer before it has read everything (a 413 for a body too large) and close: the write then
        // fails, but its answer is there to read (review B-13).
        var sendFailed = false
        do { try send(fd, request, until: deadline) } catch Failure.notListening { sendFailed = true }
        let data = try receive(fd, until: deadline)
        if sendFailed, data.firstRange(of: Data("\r\n\r\n".utf8)) == nil { throw Failure.notListening }
        return try parse(data)
    }

    private static func send(_ fd: Int32, _ data: Data, until deadline: Date) throws {
        // Non-blocking while sending (MSG_DONTWAIT alone doesn't stop a Unix socket's write from waiting); reading
        // waits again, by SO_RCVTIMEO.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                // Waits for room, then writes only what fits: a blocking write would wait again each time the
                // server reads a little, its timeout starting over.
                let left = deadline.timeIntervalSinceNow
                guard left > 0 else { throw Failure.timedOut }
                var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let polled = poll(&ready, 1, Int32(min(ceil(left * 1000), Double(Int32.max))))
                if polled < 0 {
                    if errno == EINTR { continue }
                    throw Failure.notListening
                }
                if polled == 0 { throw Failure.timedOut }
                let sent = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if sent < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw Failure.notListening
                }
                offset += sent
            }
        }
    }

    /// Until the answer is complete (its Content-Length, or the last chunk), the server closes, or `deadline` (for
    /// the whole answer, not each read: a server sending a byte now and then can't hold it open).
    private static func receive(_ fd: Int32, until deadline: Date) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw Failure.timedOut }
            var wait = Self.wait(left)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                if complete(data) { return data }
                continue
            }
            if count == 0 { return data }
            if errno == EINTR { continue }
            if errno == EAGAIN { throw Failure.timedOut }
            if !data.isEmpty { return data }   // reset after it answered
            throw Failure.malformed("read failed")
        }
    }

    /// A socket timeout of `seconds`, at least a millisecond: zero would mean none at all.
    static func wait(_ seconds: TimeInterval) -> timeval {
        let seconds = max(seconds, 0.001)
        return timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
    }

    /// Whether an answer has all of its body.
    static func complete(_ data: Data) -> Bool {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).lowercased()
        let body = data.count - end.upperBound
        for line in head.components(separatedBy: "\r\n") {
            if line.hasPrefix("content-length:"), let length = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) {
                return body >= length
            }
            if line.hasPrefix("transfer-encoding:"), line.contains("chunked") {
                return data.suffix(5) == Data("0\r\n\r\n".utf8)
            }
        }
        return false
    }

    static func parse(_ data: Data) throws -> Response {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { throw Failure.malformed("no header end") }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else { throw Failure.malformed("status line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(data[end.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try dechunk(body)
        } else if let length = headers["content-length"].flatMap(Int.init), body.count > length {
            body = body.prefix(length)
        }
        return Response(status: status, headers: headers, body: body)
    }

    static func dechunk(_ data: Data) throws -> Data {
        var out = Data()
        var rest = data[...]
        while let lineEnd = rest.firstRange(of: Data("\r\n".utf8)) {
            let sizeText = String(decoding: rest[..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw Failure.malformed("chunk size")
            }
            if size == 0 { return out }
            let start = lineEnd.upperBound
            guard rest.distance(from: start, to: rest.endIndex) >= size else { throw Failure.malformed("short chunk") }
            let stop = rest.index(start, offsetBy: size)
            out.append(rest[start..<stop])
            rest = rest[stop...].dropFirst(2)
        }
        return out
    }
}
