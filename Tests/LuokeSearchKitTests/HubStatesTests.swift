import Foundation
import Testing
@testable import LuokeSearchKit

// How luoke-search reports luoke-core's states and goes on without it (coverage gap 5, 10-22): what search_status
// says, filling in vectors when the limits or the vector space change under it or an error ends the run, and a
// question without a vector. Short notes, or pictures made up through `VectorFiller.next`: nothing here reads a
// picture, so none of it needs `ReadsPictures`.

/// A socket nobody listens on: luoke-core isn't running.
fileprivate func nobodysHub() -> Hub {
    Hub(socket: "/tmp/lsfh-nobody-\(UUID().uuidString.prefix(6)).sock", environment: [:])
}

/// The service on `texts`' index, asking `hub`.
fileprivate func searchService(_ texts: Texts, hub: Hub) throws -> SearchService {
    try SearchService(directory: DataDirectory(url: texts.scratch.url.appendingPathComponent("data")), hub: hub,
                      opener: Opened().opener, home: texts.scratch.path)
}

/// Makes the index refuse vectors, as a full disk would; vectors cleared (a new space) still go through.
fileprivate func fillUp(_ store: IndexStore) throws {
    try store.db.execute("""
        CREATE TRIGGER full BEFORE UPDATE OF vec ON segments WHEN NEW.vec IS NOT NULL
        BEGIN SELECT RAISE(ABORT, 'database or disk is full'); END
        """)
}

/// How many texts each embed request carried.
fileprivate func textsPerRequest(_ fake: FakeHub) -> [Int] {
    fake.embedRequests.compactMap {
        ((try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any])?["texts"] as? [String]
    }.map(\.count)
}

struct HubStatusTests {
    @Test("search_status follows what luoke-core says of the task: ready, downloading, busy, not on this Mac")
    func statesFromTheTask() throws {
        let texts = try Texts(1)
        let service = try searchService(texts, hub: texts.hub)
        let cases: [(status: String, reason: String?, state: String, note: String?)] = [
            ("available", nil, "available", nil),
            ("downloading", "下载模型 40%", "downloading", "下载模型 40%"),
            ("needs_download", "要先下载模型", "downloading", "要先下载模型"),
            ("paused", "battery", "busy", "battery"),
            ("warming_up", nil, "busy", "warming_up"),   // a status this version doesn't know: not now
            ("unsupported", "no GPU", "unsupported", "no GPU"),
        ]
        for (status, reason, state, note) in cases {
            texts.fake.status = status
            texts.fake.reason = reason
            let said = try service.status()
            let hub = try #require(said["hub"] as? [String: Any])
            #expect(hub["state"] as? String == state, "\(status)")
            #expect(hub["note"] as? String == note, "\(status)")
            // The sentence the agent reads ends with why.
            #expect(service.statusSentence(said).hasSuffix((note ?? "1 段在等螺壳算向量") + "。"), "\(status)")
        }
    }

    @Test("search_status, as the agent calls it, says luoke-core isn't running")
    func notRunning() throws {
        let texts = try Texts(1)
        let server = AgentTools.server(try searchService(texts, hub: nobodysHub()))
        let reply = server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
            "name": "search_status", "arguments": [String: Any](),
            "_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"],
        ] as [String: Any]])
        let result = try #require(reply?["result"] as? [String: Any])
        let hub = try #require((result["structuredContent"] as? [String: Any])?["hub"] as? [String: Any])
        #expect(hub["state"] as? String == "not_running")
        #expect(hub["note"] as? String == "螺壳没有在运行")
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(text == "已索引 1 个，1 段在等螺壳算向量，螺壳没有在运行。")
    }

    @Test("search_status says busy when luoke-core turns even /tasks away, and ready once it answers")
    func tooBusyToSay() throws {
        let texts = try Texts(1)
        let service = try searchService(texts, hub: texts.hub)
        texts.fake.refuseTasks(503, ["code": "busy", "reason": "interactive", "retry_after": 5])
        let busy = try #require(try service.status()["hub"] as? [String: Any])
        #expect(busy["state"] as? String == "busy")
        #expect(busy["note"] as? String == "螺壳这次没算出来")
        let ready = try #require(try service.status()["hub"] as? [String: Any])
        #expect(ready["state"] as? String == "available")
        #expect(ready["note"] is NSNull)
    }

    @Test("search_status says unsupported when luoke-core doesn't know luoke-search yet")
    func unknownAccessory() throws {
        let texts = try Texts(1)
        // An older luoke-core: /tasks doesn't list the task luoke-search asks for.
        let older = Hub(socket: texts.fake.path, task: "luoke-search-next.embed", environment: [:])
        let hub = try #require(try searchService(texts, hub: older).status()["hub"] as? [String: Any])
        #expect(hub["state"] as? String == "unsupported")
        #expect(hub["note"] as? String == "这版螺壳还不认识螺壳搜索")
    }
}

