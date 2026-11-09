import Foundation
import Testing
@testable import LuokeSearchKit

struct HubTests {
    @Test func readsTheTaskAndItsParameters() throws {
        let fake = try FakeHub()
        fake.batch = 8
        let task = try Hub(socket: fake.path, environment: [:]).embedTask()
        #expect(task.status == .available)
        #expect(task.vectorSpace == "embeddinggemma-2/1")
        #expect(task.batch == 8)
        #expect(task.maxChars == 32_000)
        let request = try #require(fake.requests.first)
        #expect(request.headers["x-luoke-accessory"] == "luoke-search/\(LuokeSearch.version)")
    }

    @Test func embedsWithPriorityAndNormalizes() throws {
        let fake = try FakeHub()
        let hub = Hub(socket: fake.path, environment: [:])
        let result = try hub.embed([Prompts.query("租赁合同"), Prompts.document(title: nil, text: "押金")],
                                   priority: .userWaiting)
        #expect(result.vectors.count == 2)
        #expect(result.vectors.allSatisfy { abs(VectorMath.cosine($0, $0) - 1) < 1e-5 && $0.count == 768 })
        #expect(result.vectorSpace == "embeddinggemma-2/1")
        let request = try #require(fake.embedRequests.first)
        #expect(request.headers["x-luoke-priority"] == "user-waiting")
        let body = try JSONSerialization.jsonObject(with: request.body) as? [String: [String]]
        #expect(body?["texts"]?.first == "task: search result | query: 租赁合同")
        #expect(body?["texts"]?.last == "title: none | text: 押金")
    }

    @Test func refusalsBecomeErrors() throws {
        let fake = try FakeHub()
        let hub = Hub(socket: fake.path, environment: [:])
        fake.refuse(503, ["code": "busy", "reason": "power_cooldown", "retry_after": 1, "retry_after_ms": 360])
        #expect(throws: HubError.refused(code: "busy", reason: "power_cooldown", retryAfter: 0.36)) {
            try hub.embed(["x"], priority: .background)
        }
        fake.refuse(404, ["code": "unsupported", "message": "not on this Mac", "retry_after": NSNull()])
        #expect(throws: HubError.unsupported("not on this Mac")) { try hub.embed(["x"], priority: .background) }
        fake.refuse(404, ["code": "task_unavailable", "message": "downloading", "retry_after": NSNull()])
        #expect(throws: HubError.unavailable("downloading")) { try hub.embed(["x"], priority: .background) }
        fake.refuse(403, ["code": "unknown_accessory", "message": "who", "retry_after": NSNull()])
        #expect(throws: HubError.unknownAccessory) { try hub.embed(["x"], priority: .background) }
        fake.refuse(503, ["code": "not_ready", "message": "loading", "retry_after": 2])
        #expect(throws: HubError.refused(code: "not_ready", reason: nil, retryAfter: 2)) {
            try hub.embed(["x"], priority: .background)
        }
    }

    @Test func noHubListening() {
        let hub = Hub(socket: "/tmp/lsfh-nobody-\(UUID().uuidString.prefix(6)).sock", environment: [:])
        #expect(throws: HubError.notRunning) { try hub.embedTask() }
    }

    @Test func developmentRunsNeverFallBackToTheRealHub() {
        let dev = DataDirectory(url: URL(fileURLWithPath: "/tmp/dev-index"))
        #expect(Hub.socket(for: dev, environment: [:]) == nil)
        #expect(Hub.socket(for: dev, environment: ["LUOKE_HUB_SOCKET": "/tmp/lab.sock"]) == "/tmp/lab.sock")
        let real = DataDirectory.standard(environment: [:])
        #expect(real.isStandard)
        // Only the app itself falls back to the installed hub; a test or a development build never does (B-10).
        #expect(Hub.socket(for: real, environment: [:], bundle: "ai.luoke.search")?.hasSuffix("luoke-core/run/hub.sock") == true)
        #expect(Hub.socket(for: real, environment: [:], bundle: nil) == nil)
        #expect(Hub.socket(for: real, environment: [:]) == nil)   // this test process isn't the app
        #expect(!DataDirectory.standard(environment: ["LUOKE_SEARCH_HOME": "/tmp/x"]).isStandard)
    }

    @Test func taskNameCanPointElsewhereForALabHub() {
        #expect(Hub(socket: "/x", environment: [:]).task == "luoke-search.embed")
        #expect(Hub(socket: "/x", environment: ["LUOKE_SEARCH_EMBED_TASK": "digup.embed"]).task == "digup.embed")
    }

    @Test func chunkedBodies() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)
        let response = try UnixHTTP.parse(raw)
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == "hello world")
    }
}

