import Foundation
import Testing
@testable import LuokeSearchKit

// The whole-branch review of 11bc2ca: searching, the command line, evals and what goes out to the agent.

struct ReviewSearchTests {
    @Test("B-04: two characters that happen to sit together don't make a document match")
    func optionalTermsAlone() throws {
        let scratch = try Scratch()
        try scratch.write("files/活动.md", "# 活动\n猫粮年付八折的活动下周开始。")
        try scratch.write("files/账单.md", "# 账单\n这个月支付八百元的物业费。")
        let store = try scratch.store()
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        _ = try indexer.sync([scratch.path + "/files"])
        try indexer.readPending()
        let query = Query("猫粮年付八折")
        #expect(query.terms.filter { !$0.optional }.map(\.text) == ["猫粮"])
        let hits = try Searcher(store: store).search("猫粮年付八折").hits
        #expect(hits.map(\.title) == ["活动.md"])   // 账单.md only holds 付八
    }

    @Test("B-11: confident is false when nothing was found, null otherwise (no threshold yet)")
    func confidentWhenNothing() throws {
        let library = try Library()
        _ = try library.index()
        let searcher = Searcher(store: library.store)
        #expect(try searcher.search("火星基地").confident == false)
        let found = try searcher.search("押金")
        #expect(!found.hits.isEmpty && found.confident == nil)
    }

    @Test("B-12: an answer marked with a range on a text file counts when the file is found")
    func rangesOnTextFiles() throws {
        let library = try Library()
        _ = try library.index()
        let set = try JSONDecoder().decode(EvalSet.self, from: Data("""
            {"base": "\(library.root)", "queries": [{"q": "marathon pace", "expect": ["notes/running.txt@3-5"]}]}
            """.utf8))
        let searcher = Searcher(store: library.store)
        let report = try Evaluation.run(set, testbed: nil) { try searcher.search($0) }
        #expect(report.all.top1 == 1)
        #expect(report.notes.contains(Evaluation.rangeNote))
    }

    @Test("B-09: an option a command doesn't take is an error; --name=value works; a dev build names its index")
    func commandLine() throws {
        let parsed = try CommandArguments(["押金", "--index=.dev/t", "-n", "3"][...])
        #expect(parsed.value("--index") == ".dev/t" && parsed.value("-n") == "3" && parsed.positional == ["押金"])
        let typo = try CommandArguments(["押金", "--indx", ".dev/t"][...])
        #expect(throws: CommandArguments.Failure.self) { try typo.only(["--index", "-n"]) }
        #expect(throws: CommandArguments.Failure.self) { try CommandArguments(["--json=1"][...]) }
        let none = try CommandArguments(["status"][...])
        #expect(throws: CommandArguments.Failure.self) { try none.dataDirectory(environment: [:], bundle: nil) }
        #expect(try none.dataDirectory(environment: [:], bundle: "ai.luoke.search").isStandard)
        #expect(try !none.dataDirectory(environment: ["LUOKE_SEARCH_HOME": "/tmp/x"], bundle: nil).isStandard)
    }

    @Test("C-09: counting a folder for a plan stops in time, and never lists a folder macOS protects")
    func countingForPlans() throws {
        let scratch = try Scratch()
        for index in 0..<600 { try scratch.write("tree/d\(index / 50)/f\(index).bin", "x") }   // nothing to read
        let (count, more) = SearchService.countFiles(scratch.path + "/tree", until: Date.distantPast)
        #expect(count == 0 && more)   // the clock is looked at though no file counts
        #expect(SearchService.isProtected("/home/x/Documents/工作", home: "/home/x"))
        #expect(SearchService.isProtected("/Volumes/盘", home: "/home/x"))
        #expect(!SearchService.isProtected("/home/x/Projects", home: "/home/x"))
        try FileManager.default.createDirectory(atPath: scratch.path + "/Documents", withIntermediateDirectories: true)
        let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        let service = try SearchService(directory: data, hub: nil, opener: Opened().opener, home: scratch.path)
        var change = SearchService.Change()
        change.addFolders = ["documents"]
        let (_, lines) = try service.plan(change)
        #expect(lines.first?.text.contains("macOS 会先问你") == true)
    }
}