struct TextFillerStatesTests {
    @Test("A luoke-core that isn't running, or stops mid-run, ends the run at once, even one told to wait")
    func notRunning() throws {
        let texts = try Texts(2)
        let filler = VectorFiller(store: texts.store, hub: nobodysHub())
        filler.sleep = { _, _ in Issue.record("waited for a luoke-core that isn't there") }
        let report = filler.run(wait: true)
        #expect(report.stoppedBy == .notRunning)
        #expect(report.embedded == 0)
        #expect(try texts.store.counts().waitingForVectors == 2)
        // It quits during a short rest: the next request finds nobody, and the run ends there.
        let gone = try Texts(2)
        gone.fake.refuse(503, ["code": "busy", "reason": "lane_busy", "retry_after_ms": 100])
        let leaving = gone.filler()
        leaving.sleep = { _, _ in gone.fake.stop() }
        let stopped = leaving.run(wait: true)
        #expect(stopped.stoppedBy == .notRunning)
        #expect(stopped.embedded == 0)
        #expect(try gone.store.counts().waitingForVectors == 2)
    }

    @Test("Limits that changed under the run: read again and used as they are, nothing halved or given up")
    func limitsChangedUnderTheRun() throws {
        let texts = try Texts(20)
        texts.fake.batch = 8
        texts.fake.changeBatch(to: 3, afterRequests: 1)   // the second request's eight are refused
        let report = texts.filler().run(wait: false)
        #expect(report.stoppedBy == nil)
        #expect(report.embedded == 20)
        #expect(try texts.store.counts().vectors == 20)
        #expect(textsPerRequest(texts.fake) == [8, 8, 3, 3, 3, 3])   // halving would have sent four
    }

    @Test("Refused for its size with the same limits: the batch is halved until it goes through, then full again")
    func batchHalved() throws {
        let texts = try Texts(8)
        texts.fake.refuse(413, ["code": "input_too_long", "message": "too long", "retry_after": NSNull()])
        texts.fake.refuse(400, ["code": "invalid_request", "message": "bad texts", "retry_after": NSNull()])
        let report = texts.filler().run(wait: false)
        #expect(report.stoppedBy == nil)
        #expect(report.embedded == 8)
        #expect(textsPerRequest(texts.fake) == [8, 4, 2, 6])
    }

    @Test("A single text still refused gets no vector and stays found by its words; the rest go on")
    func singleTextGivenUp() throws {
        let texts = try Texts(3)
        texts.fake.refuse(413, ["code": "input_too_long", "message": "too long", "retry_after": NSNull()], times: 2)
        let report = texts.filler().run(wait: false)
        #expect(report.stoppedBy == nil)
        #expect(report.embedded == 2)
        #expect(textsPerRequest(texts.fake) == [3, 1, 1, 1])
        let counts = try texts.store.counts()
        #expect(counts.vectors == 2 && counts.waitingForVectors == 0)
        var given: [String] = []
        try texts.store.db.query("""
            SELECT i.path FROM segments s JOIN items i ON i.id = s.item
            WHERE s.kind = 'text' AND s.vec IS NULL AND s.todo IS NULL
            """) { given.append($0.text(0) ?? "") }
        #expect(given.count == 1)
        // Not asked for again.
        #expect(texts.filler().run(wait: false).embedded == 0)
        #expect(texts.fake.embedRequests.count == 4)
        // Still found by the words of its text (no file's name has them).
        let answer = try Searcher(store: texts.store).search("份笔记的内容")
        #expect(answer.hits.contains { $0.path == given.first })
    }