struct VectorTests {
    @Test func float16RoundTrip() throws {
        let vector = VectorMath.normalized((0..<768).map { Float(sin(Double($0))) })
        let back = try #require(VectorMath.vector(VectorMath.blob(vector)))
        #expect(VectorMath.cosine(vector, back) > 0.9999)
    }

    @Test func matrixScoresAreCosines() {
        let matrix = VectorMatrix()
        let vectors = (0..<1500).map { seed in VectorMath.normalized((0..<768).map { Float(sin(Double($0 * (seed + 1)))) }) }
        for (index, vector) in vectors.enumerated() {
            matrix.append(segment: Int64(index), item: Int64(index), modality: "text", blob: VectorMath.blob(vector))
        }
        let query = vectors[1234]
        let scores = matrix.scores(query)
        #expect(scores.count == 1500)
        #expect(abs(scores[1234] - 1) < 0.002)                       // past the first 1024-row block
        #expect(abs(scores[7] - VectorMath.cosine(query, vectors[7])) < 0.002)
    }

    @Test func aMatchStandsOutEvenInASmallIndex() {
        // Four rows: leave-one-out and the typical deviation still let the match pass the gate (z ≥ 2).
        let z = VectorMatrix.meaning([0.62, 0.21, 0.19, 0.23], modalities: ["text", "text", "text", "text"])
        #expect(z[0] >= Searcher.zGate)
        #expect(z[1...].allSatisfy { $0 < Searcher.zGate })
    }
}

extension ReadsPictures {
    struct FillerTests {
        func library() throws -> (Library, FakeHub, Hub) {
            let library = try Library()
            _ = try library.index()
            let fake = try FakeHub()
            return (library, fake, Hub(socket: fake.path, environment: [:]))
        }

        @Test func fillsEveryWaitingSegment() throws {
            let (library, fake, hub) = try library()
            fake.batch = 4
            let report = VectorFiller(store: library.store, hub: hub).run(wait: false)
            #expect(report.embedded == 6)
            #expect(report.stoppedBy == nil)
            let counts = try library.store.counts()
            #expect(counts.vectors == 6)
            #expect(counts.waitingForVectors == 0)
            #expect(try library.store.vectorSpace == "embeddinggemma-2/1")
            #expect(fake.embedRequests.count == 2)   // 4 + 2
            #expect(fake.embedRequests.allSatisfy { $0.headers["x-luoke-priority"] == "background" })
            // Documents are prompted with their file's name as the title, the original text (full-width punctuation).
            let texts = fake.embedRequests.flatMap {
                (try? JSONSerialization.jsonObject(with: $0.body) as? [String: [String]])?["texts"] ?? []
            }
            #expect(texts.contains { $0.hasPrefix("title: 租赁合同摘要 | text: # 租赁合同\n房屋位于静安区。押金为两个月租金，") })
        }

        @Test func shortRestsAreWaitedOutOnTheSpot() throws {
            let (library, fake, hub) = try library()
            fake.refuse(503, ["code": "busy", "reason": "lane_busy", "retry_after": 1, "retry_after_ms": 120], times: 3)
            let filler = VectorFiller(store: library.store, hub: hub)
            var slept: [TimeInterval] = []
            filler.sleep = { seconds, _ in slept.append(seconds) }
            let report = filler.run(wait: false)
            #expect(report.embedded == 6)
            #expect(slept == [0.25, 0.25, 0.25])   // 120 ms asked, a quarter second at least
        }