struct ReviewSecretsTests {
    // luoke-mem's own cases (tests/test_sensitive.py, 888b424), so both find alike. A card or ID number keeps its
    // last 4 (10-22), where luoke-mem masks the whole.
    @Test("C-08: credentials are masked where they are; a card or ID number keeps its last 4")
    func masked() {
        for (text, masked) in [("验证码 482913，5 分钟内有效", "验证码 〔验证码〕，5 分钟内有效"),
                               ("482913 是你的验证码", "〔验证码〕 是你的验证码"),
                               ("Your verification code: 774201", "Your verification code: 〔验证码〕"),
                               ("我的密码是 Lk-2026-qwe，别外传", "我的密码是 〔密码〕，别外传"),
                               ("护照号 E12345678", "护照号 〔证件号 ****5678〕"),
                               ("卡号 4111 1111 1111 1111 已绑定", "卡号 〔卡号 ****1111〕 已绑定"),
                               ("卡号 4111-1111-1111-1111", "卡号 〔卡号 ****1111〕"),
                               ("身份证 110101199003070017", "身份证 〔证件号 ****0017〕"),
                               ("身份证 11010119900307001X", "身份证 〔证件号 ****001X〕"),
                               ("身份证 １１０１０１１９９００３０７００１７", "身份证 〔证件号 ****００１７〕"),
                               ("护照号码：E12345678", "护照号码：〔证件号 ****5678〕"),
                               ("passport no. G1234567", "passport no. 〔证件号 ****4567〕"),
                               ("密码\t\t abc12345", "密码\t\t 〔密码〕"),
                               ("验证码   482913", "验证码   〔验证码〕"),
                               ("123456 是您的 验证码", "〔验证码〕 是您的 验证码"),
                               ("key: sk-abc123def456ghi789jkl0", "key: 〔密钥〕"),
                               ("AKIAABCDEFGHIJKLMNOP 是那个", "〔密钥〕 是那个")] {
            #expect(Secrets.mask(text) == masked, "\(text)")
        }
        #expect(Secrets.find("密码是 abc123；验证码 482913").map(\.kind) == ["password", "code"])
    }

    @Test("A long run of whitespace after a keyword takes no time (the rules don't try every way to split it)")
    func longWhitespace() {
        let run = String(repeating: "\u{3000}", count: 20_000)
        let started = Date()
        #expect(Secrets.mask("password" + run + "x") == "password" + run + "x")
        #expect(Secrets.mask("密码" + String(repeating: "\t", count: 4_000)) == "密码" + String(repeating: "\t", count: 4_000))
        #expect(Secrets.mask("密码" + run + "abc12345") == "密码" + run + "〔密码〕")
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test("C-08: what isn't a credential stays")
    func notCredentials() {
        for text in ["手机 138 1234 5678", "订单号 20391837", "月薪 3 万元", "我的账号是 xiaoming", "银行卡尾号 7890",
                     "commit 5fee45b", "https://github.com/luoke/luoke-mem", "打开 GPT-4o-mini 试试", "token 太多了",
                     "4111 1111 1111 1112", "2026-10-19 10:00:00", "职位：产品负责人", ""] {
            #expect(Secrets.mask(text) == text, "\(text)")
        }
    }

    @Test("C-08: a result's snippet goes out masked: in the hits, the card and the answer's text")
    func snippetsMasked() throws {
        let library = try Library()
        try library.scratch.write("files/notes/家里网络.md", "# 家里网络\n路由器在书房。Wi-Fi 密码：abc12345，访客网络另设。")
        _ = try library.index()
        let service = try SearchService(directory: DataDirectory(url: library.scratch.url.appendingPathComponent("data")),
                                        hub: nil, opener: Opened().opener, home: library.scratch.path)
        let server = AgentTools.server(service)
        let answer = server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
            "name": "search_query", "arguments": ["query": "家里网络 路由器"]]])
        let text = String(decoding: try JSONSerialization.data(withJSONObject: answer ?? [:]), as: UTF8.self)
        #expect(text.contains("路由器"))
        #expect(text.contains("〔密码〕"))
        #expect(!text.contains("abc12345"))
        // The index keeps the text as written: on this Mac it's still found by it.
        #expect(try Searcher(store: library.store).search("abc12345").hits.first?.title == "家里网络.md")
    }
}