    @Test("The vector space changing again after one switch ends the run, nothing stored; the next run settles in it")
    func spaceKeepsChanging() throws {
        let texts = try Texts(3)
        texts.fake.answerSpace("other/2")
        texts.fake.changeAnswerSpace(to: "other/3", afterRequests: 1)
        let report = texts.filler().run(wait: false)
        #expect(report.stoppedBy == .failed("luoke-core's vector space keeps changing"))
        #expect(report.embedded == 0)
        #expect(texts.fake.embedRequests.count == 2)   // one switch, then it stops: never a loop
        #expect(try texts.store.counts().vectors == 0)
        #expect(try texts.store.counts().waitingForVectors == 3)
        #expect(try texts.store.vectorSpace == "other/2")   // the one switch it made
        let next = texts.filler().run(wait: false)
        #expect(next.stoppedBy == nil)
        #expect(next.embedded == 3)
        #expect(try texts.store.vectorSpace == "other/3")
    }

    @Test("An index that can't take the vectors (a full disk) ends the run, saying why; nothing is lost")
    func indexCantBeWritten() throws {
        let texts = try Texts(3)
        try fillUp(texts.store)
        let filler = texts.filler()
        filler.sleep = { _, _ in Issue.record("waited on an error that isn't luoke-core's") }
        let report = filler.run(wait: true)
        guard case .failed(let why)? = report.stoppedBy else {
            Issue.record("\(String(describing: report.stoppedBy))")
            return
        }
        #expect(why.contains("disk is full"))
        #expect(report.embedded == 0)
        #expect(texts.fake.embedRequests.count == 1)
        #expect(try texts.store.counts().waitingForVectors == 3)
    }
}

/// One scanned PDF's pages waiting for picture vectors, never read: the test makes up what making each one gives
/// (`VectorFiller.next`). A fake luoke-core that takes pictures. Holds the scratch folder while used.
fileprivate final class Pages {
    let scratch: Scratch, store: IndexStore, fake: FakeHub, hub: Hub
    let segments: [Int64]

    init(_ count: Int) throws {
        scratch = try Scratch()
        store = try scratch.store()
        // There on this Mac: the filler passes over files that aren't (`MediaInputs.isHere`). Its pictures come from
        // `filler.next`, not from it.
        try scratch.write("files/扫描件.pdf", "")
        let id = try store.add(FoundFile(path: scratch.path + "/files/扫描件.pdf", kind: .pdf, size: 1, mtime: 1,
                                         inode: 1, device: 1))
        guard let item = try store.item(id: id) else { throw Database.Failure(message: "no item") }
        let pages = (1...count).map { Piece(kind: .page, loc: Double($0), text: "", vector: .media) }
        try store.store(Reading(pieces: pages), for: item, reader: 1)
        var segments: [Int64] = []
        try store.db.query("SELECT id FROM segments WHERE todo = 'media' ORDER BY id") { segments.append($0.int(0)) }
        self.segments = segments
        fake = try FakeHub()
        fake.takesMedia = true
        hub = Hub(socket: fake.path, environment: [:])
    }

    deinit { fake.stop() }   // its socket and thread go with it

    /// A filler whose pictures come out as `outcomes`, in order; no real waiting.
    func filler(_ outcomes: [MediaInputs.Outcome]) -> VectorFiller {
        let filler = VectorFiller(store: store, hub: hub)
        filler.sleep = { _, _ in }
        var left = outcomes
        filler.next = { _ in left.isEmpty ? nil : left.removeFirst() }
        return filler
    }

    /// Every waiting page, made.
    func filler() -> VectorFiller { filler(segments.map(Self.picture)) }

    static func picture(_ segment: Int64) -> MediaInputs.Outcome {
        .made(MediaInputs.Made(segment: segment, input: .image(Data("第 \(segment) 页".utf8), budget: 280)))
    }

    /// A page's `todo` and `tries`.
    func state(_ segment: Int64) throws -> (todo: String?, tries: Int64) {
        var state: (String?, Int64) = (nil, -1)
        try store.db.query("SELECT todo, tries FROM segments WHERE id = ?", [.int(segment)]) {
            state = ($0.text(0), $0.int(1))
        }
        return state
    }

    /// How many pictures each request carried.
    var sizes: [Int] { fake.inputRequests.map(\.count) }
}