        @Test func busyStopsUnlessToldToWait() throws {
            let (library, fake, hub) = try library()
            fake.refuse(503, ["code": "busy", "reason": "interactive", "retry_after": 30], times: 2)
            let filler = VectorFiller(store: library.store, hub: hub)
            var slept: [TimeInterval] = []
            filler.sleep = { seconds, _ in slept.append(seconds) }
            let stopped = filler.run(wait: false)
            #expect(stopped.embedded == 0)
            #expect(stopped.stoppedBy == .refused(code: "busy", reason: "interactive", retryAfter: 30))
            let waited = filler.run(wait: true)
            #expect(waited.embedded == 6)
            #expect(slept == [30])
        }

        @Test func waitingBacksOffOnlyWhileNothingGetsThrough() throws {
            let (library, fake, hub) = try library()
            fake.refuse(503, ["code": "paused", "reason": "battery", "retry_after": 5], times: 3)
            let filler = VectorFiller(store: library.store, hub: hub)
            var slept: [TimeInterval] = []
            filler.sleep = { seconds, _ in slept.append(seconds) }
            _ = filler.run(wait: true)
            #expect(slept == [5, 10, 20])
        }

        @Test func unsupportedStops() throws {
            let (library, fake, hub) = try library()
            fake.status = "unsupported"
            let report = VectorFiller(store: library.store, hub: hub).run(wait: true)
            #expect(report.stoppedBy == .unsupported(nil))
            #expect(fake.embedRequests.isEmpty)
        }

        @Test func aNewVectorSpaceRemakesEveryVector() throws {
            let (library, fake, hub) = try library()
            _ = VectorFiller(store: library.store, hub: hub).run(wait: false)
            fake.space = "embeddinggemma-2/2"
            let report = VectorFiller(store: library.store, hub: hub).run(wait: false)
            #expect(report.spaceChanged == 6)
            #expect(report.embedded == 6)
            #expect(try library.store.vectorSpace == "embeddinggemma-2/2")
            #expect(try library.store.counts().waitingToRead == 0)   // nothing read again
        }

        @Test func promptsKeepWithinTheLimits() {
            let todos = (0..<5).map { IndexStore.TextTodo(segment: Int64($0), text: String(repeating: "字", count: 100),
                                                          title: "t") }
            let task = HubTask(status: .available, batch: 4, maxChars: 50, maxTotalChars: 120)
            let (prompts, used) = VectorFiller.prompts(todos, task: task)
            #expect(prompts.count == 2)   // 50 + 50 fit in 120, a third doesn't
            #expect(used.map(\.segment) == [0, 1])
            #expect(prompts.allSatisfy { $0.unicodeScalars.count == 50 })
        }
    }
}

extension ReadsPictures {
    struct MeaningSearchTests {
        /// The library with every text segment's vector made by the fake hub.
        func library() throws -> (Library, Hub) {
            let library = try Library()
            _ = try library.index()
            let fake = try FakeHub()
            let hub = Hub(socket: fake.path, environment: [:])
            _ = VectorFiller(store: library.store, hub: hub).run(wait: false)
            return (library, hub)
        }

        @Test func meaningAloneFindsAnItem() throws {
            let (library, _) = try library()
            // A vector exactly like one document's, with words found nowhere: only meaning can find it.
            let segment = try library.store.db.scalarInt("""
                SELECT s.id FROM segments s JOIN items i ON i.id = s.item WHERE i.path LIKE '%running.txt' AND s.kind = 'text'
                """)
            var blob: Data?
            try library.store.db.query("SELECT vec FROM segments WHERE id = ?", [.int(segment)]) { blob = $0.blob(0) }
            let vector = try #require(blob.flatMap(VectorMath.vector))
            let answer = try Searcher(store: library.store).search("qqzzxx", meaning: QueryMeaning(vector: vector,
                                                                                                    space: "embeddinggemma-2/1"))
            let hit = try #require(answer.hits.first)
            #expect(hit.title == "running.txt")
            #expect(hit.why == "意思对得上")
            #expect(hit.where == Location(part: 1))
            #expect(answer.partialReason?.contains("还没全有按意思搜的向量") == true)   // the screenshot's picture vector
        }