/// A server on a Unix socket that answers one request as the test says.
final class OneShotServer: @unchecked Sendable {
    let path = "/tmp/lsos-\(UUID().uuidString.prefix(8)).sock"
    private let listener: Int32

    /// `answer` gets the connection after the request's head arrived.
    init(_ answer: @escaping @Sendable (Int32) -> Void) {
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8))
            raw[path.utf8.count] = 0
        }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        listen(listener, 4)
        let accepted = listener
        Thread {
            let connection = accept(accepted, nil, nil)
            guard connection >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 4096), head = Data()
            while head.firstRange(of: Data("\r\n\r\n".utf8)) == nil {
                let count = read(connection, &buffer, buffer.count)
                if count <= 0 { break }
                head.append(buffer, count: count)
            }
            answer(connection)
        }.start()
    }

    deinit {
        close(listener)
        unlink(path)
    }
}

struct ReviewClientTests {
    @Test("B-13: an answer given before the whole request was read is still read")
    func earlyAnswer() throws {
        let server = OneShotServer { connection in
            let reply = "HTTP/1.1 413 X\r\nContent-Type: application/json\r\nContent-Length: 27\r\n\r\n{\"code\": \"input_too_long\"}\n"
            _ = reply.withCString { write(connection, $0, strlen($0)) }
            close(connection)
        }
        let big = Data(repeating: 0x41, count: 8 << 20)
        let answer = try UnixHTTP.request(socket: server.path, method: "POST", target: "/x", body: big, timeout: 5)
        #expect(answer.status == 413)
    }

    @Test("B-13: a complete answer is taken without waiting for the connection to close")
    func keptOpen() throws {
        let server = OneShotServer { connection in
            let reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"
            _ = reply.withCString { write(connection, $0, strlen($0)) }
            Thread.sleep(forTimeInterval: 4)
            close(connection)
        }
        let started = Date()
        let answer = try UnixHTTP.request(socket: server.path, method: "GET", target: "/x", timeout: 10)
        #expect(answer.status == 200 && answer.body == Data("{}".utf8))
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test("B-17: a paragraph pasted as a question is looked at for a limited number of words")
    func longQuestions() {
        let paragraph = (0..<80).map { "词语\($0)号" }.joined(separator: " ")
        let query = Query(paragraph)
        #expect(query.terms.filter { !$0.optional }.count <= Query.maxRequired)
        #expect(query.terms.filter(\.optional).count <= Query.maxOptional)
    }

    @Test("B-21: -n is a whole number from 1 to 50")
    func counts() throws {
        #expect(try CommandArguments(["-n", "-1"][...]).count("-n", default: 10) == 1)
        #expect(try CommandArguments(["-n", "500"][...]).count("-n", default: 10) == 50)
        #expect(try CommandArguments([][...]).count("-n", default: 10) == 10)
        #expect(throws: CommandArguments.Failure.self) { try CommandArguments(["-n", "ten"][...]).count("-n", default: 10) }
    }
}

struct ReviewStoreTests {
    @Test("A-11: what was read is dropped when the item changed, was read or went meanwhile; vectors of another space aren't stored")
    func twoWriters() throws {
        let scratch = try Scratch()
        let file = try scratch.write("files/a.md", "# 甲\n第一版。")
        let store = try scratch.store()
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        _ = try indexer.sync([scratch.path + "/files"])
        let picked = try #require(try store.pending(limit: 1).first)
        // The other process sees it change before this one stores what it read.
        try store.changed(picked.id, to: FoundFile(path: file.path, kind: .doc, size: 99, mtime: picked.mtime + 5,
                                                   inode: picked.inode, device: picked.device))
        try store.store(Reading(pieces: [Piece(kind: .text, loc: 1, text: "旧的内容", vector: .text)]), for: picked, reader: 1)
        #expect(try store.item(id: picked.id)?.state == "pending")
        #expect(try Searcher(store: store).search("旧的内容").hits.isEmpty)
        // Gone meanwhile: nothing thrown, nothing stored.
        let again = try #require(try store.item(id: picked.id))
        try store.remove(picked.id)
        try store.store(Reading(pieces: [Piece(kind: .text, loc: 1, text: "x", vector: .text)]), for: again, reader: 1)
        // Vectors made in a space the index has left.
        try scratch.write("files/b.md", "# 乙\n内容。")
        _ = try indexer.sync([scratch.path + "/files"])
        try indexer.readPending()
        try store.adoptVectorSpace("new/2")
        let todo = try #require(try store.textTodos(limit: 1).first)
        var vector = [Float](repeating: 0, count: VectorMath.dimension)
        vector[0] = 1
        try store.setVectors([(todo.segment, vector)], space: "old/1")
        #expect(try store.counts().vectors == 0)
    }
}

extension ReadsPictures {
    struct ReviewServiceAgentTests {
        @Test("B-18: the vectors' memory is given back after a while without a search")
        func idleRelease() throws {
            let library = try Library()
            _ = try library.index()
            let fake = try FakeHub()
            let hub = Hub(socket: fake.path, environment: [:])
            _ = VectorFiller(store: library.store, hub: hub).run(wait: false)
            let service = try SearchService(directory: DataDirectory(url: library.scratch.url.appendingPathComponent("data")),
                                            hub: hub, opener: Opened().opener, home: library.scratch.path)
            _ = try service.search("押金", options: SearchOptions())
            #expect(service.vectorsLoaded)
            service.releaseVectorsWhenIdle(after: 0.3)
            #expect(eventually(5) { !service.vectorsLoaded })
            _ = try service.search("押金", options: SearchOptions())   // read again when needed
            #expect(service.vectorsLoaded)
        }

