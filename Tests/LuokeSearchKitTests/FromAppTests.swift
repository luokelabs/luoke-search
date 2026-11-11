import Darwin
import Foundation
import Testing
@testable import LuokeSearchKit

// Whether 螺壳 started this process (`FromApp`): a socket pair in this process plays the channel, this process (or a
// shell it starts) the one that answers.
struct FromAppTests {
    private func pair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        fds.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }     // tests running alongside start processes too
        return (fds[0], fds[1])
    }

    /// Answers the one line on `fd` from a thread of this process, as 螺壳 does: the same id back.
    private func answerOnce(_ fd: Int32) {
        Thread {
            guard let line = FromApp.readLine(fd, wait: 5),
                  let hello = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = hello["id"] as? String
            else { return }
            _ = FromApp.writeLine(fd, Data(#"{"id":"\#(id)","result":{"status":"ok"}}"#.utf8))
        }.start()
    }

    /// Whether anything is waiting to be read on `fd`.
    private func pending(_ fd: Int32) -> Bool {
        var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&ready, 1, 0) > 0
    }

    /// Starts `/bin/sh -c script` with `fd` as its descriptor 3.
    private func shell(_ script: String, holding fd: Int32) -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fd, 3)
        let args: [String] = ["/bin/sh", "-c", script]
        let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, "/bin/sh", &actions, nil, argv, nil) == 0 else { return -1 }
        return pid
    }

    private func reap(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    /// The shell line that answers the hello on descriptor 3 with its id.
    private let echo = #"IFS= read -r l <&3; id=$(printf %s "$l" | sed 's/.*"id":"\([0-9a-f]*\)".*/\1/'); printf '{"id":"%s","result":{}}\n' "$id" >&3"#

    private let main = "/Applications/螺壳.app/Contents/MacOS/LuokeCore"
    private var me: pid_t { getpid() }
    private func path(_ program: String) -> (pid_t) -> String? { { $0 == getpid() ? program : "/somewhere/else" } }
    private let signed: (audit_token_t) -> String? = { _ in nil }

    @Test func takesTheParentThatAnswers() throws {
        let (search, body) = try pair()
        defer { close(search); close(body) }
        answerOnce(body)
        #expect(FromApp.check(descriptor: search, parent: { me }, path: path(main), allowed: [main], signed: signed, wait: 5) == nil)
    }

    @Test func refusesAnotherProgramBeforeSayingAnything() throws {
        let (search, body) = try pair()
        defer { close(search); close(body) }
        let why = FromApp.check(descriptor: search, parent: { me }, path: path("/tmp/x.app/Contents/MacOS/LuokeCore"),
                                allowed: [main], signed: signed, wait: 5)
        #expect(why?.contains("起它的是 /tmp/x.app") == true)
        #expect(!pending(body))
    }

    @Test func refusesAParentNotSignedAsTheApp() throws {
        let (search, body) = try pair()
        defer { close(search); close(body) }
        var named: pid_t = 0
        let why = FromApp.check(descriptor: search, parent: { me }, path: path(main), allowed: [main],
                                signed: { named = pid_t(bitPattern: $0.val.5); return "起它的程序不是签好名的螺壳" }, wait: 5)
        #expect(why?.contains("不是签好名的螺壳") == true)
        #expect(named == me)
        #expect(!pending(body))
    }

    @Test func refusesWithoutASocket() throws {
        var p: [Int32] = [-1, -1]
        #expect(pipe(&p) == 0)
        defer { close(p[0]); close(p[1]) }
        #expect(FromApp.check(descriptor: p[1], parent: { me }, path: path(main), allowed: [main], signed: signed, wait: 1)?
            .contains("没有螺壳给的通道") == true)
        #expect(FromApp.check(descriptor: 1000, parent: { me }, path: path(main), allowed: [main], signed: signed, wait: 1)?
            .contains("没有螺壳给的通道") == true)
    }

    @Test func refusesWhenNobodyAnswers() throws {
        let (search, body) = try pair()
        defer { close(search); close(body) }
        #expect(FromApp.check(descriptor: search, parent: { me }, path: path(main), allowed: [main], signed: signed, wait: 0.2)?
            .contains("没答") == true)
    }

    /// A line put on the channel before the check (an answer written ahead, then exec) doesn't carry the new id.
    @Test func refusesAnAnswerWrittenAhead() throws {
        let (search, body) = try pair()
        defer { close(search); close(body) }
        #expect(FromApp.writeLine(body, Data(#"{"id":0,"result":{"status":"ok"}}"#.utf8)))
        #expect(FromApp.check(descriptor: search, parent: { me }, path: path(main), allowed: [main], signed: signed, wait: 1)?
            .contains("答的不是这一句") == true)
    }

    /// Another process used the other end last: refused before the hello.
    @Test func refusesWhenAnotherProcessHoldsTheOtherEnd() throws {
        let (search, body) = try pair()
        defer { close(search) }
        let pid = shell(#"printf 'x\n' >&3; sleep 5"#, holding: body)
        close(body)
        defer { reap(pid) }
        #expect(FromApp.readLine(search, wait: 5) == Data("x".utf8))
        let why = FromApp.check(descriptor: search, parent: { me }, path: path(main), allowed: [main], signed: signed, wait: 5)
        #expect(why?.contains("通道那头不是起它的进程") == true)
    }

    /// Another process answers the hello, with the right id: the answer names that process.
    @Test func refusesAnAnswerFromAnotherProcess() throws {
        let (search, body) = try pair()
        defer { close(search) }
        let pid = shell("sleep 0.5; " + echo, holding: body)
        close(body)
        defer { reap(pid) }
        let why = FromApp.check(descriptor: search, parent: { me }, path: path(main), allowed: [main], signed: signed, wait: 5)
        #expect(why?.contains("不是起它的进程") == true)
    }

    /// The parent turns itself into the main body with exec (same pid, the right program, signed) and leaves the
    /// answering to a process of its own: refused (here `/bin/sleep` plays the main body).
    @Test func refusesAParentThatBecameTheMainBodyByExec() throws {
        let (search, body) = try pair()
        defer { close(search) }
        let pid = shell("printf 'x\\n' >&3; (sleep 0.5; \(echo)) & exec /bin/sleep 5", holding: body)
        close(body)
        defer { reap(pid) }
        #expect(FromApp.readLine(search, wait: 5) == Data("x".utf8))
        let deadline = Date().addingTimeInterval(5)
        while FromApp.path(of: pid) != "/bin/sleep", Date() < deadline { usleep(10_000) }
        let why = FromApp.check(descriptor: search, parent: { pid }, path: FromApp.path(of:), allowed: ["/bin/sleep"],
                                signed: { FromApp.path(of: pid_t(bitPattern: $0.val.5)) == "/bin/sleep" ? nil : "不是" }, wait: 3)
        #expect(why != nil)
        #expect(why?.contains("不是起它的进程") == true || why?.contains("没答") == true)
    }

    /// The other end goes away just before the hello: a reason, not a SIGPIPE (the check runs before serve ignores it;
    /// without `SO_NOSIGPIPE` the write ends the test run). Usually 写不进; 没答 if a process another test starts holds a
    /// copy of the other end for a moment.
    @Test func survivesAnOtherEndThatClosed() throws {
        let (search, body) = try pair()
        defer { close(search) }
        let why = FromApp.check(descriptor: search, parent: { me }, path: path(main), allowed: [main],
                                signed: { _ in close(body); return nil }, wait: 1)
        #expect(why?.contains("写不进") == true || why?.contains("没答") == true)
        var on: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(search, SOL_SOCKET, SO_NOSIGPIPE, &on, &size) == 0 && on != 0)
    }

    @Test func peerIsThisProcessForItsOwnPair() throws {
        let (search, body) = try pair()
        defer { close(search); close(body) }
        let peer = try #require(FromApp.peer(search))
        #expect(peer.pid == me)
        #expect(peer.version != 0)
    }

    @Test func appReadsTheBundleExecutableAndIdentifier() throws {
        let contents = FileManager.default.temporaryDirectory.appendingPathComponent("fromapp-\(UUID().uuidString)/螺壳.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent().deletingLastPathComponent()) }
        func plist(_ name: String, _ identifier: String? = "ai.example.app") throws {
            var p: [String: Any] = ["CFBundleExecutable": name, "LSUIElement": true]
            if let identifier { p["CFBundleIdentifier"] = identifier }
            try PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        try plist("LuokeCore")
        let app = FromApp.app(of: contents.path + "/Helpers/luoke-search")
        #expect(app?.main == contents.path + "/MacOS/LuokeCore")
        #expect(app?.identifier == "ai.example.app")
        #expect(FromApp.app(of: "/usr/local/bin/luoke-search") == nil)
        try plist("../x")
        #expect(FromApp.app(of: contents.path + "/Helpers/luoke-search") == nil)
        try plist("LuokeCore", nil)
        #expect(FromApp.app(of: contents.path + "/Helpers/luoke-search") == nil)
    }

    /// Unsigned or ad hoc (as tests run): no team, so nothing passes as the app; an identifier that would change the
    /// requirement's meaning is never taken.
    @Test func signedAsAppNeedsATeamAndAPlainIdentifier() throws {
        let (search, body) = try pair()
        defer { close(search); close(body) }
        let token = try #require(FromApp.peer(search)).token
        if FromApp.ownTeam() == nil {
            #expect(FromApp.signedAsApp("ai.luoke.core", token: token) == "自己没有开发者签名")
        }
        #expect(FromApp.signedAsApp(#"ai.luoke.core" or anchor trusted or identifier "x"#, token: token) != nil)
    }

    @Test func pathIsTheRunningFile() {
        let mine = FromApp.path(of: getpid())
        #expect(mine.map { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) } == true)
        #expect(FromApp.path(of: 0x7fff_fff0) == nil)
    }
}