        @Test func wordsAndMeaningTogether() throws {
            let (library, hub) = try library()
            let (meaning, note) = QueryMeaning.make("押金 租金", hub: hub)
            #expect(note == nil)
            let answer = try Searcher(store: library.store).search("押金 租金", meaning: meaning)
            #expect(answer.hits.first?.title == "租赁合同摘要.md")
            #expect(answer.hits.first?.snippet?.contains("押金为两个月租金，") == true)   // the text as written
            #expect(answer.partialReason?.contains("图片") == true)   // only the screenshot is waiting
        }

        @Test func anotherVectorSpaceMeansWordsOnly() throws {
            let (library, _) = try library()
            let answer = try Searcher(store: library.store).search("押金", meaning: QueryMeaning(
                vector: FakeHub.vector("押金"), space: "something-else/9"))
            #expect(answer.hits.first?.title == "租赁合同摘要.md")
            #expect(answer.partialReason?.contains("只按字词") == true)
        }

        @Test func whyThereIsNoMeaning() {
            #expect(QueryMeaning.make("x", hub: nil).note == "没有连螺壳，只按字词搜")
            let nobody = Hub(socket: "/tmp/lsfh-nobody-\(UUID().uuidString.prefix(6)).sock", environment: [:])
            #expect(QueryMeaning.make("x", hub: nobody).note == "螺壳没有在运行，只按字词搜")
        }
    }
}

struct EvalTests {
    @Test func expectedAnswersWithPlaces() {
        let base = "/corpus"
        let page = Evaluation.Expected("pdf/租赁合同.pdf@2-2", base: base)
        func hit(_ path: String, _ location: Location?) -> Hit {
            Hit(id: "1", kind: .pdf, title: "", path: path, where: location, date: "", snippet: nil, why: "",
                score: 1, strong: true)
        }
        #expect(page.matches(hit("/corpus/pdf/租赁合同.pdf", Location(page: 2))))
        #expect(!page.matches(hit("/corpus/pdf/租赁合同.pdf", Location(page: 3))))
        #expect(!page.matches(hit("/corpus/pdf/租赁合同.pdf", nil)))
        let moment = Evaluation.Expected("audio/播客第12期.m4a@20-35", base: base)
        #expect(moment.matches(hit("/corpus/audio/播客第12期.m4a", Location(time: 25, end: 55))))
        #expect(!moment.matches(hit("/corpus/audio/播客第12期.m4a", Location(time: 50, end: 80))))
        let whole = Evaluation.Expected("docs/草稿.md", base: base)
        #expect(whole.matches(hit("/corpus/docs/草稿.md", Location(part: 1))))
    }

    @Test func ranksAndShares() throws {
        let set = try JSONDecoder().decode(EvalSet.self, from: Data("""
            {"base": "~/DigUpTestbed/x", "queries": [
              {"q": "a", "expect": ["a.md"], "tag": "doc"},
              {"q": "b", "expect": ["b.md"], "tag": "doc"},
              {"q": "c", "expect": ["c.md"], "tag": "img"}]}
            """.utf8))
        let scratch = try Scratch()
        let base = scratch.path + "/x"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let report = Evaluation.run(set, testbed: scratch.path) { query in
            let order = ["a": ["a.md", "b.md"], "b": ["a.md", "b.md"], "c": ["a.md"]][query]!
            return SearchAnswer(hits: order.map { Hit(id: $0, kind: .doc, title: $0, path: base + "/" + $0, where: nil,
                                                      date: "", snippet: nil, why: "", score: 1, strong: true) },
                                partial: false, partialReason: nil, confident: nil, tookMs: 1)
        }
        #expect(report.all.count == 3)
        #expect(report.all.top1 == 0.33)
        #expect(report.all.top5 == 0.67)
        #expect(report.all.mrr == 0.5)
        #expect(report.byTag["doc"]?.top5 == 1)
        #expect(report.misses.map(\.q) == ["b", "c"])
    }
}