struct PictureFillerStatesTests {
    @Test("Pictures that can never be made are given up; one that failed for now is counted; one not here yet waits")
    func whatMakingThemGave() throws {
        let pages = try Pages(3)
        let (gone, broken, later) = (pages.segments[0], pages.segments[1], pages.segments[2])
        let report = pages.filler([.impossible(gone, "the page isn't there"),
                                   .failedForNow(broken, "couldn't be decoded just now"),
                                   .later(later, "only in iCloud")]).run(wait: false)
        #expect(report.stoppedBy == nil)
        #expect(report.mediaFailed == 1 && report.mediaRetrying == 1 && report.embeddedMedia == 0)
        #expect(pages.fake.inputRequests.isEmpty)
        #expect(try pages.state(gone).todo == nil)
        #expect(try pages.state(broken) == ("media", 1))
        #expect(try pages.state(later) == ("media", 0))
    }

    @Test("Pictures refused for their size are sent again a half at a time")
    func halved() throws {
        let pages = try Pages(4)
        pages.fake.refuse(413, ["code": "input_too_long", "message": "too long", "retry_after": NSNull()])
        let report = pages.filler().run(wait: false)
        #expect(report.stoppedBy == nil)
        #expect(report.embeddedMedia == 4)
        #expect(pages.sizes == [4, 2, 2])
        #expect(try pages.store.counts().waitingForMedia == 0)
    }

    @Test("A single picture still refused waits for the next run, counted; it goes through then")
    func singlePictureLater() throws {
        let pages = try Pages(1)
        let page = pages.segments[0]
        pages.fake.refuse(400, ["code": "invalid_request", "message": "over the limits", "retry_after": NSNull()])
        let report = pages.filler().run(wait: false)
        #expect(report.stoppedBy == nil)
        #expect(report.embeddedMedia == 0 && report.mediaRetrying == 1)
        #expect(try pages.state(page) == ("media", 1))
        let next = pages.filler().run(wait: false)
        #expect(next.embeddedMedia == 1)
        #expect(try pages.state(page) == (nil, 0))
    }

    @Test("Pictures refused because the tier changed under the run are neither sent again nor counted: they wait")
    func tierChanged() throws {
        let pages = try Pages(2)
        let filler = pages.filler()
        let make = filler.next
        filler.next = { source in
            pages.fake.imageBudgets = [70, 140]   // while they're made, luoke-core moves to a tier without 280
            return make(source)
        }
        let report = filler.run(wait: false)
        #expect(report.stoppedBy == nil)
        #expect(report.embeddedMedia == 0 && report.mediaRetrying == 0 && report.mediaFailed == 0)
        #expect(pages.sizes == [2])   // refused once, then nothing left this tier takes
        #expect(try pages.segments.map { try pages.state($0) }.allSatisfy { $0 == ("media", 0) })
    }

