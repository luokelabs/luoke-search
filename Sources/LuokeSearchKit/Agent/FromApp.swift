import Darwin
import Foundation
import Security

/// Whether 螺壳's main body started this process. The program inside 螺壳.app reads under 螺壳's Full Disk Access
/// whoever starts it (macOS counts a program by where it is), so as it ships it runs only for 螺壳, but for `status`
/// and help. 螺壳 starts it with a socket on descriptor 3: the channel of `LUOKE_HOST_FD` for the resident, and one that
/// answers every request with failed for the `settings` runs. The check:
///
/// 1. descriptor 3 is a Unix stream socket;
/// 2. the other end is held by the parent (`LOCAL_PEERPID`: the last process to read or write it), and the parent
///    runs, right now, the main program of this same app: its signature (by the kernel's audit token for it, so the
///    program running, not one on disk) is Apple-anchored, from this program's team, with the app's identifier, and
///    its file (`proc_pidpath`) is `Contents/MacOS/<CFBundleExecutable>`;
/// 3. only then a hello goes out whose id is new random bytes, and the line that comes back carries that id;
/// 4. after it the other end is still the parent and the parent still runs the same image (the audit token's pid
///    version, which changes with every exec).
///
/// Why in this order: the audit token for a socket's other end is the one of the program its pid runs when asked,
/// not when it wrote (measured on macOS 27), so checking after the answer alone lets a parent answer, then exec into
/// the main body (same pid). Here the parent must already be the main body before there is anything to answer, the
/// answer can't be written ahead (the id is new), and a process the parent left holding the other end answers under
/// its own pid.
public enum FromApp {
    /// The descriptor 螺壳 hands over.
    public static let descriptor: Int32 = 3
    /// The exit code when it wasn't 螺壳.
    public static let refusedExitCode: Int32 = 77
    /// What the program as it ships runs for anyone.
    public static let free: Set<String> = ["status", "help", "-h", "--help"]
    /// The token 螺壳 gave in its answer to hello (the resident's: `serve` lets in only requests that carry it); nil
    /// before the check, for the `settings` runs, and with a 螺壳 that gives none. Set once, before anything is served.
    public nonisolated(unsafe) private(set) static var token: String?

    /// nil when 螺壳 started this process; otherwise why not, for a person. After it, descriptor 3 stays open only
    /// when it's the channel the rest of the run uses (`LUOKE_HOST_FD=3`), and no child gets it.
    public static func check(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let me = path(of: getpid()) else { return "不是螺壳起的（读不到自己的程序路径）" }
        guard let app = app(of: me) else { return "不是螺壳起的（不在螺壳.app 里）" }
        var answer: Data?
        let why = check(descriptor: descriptor, parent: { getppid() }, path: path(of:), allowed: [app.main],
                        signed: { signedAsApp(app.identifier, token: $0) }, wait: 5, answer: { answer = $0 })
        if why == nil {
            token = answer.flatMap(token(in:))
            if environment[Opener.hostVariable] == "3" {
                _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            } else {
                close(descriptor)
            }
        }
        return why
    }