        @Test("C-14: a plan of many folders still makes a card the agent can draw")
        func longPlans() throws {
            let plan = SettingsPlan(id: "plan-x", made: 0, basis: Settings())
            let card = Cards.plan(plan, lines: (0..<200).map { SearchService.PlanLine("跳过「文件夹\($0)」") }, surfaceID: "s-plan-x")
            let components = ((card.last?["updateComponents"] as? [String: Any])?["components"] as? [Any])?.count ?? 0
            #expect(components > 0 && components < 200 - 100)   // far inside the protocol's 200
            #expect(ReviewCardTexts.texts(card).contains { $0.text == "另外 181 项" })
        }

        @Test("C-17: outbox answers written from many threads at once are all kept")
        func lockedState() throws {
            let agent = try Agent()
            // Forty folders searched, macOS letting none be read: forty ids the outbox could hold (only those are kept:
            // should-fix 11), each folder's latest item.
            var settings = Settings.load(agent.directory)
            settings.folders = (0..<40).map { agent.library.scratch.path + "/文件夹\($0)" }
            try settings.save(agent.directory)
            var state = ToolState.load(agent.directory)
            for (index, folder) in settings.folders.enumerated() { state.folderItems[folder] = index + 1 }
            try state.save(agent.directory)
            DispatchQueue.concurrentPerform(iterations: 40) { index in
                try? agent.service.acknowledge(SearchService.folderID(settings.folders[index], index + 1), state: "dismissed")
            }
            #expect(ToolState.load(agent.directory).closed.count == 40)
        }

        @Test("C-18: in a dry run a photo's [打开] doesn't open Photos")
        func dryPhotos() throws {
            let photos = FakePhotos([.photo("A1", "IMG_1001.HEIC")])
            let library = try Library()
            _ = try library.index()
            _ = try PhotoIndexing.sync(photos, store: library.store)
            let service = try SearchService(directory: DataDirectory(url: library.scratch.url.appendingPathComponent("data")),
                                            hub: nil, opener: .dry, photos: photos, home: library.scratch.path)
            let id = try #require(try service.search("IMG_1001", options: SearchOptions()).hits.first?.id)
            _ = try service.open(id, reveal: false)
            #expect(photos.opened.isEmpty)
        }
    }
}