    @Test("Pictures turned away: a short rest is waited out; anything else ends the run, the pictures still waiting")
    func turnedAway() throws {
        let rested = try Pages(2)
        rested.fake.refuse(503, ["code": "busy", "reason": "lane_busy", "retry_after_ms": 200])
        let filler = rested.filler()
        var slept: [TimeInterval] = []
        filler.sleep = { seconds, _ in slept.append(seconds) }
        let report = filler.run(wait: false)
        #expect(slept == [0.25])
        #expect(report.stoppedBy == nil && report.embeddedMedia == 2)
        let busy = try Pages(2)
        busy.fake.refuse(503, ["code": "busy", "reason": "interactive", "retry_after": 30])
        let stopped = busy.filler().run(wait: false)
        #expect(stopped.stoppedBy == .refused(code: "busy", reason: "interactive", retryAfter: 30))
        #expect(stopped.embeddedMedia == 0 && stopped.mediaRetrying == 0)
        #expect(try busy.segments.map { try busy.state($0) }.allSatisfy { $0 == ("media", 0) })
    }

    @Test("An index that can't take the picture vectors ends the run, saying why; the pictures still wait")
    func indexCantBeWritten() throws {
        let pages = try Pages(2)
        try fillUp(pages.store)
        let report = pages.filler().run(wait: false)
        guard case .failed(let why)? = report.stoppedBy else {
            Issue.record("\(String(describing: report.stoppedBy))")
            return
        }
        #expect(why.contains("disk is full"))
        #expect(report.embeddedMedia == 0)
        #expect(try pages.segments.map { try pages.state($0) }.allSatisfy { $0 == ("media", 0) })   // both, untouched
    }
}

struct QueryMeaningStatesTests {
    @Test("Without a vector for the question, the note says why: not on this Mac, not ready, too old, busy")
    func whyNoVector() throws {
        let fake = try FakeHub()
        defer { fake.stop() }
        let hub = Hub(socket: fake.path, environment: [:])
        let cases: [(status: Int, json: [String: Any], note: String)] = [
            (404, ["code": "unsupported", "message": "not on this Mac"], "这台 Mac 上的螺壳不提供按意思搜，只按字词搜"),
            (404, ["code": "task_unavailable", "message": "downloading"], "螺壳还没准备好按意思搜（downloading），只按字词搜"),
            (403, ["code": "unknown_accessory", "message": "who"], "这版螺壳还不认识螺壳搜索，只按字词搜"),
            (503, ["code": "busy", "reason": "interactive", "retry_after": 30], "螺壳这次没算出来，只按字词搜"),
        ]
        for (status, json, note) in cases {
            fake.refuse(status, json)
            let (meaning, said) = QueryMeaning.make("押金", hub: hub)
            #expect(meaning == nil)
            #expect(said == note)
        }
        #expect(fake.embedRequests.count == 4)   // asked once each: only a model still loading is waited for
    }

    @Test("A model still loading is waited for twice at most, then the search goes on by words")
    func notReady() throws {
        let fake = try FakeHub()
        defer { fake.stop() }
        let hub = Hub(socket: fake.path, environment: [:])
        let loading: [String: Any] = ["code": "not_ready", "message": "loading", "retry_after_ms": 1]
        fake.refuse(503, loading)
        let (meaning, note) = QueryMeaning.make("押金", hub: hub)
        #expect(meaning != nil && note == nil)
        #expect(fake.embedRequests.count == 2)
        fake.refuse(503, loading, times: 3)
        let (none, why) = QueryMeaning.make("押金", hub: hub)
        #expect(none == nil && why == "螺壳这次没算出来，只按字词搜")
        #expect(fake.embedRequests.count == 5)   // two waits, then given up
    }