    /// Steps 1–4 on `fd`; `parent`, `path` and `signed` (nil when the token's program is the app's main body) are the
    /// system's, swapped in tests. `answer` gets 螺壳's answer to hello, once the check has passed.
    static func check(descriptor fd: Int32, parent: () -> pid_t, path: (pid_t) -> String?, allowed: [String],
                      signed: (audit_token_t) -> String?, wait: TimeInterval, answer: (Data) -> Void = { _ in }) -> String? {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return "不是螺壳起的（没有螺壳给的通道）" }
        var type: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &size) == 0, type == SOCK_STREAM else { return "不是螺壳起的（通道不对）" }
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0, Int32(address.ss_family) == AF_UNIX else { return "不是螺壳起的（通道不对）" }
        // This runs before serve ignores SIGPIPE: an other end already closed must not end the process silently.
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let up = parent()
        guard up > 1, let before = peer(fd), before.pid == up else { return "不是螺壳起的（通道那头不是起它的进程）" }
        if let why = signed(before.token) { return "不是螺壳起的（\(why)）" }
        guard let program = path(up) else { return "不是螺壳起的（读不到起它的程序）" }
        guard allowed.contains(program) else { return "不是螺壳起的（起它的是 \(program)）" }

        guard let nonce = randomHex(16) else { return "不是螺壳起的（取不到随机数）" }
        guard writeLine(fd, Data(#"{"id":"\#(nonce)","method":"hello"}"#.utf8)) else { return "不是螺壳起的（通道写不进）" }
        guard let line = readLine(fd, wait: wait) else { return "不是螺壳起的（通道那头没答）" }
        guard let reply = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], reply["id"] as? String == nonce
        else { return "不是螺壳起的（答的不是这一句）" }
        guard parent() == up, let after = peer(fd), after.pid == up, after.version == before.version
        else { return "不是螺壳起的（答话的不是起它的进程）" }
        answer(line)
        return nil
    }

    /// The token in an answer to hello: `{"id":"…","result":{"status":"ok","token":"…"}}`.
    static func token(in reply: Data) -> String? {
        guard let message = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let result = message["result"] as? [String: Any], result["status"] as? String == "ok",
              let token = result["token"] as? String, (16...256).contains(token.utf8.count) else { return nil }
        return token
    }

    /// The process at the other end of `fd` (`LOCAL_PEERPID`) and the kernel's audit token for the program it runs now
    /// (`LOCAL_PEERTOKEN`): its pid and pid version (changes with exec).
    struct Peer { let pid: pid_t; let version: UInt32; let token: audit_token_t }

    static func peer(_ fd: Int32) -> Peer? {
        let solLocal: Int32 = 0, localPeerPID: Int32 = 2, localPeerToken: Int32 = 6    // <sys/un.h>
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, solLocal, localPeerPID, &pid, &size) == 0 else { return nil }
        var token = audit_token_t()
        size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, solLocal, localPeerToken, &token, &size) == 0,
              size == socklen_t(MemoryLayout<audit_token_t>.size), pid_t(bitPattern: token.val.5) == pid else { return nil }
        return Peer(pid: pid, version: token.val.7, token: token)
    }

    /// nil when the program the audit token names is valid now and signed as this app's main body: Apple-anchored,
    /// from this program's own team, with the app's identifier.
    static func signedAsApp(_ identifier: String, token: audit_token_t) -> String? {
        guard let team = ownTeam() else { return "自己没有开发者签名" }
        guard !identifier.isEmpty, identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return "认不出螺壳的标识" }
        var token = token
        let data = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return "读不到起它的程序的签名" }
        let text = #"anchor apple generic and identifier "\#(identifier)" and certificate leaf[subject.OU] = "\#(team)""#
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return "认不出螺壳的标识" }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess ? nil : "起它的程序不是签好名的螺壳"
    }

    /// This program's team (from its own signature); nil when it has none (ad hoc, unsigned).
    static func ownTeam() -> String? {
        var code: SecCode?, staticCode: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess
        else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The app `program` is in: `<app>/Contents/Helpers/luoke-search` → its main program,
    /// `<app>/Contents/MacOS/<CFBundleExecutable of <app>/Contents/Info.plist>`, and its `CFBundleIdentifier`.
    static func app(of program: String) -> (main: String, identifier: String)? {
        let helpers = (program as NSString).deletingLastPathComponent
        let contents = (helpers as NSString).deletingLastPathComponent
        guard (helpers as NSString).lastPathComponent == "Helpers", (contents as NSString).lastPathComponent == "Contents",
              let data = FileManager.default.contents(atPath: contents + "/Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = plist["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/"), name != ".", name != "..",
              let identifier = plist["CFBundleIdentifier"] as? String, !identifier.isEmpty
        else { return nil }
        return (contents + "/MacOS/" + name, identifier)
    }

    /// The file a process runs.
    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    static func randomHex(_ count: Int) -> String? {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func writeLine(_ fd: Int32, _ line: Data) -> Bool {
        let bytes = [UInt8](line + Data([0x0a]))
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return false }
            sent += n
        }
        return true
    }

    /// One line read a byte at a time (nothing past it is taken off the channel), within `wait` seconds.
    static func readLine(_ fd: Int32, wait: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(wait)
        var line = Data()
        while line.count < 1 << 16 {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let polled = poll(&ready, 1, Int32(left * 1000) + 1)
            if polled < 0 && errno == EINTR { continue }
            guard polled > 0 else { return nil }
            var byte: UInt8 = 0
            let n = read(fd, &byte, 1)
            if n < 0 && errno == EINTR { continue }
            guard n == 1 else { return nil }
            if byte == 0x0a { return line }
            line.append(byte)
        }
        return nil
    }
}