    @Test("Within a budget: a slow vector, or a model loading longer than is left, gives words only at once")
    func withinABudget() throws {
        let fake = try FakeHub()
        defer { fake.stop() }
        let hub = Hub(socket: fake.path, environment: [:])
        _ = try hub.embedTask()   // the limits known, as the resident has them
        fake.delay = 1
        var started = Date()
        let (slow, late) = QueryMeaning.make("押金", hub: hub, within: 0.3)
        #expect(slow == nil && late == "螺壳这次没及时算出来，只按字词搜")
        #expect(Date().timeIntervalSince(started) < 0.9)
        // Without one, as the command line and the evals ask: waited for.
        let (waited, none) = QueryMeaning.make("押金", hub: hub)
        #expect(waited != nil && none == nil)
        fake.delay = 0
        // A long question to a luoke-core reading slowly: the budget holds while sending too.
        fake.readPause = 0.2
        started = Date()
        let long = String(repeating: "押金退还的条件", count: 4000)   // about 84 KB, more than the socket buffers
        #expect(QueryMeaning.make(long, hub: hub, within: 0.5).note == "螺壳这次没及时算出来，只按字词搜")
        #expect(Date().timeIntervalSince(started) < 1.2)
        fake.readPause = 0
        _ = QueryMeaning.make("押金", hub: hub)   // after the fake has read the long one to its end (and answered it)
        // Loading a little longer than twice: waited for as long as the budget lasts.
        let loadingFrom = fake.embedRequests.count
        fake.refuse(503, ["code": "not_ready", "message": "loading", "retry_after_ms": 300], times: 3)
        #expect(QueryMeaning.make("押金", hub: hub, within: 3).0 != nil)
        #expect(fake.embedRequests.count == loadingFrom + 4)
        // A model loading for 2 s more, 1 s left: not waited for, and asked only once.
        let asked = fake.embedRequests.count
        fake.refuse(503, ["code": "not_ready", "message": "loading", "retry_after": 2])
        started = Date()
        let (loading, why) = QueryMeaning.make("押金", hub: hub, within: 1)
        #expect(loading == nil && why == "螺壳还在加载模型，这次只按字词搜")
        #expect(Date().timeIntervalSince(started) < 0.8)
        #expect(fake.embedRequests.count == asked + 1)
        // Loading for a moment, time enough: waited for as before.
        fake.refuse(503, ["code": "not_ready", "message": "loading", "retry_after_ms": 1])
        #expect(QueryMeaning.make("押金", hub: hub, within: 2).0 != nil)
        // Nothing left of it: luoke-core isn't asked at all, not even for the limits (a client yet to read them).
        let before = fake.requests.count
        let fresh = Hub(socket: fake.path, environment: [:])
        #expect(QueryMeaning.make("押金", hub: fresh, within: 0).note == "螺壳这次没及时算出来，只按字词搜")
        #expect(fake.requests.count == before)
    }

    @Test("The agent's search waits for its question's vector only so long, then answers by words and says why")
    func agentSearchWithinItsBudget() throws {
        #expect(SearchService.meaningTimeout == 5)
        let texts = try Texts(3)
        _ = texts.filler().run(wait: false)
        let service = try searchService(texts, hub: texts.hub)
        service.meaningWait = 0.5
        texts.fake.delay = 3
        let started = Date()
        let answer = try service.search("note1", options: SearchOptions())
        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(answer.hits.first?.title == "note1.md")
        #expect(answer.partial && answer.partialReason == "螺壳这次没及时算出来，只按字词搜")
    }

    @Test("A search whose question gets no vector goes by words and says why")
    func wordsOnlyWithTheNote() throws {
        let texts = try Texts(3)
        _ = texts.filler().run(wait: false)
        let service = try searchService(texts, hub: texts.hub)
        let meant = try service.search("note1", options: SearchOptions())
        #expect(meant.partialReason == nil)
        texts.fake.refuse(404, ["code": "unsupported", "message": "not on this Mac"])
        let answer = try service.search("note1", options: SearchOptions())
        #expect(answer.hits.first?.title == "note1.md")
        #expect(answer.partial)
        #expect(answer.partialReason == "这台 Mac 上的螺壳不提供按意思搜，只按字词搜")
    }
}
