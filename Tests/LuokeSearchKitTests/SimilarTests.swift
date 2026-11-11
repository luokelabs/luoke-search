import Foundation
import Testing
@testable import LuokeSearchKit

/// 「找相似的」 on a result (`search_similar`, agent tool protocol §1b): what else is like it, by the vectors already
/// in the index. The fake hub's vectors are words hashed, so texts sharing words come out alike.
struct SimilarTests {
    final class Folder {
        let scratch: Scratch
        let store: IndexStore
        let indexer: Indexer
        let hub: FakeHub

        init() throws {
            scratch = try Scratch()
            try scratch.write("files/租房/合同.md", "# 合同\n租房合同：押金两个月租金，退租前三十天书面通知房东，交房后退押金。")
            try scratch.write("files/租房/续租.md", "# 续租\n续租的话押金不变，房东说退租前三十天书面通知就行，押金交房后退。")
            try scratch.write("files/租房/收据.md", "# 收据\n收到押金两个月租金，退租交房后退押金。房东签字。")
            try scratch.write("files/厨房/蛋糕.md", "# 蛋糕\n烤蛋糕：鸡蛋打发，面粉过筛，烤箱一百八十度烤三十分钟。")
            try scratch.write("files/厨房/面包.md", "# 面包\n烤面包：面粉加酵母揉面，发酵一小时，烤箱一百八十度。")
            try scratch.write("files/notes/running.txt", "Notes on running a marathon: keep the pace slow and steady.")
            // One file, two topics: its rental part and its baking part are found apart.
            let long = (0..<60).map { "第 \($0) 条：押金两个月，退租前三十天书面通知房东，交房后退押金。" }.joined(separator: "\n")
                + "\n" + (0..<60).map { "第 \($0) 步：烤蛋糕，鸡蛋打发，面粉过筛，烤箱一百八十度。" }.joined(separator: "\n")
            try scratch.write("files/杂记.txt", long)
            store = try scratch.store()
            indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([scratch.path + "/files"])
            try indexer.readPending()
            hub = try FakeHub()
            let report = VectorFiller(store: store, hub: Hub(socket: hub.path, environment: [:])).run(wait: false)
            #expect(report.embedded > 0)
        }

        deinit { hub.stop() }

        func id(_ relative: String) throws -> Int64 {
            try #require(try store.item(path: scratch.path + "/files/" + relative)).id
        }

        /// A searcher without the cosine floor: the fake hub's vectors (words hashed) are named like the model's but
        /// aren't its cosines. The floor is `RelevanceCutTests`'.
        func searcher() -> Searcher {
            let searcher = Searcher(store: store)
            searcher.cutsWeakHits = false
            return searcher
        }

        /// The titles `similar` lists for a result id.
        func similar(_ id: String, limit: Int = 10) throws -> [String] {
            try #require(try searcher().similar(to: id, options: SearchOptions(limit: limit))).hits.map(\.title)
        }
    }

    @Test("Similar: photos without permission aren't listed or counted")
    func hiddenPhotos() throws {
        let folder = try Folder()
        let contract = String(try folder.id("租房/合同.md"))
        try folder.store.db.execute("UPDATE items SET source = 'photos' WHERE id = \(try folder.id("租房/收据.md"))")
        let searcher = folder.searcher()
        let shown = try #require(try searcher.similar(to: contract))
        #expect(shown.totals?["photos"] == 1)
        var options = SearchOptions()
        options.hidesPhotos = true
        let hidden = try #require(try searcher.similar(to: contract, options: options))
        #expect(hidden.totals?["photos"] == 0 && hidden.hits.count == shown.hits.count - 1)
        // Nor does one start from it, though its vectors are there.
        let receipt = String(try folder.id("租房/收据.md"))
        #expect(try #require(try searcher.similar(to: receipt)).hits.isEmpty == false)
        #expect(try #require(try searcher.similar(to: receipt, options: options)).hits.isEmpty)
    }

    @Test("Similar: the closest others first, never itself; why says it's near")
    func closestFirst() throws {
        let folder = try Folder()
        let contract = try folder.id("租房/合同.md")
        let answer = try #require(try folder.searcher().similar(to: String(contract)))
        let titles = answer.hits.map(\.title)
        #expect(!titles.contains("合同.md"))
        #expect(Set(titles.prefix(3)) == ["续租.md", "收据.md", "杂记.txt"])
        #expect(!titles.contains("running.txt"))   // nothing in common: no higher than the rest
        #expect(answer.hits.first?.strong == true)
        #expect(answer.hits.first?.why.hasSuffix("和它相近") == true)
        #expect(answer.hits.allSatisfy { $0.signals?.z ?? 0 > 0 })
        // The baking ones are like each other, and like the baking half of the long file; none of the rental ones.
        let cake = try folder.similar(String(try folder.id("厨房/蛋糕.md")))
        #expect(Set(cake) == ["杂记.txt", "面包.md"])
        #expect(try folder.similar(String(contract), limit: 1).count == 1)
    }

    @Test("Similar: a part of a file (a chunk, a page) is looked for by that part; one with no vector, by the whole")
    func byThePart() throws {
        let folder = try Folder()
        let long = try folder.id("杂记.txt")
        var baking: Double?, rental: Double?
        try folder.store.db.query("""
            SELECT s.loc, f.body FROM segments s JOIN fts f ON f.rowid = s.id
            WHERE s.item = ? AND s.kind = 'text' AND s.vec IS NOT NULL ORDER BY s.loc
            """, [.int(long)]) { row in
            let body = row.text(1) ?? ""
            if body.contains("蛋糕"), !body.contains("押金"), baking == nil { baking = row.double(0) }
            if body.contains("押金"), !body.contains("蛋糕"), rental == nil { rental = row.double(0) }
        }
        let (bake, rent) = (try #require(baking), try #require(rental))
        #expect(try folder.similar("\(long)#c\(Int(bake))").first == "蛋糕.md")
        #expect(try folder.similar("\(long)#c\(Int(rent))").prefix(3).allSatisfy { ["合同.md", "续租.md", "收据.md"].contains($0) })
        // A part it doesn't have (or a tag nothing writes): the whole file.
        let whole = try folder.similar("\(long)")
        #expect(!whole.isEmpty)
        #expect(try folder.similar("\(long)#c9999") == whole)
        #expect(try folder.similar("\(long)#x1") == whole)
    }

    @Test("Similar: the part is matched as the result id wrote it (a time rounded); a moment that's a frame and sound goes by the frame")
    func theMoment() throws {
        let folder = try Folder()
        let item = try folder.id("notes/running.txt")
        func add(_ kind: SegmentKind, _ loc: Double, _ modality: String) throws -> Int64 {
            try folder.store.db.run("INSERT INTO segments(item, kind, loc, modality) VALUES (?, ?, ?, ?)",
                                    [[.int(item), .text(kind.rawValue), .double(loc), .text(modality)]])
            return folder.store.db.lastInsertID
        }
        let frame = try add(.frame, 12.25, "image"), sound = try add(.audio, 12.25, "audio")
        let later = try add(.audio, 50, "audio"), page = try add(.page, 3, "image")
        let unit = [Float](repeating: 1 / Float(VectorMath.dimension).squareRoot(), count: VectorMath.dimension)
        try folder.store.setVectors([frame, sound, later, page].map { ($0, unit) }, space: nil)
        let searcher = folder.searcher()
        func part(_ kind: SegmentKind, _ loc: Double) throws -> [Int64] {
            let id = Searcher.hitID(item, kind, loc)
            return try searcher.vectorSegments(item: item, part: String(id.split(separator: "#")[1]))
        }
        #expect(Searcher.hitID(item, .frame, 12.25) == "\(item)#t12.2")   // rounded half to even: 0.05 off
        #expect(try part(.frame, 12.25) == [frame])
        #expect(try part(.audio, 50) == [later])
        #expect(try part(.page, 3) == [page])
        #expect(try searcher.vectorSegments(item: item, part: "t12.3").isEmpty)
        #expect(try searcher.vectorSegments(item: item, part: nil).contains(sound))
    }

    @Test("Similar: no such item is nil; one with no vector yet says so; a file gone since isn't listed")
    func edges() throws {
        let folder = try Folder()
        let searcher = folder.searcher()
        #expect(try searcher.similar(to: "999999") == nil)
        #expect(try searcher.similar(to: "not-an-id") == nil)
        // Written after the vectors were filled: read, but no vector.
        let late = try folder.scratch.write("files/租房/新的.md", "# 新的\n押金两个月，退租前三十天通知。")
        _ = try folder.indexer.sync([folder.scratch.path + "/files"])
        try folder.indexer.readPending()
        let none = try #require(try searcher.similar(to: String(try folder.id("租房/新的.md"))))
        #expect(none.hits.isEmpty && none.confident == false)
        #expect(none.partialReason == "这条还没算出向量，还找不了相似的")
        #expect(none.totals == ["files": 0, "photos": 0])
        try FileManager.default.removeItem(at: late)
        // Deleted since it was indexed: left out, as in a search.
        #expect(try folder.similar(String(try folder.id("租房/合同.md"))).contains("续租.md"))
        try FileManager.default.removeItem(atPath: folder.scratch.path + "/files/租房/续租.md")
        #expect(try !folder.similar(String(try folder.id("租房/合同.md"))).contains("续租.md"))
    }

    /// The window's filter (`sources`) on a search found only by meaning: what it found elsewhere counts; it isn't
    /// taken for nothing found, which would list the newest of the query's kind instead.
    @Test("A filter that leaves a meaning search empty keeps its counts, and doesn't list the newest of the kind")
    func filteredEmptyIsntNothingFound() throws {
        let folder = try Folder()
        let searcher = folder.searcher()
        var segment: Int64?
        try folder.store.db.query("SELECT id FROM segments WHERE item = ? AND vec IS NOT NULL LIMIT 1",
                                  [.int(try folder.id("租房/合同.md"))]) { segment = $0.int(0) }
        let row = try #require(segment)
        let vector = try #require(try searcher.vectors().vector(ofSegment: row))
        let meaning = QueryMeaning(vector: vector, space: try folder.store.vectorSpace)
        let all = try searcher.search("文档", meaning: meaning)
        let found = try #require(all.totals?["files"])
        #expect(found > 0 && all.hits.count == found)
        let photos = try searcher.search("文档", options: SearchOptions(sources: [.photos]), meaning: meaning)
        #expect(photos.hits.isEmpty && photos.totals == ["files": found, "photos": 0])
    }

    @Test("search_similar: listed read-only, answers in the window's shape; not a button on the window's hits")
    func theTool() throws {
        let folder = try Folder()
        let service = try SearchService(directory: DataDirectory(url: folder.scratch.url.appendingPathComponent("data")),
                                        hub: nil, opener: Opened().opener, home: folder.scratch.path)
        let server = AgentTools.server(service)
        var ids = 0
        func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
            ids += 1
            let params: [String: Any] = ["name": name, "arguments": arguments,
                                         "_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]
            return server.handle(["jsonrpc": "2.0", "id": ids, "method": "tools/call", "params": params])?["result"]
                as? [String: Any] ?? [:]
        }
        func hits(_ result: [String: Any]) throws -> [[String: Any]] {
            try #require((result["structuredContent"] as? [String: Any])?["hits"] as? [[String: Any]])
        }
        let tools = (server.handle(["jsonrpc": "2.0", "id": 0, "method": "tools/list",
                                    "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]])?["result"]
            as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        let tool = try #require(tools.first { $0["name"] as? String == "search_similar" })
        #expect((tool["annotations"] as? [String: Bool])?["readOnlyHint"] == true)
        #expect((tool["inputSchema"] as? [String: Any])?["required"] as? [String] == ["id"])

        // A search's hit carries opening it only, not 「找相似的」 (a hit's button answers in one sentence, this one
        // answers with new results); asked with the hit's id, the tool lists the others.
        let found = try #require(try hits(call("search_query", ["query": "租房合同"])).first { $0["title"] as? String == "合同.md" })
        let actions = found["actions"] as? [[String: Any]] ?? []
        #expect(!actions.isEmpty && actions.allSatisfy { $0["name"] as? String == "search_open" })
        let args: [String: Any] = ["id": try #require(found["id"] as? String)]
        let similar = call("search_similar", args)
        let listed = try hits(similar)
        #expect(!listed.isEmpty && !listed.contains { $0["title"] as? String == "合同.md" })
        #expect(listed.first?["source"] as? String == "files")
        #expect((similar["structuredContent"] as? [String: Any])?["card"] is [Any])
        #expect((similar["structuredContent"] as? [String: Any])?["skipped"] is [Any])
        let totals = try #require((similar["structuredContent"] as? [String: Any])?["totals"] as? [String: Int])
        #expect(totals["files"] == listed.count && totals["photos"] == 0)
        #expect(try hits(call("search_similar", args.merging(["sources": ["photos"]]) { $1 })).isEmpty)
        #expect(try hits(similar).allSatisfy { ($0["actions"] as? [[String: Any]] ?? []).allSatisfy { $0["name"] as? String == "search_open" } })
        #expect(((similar["content"] as? [[String: Any]])?.first?["text"] as? String)?.hasPrefix("找到") == true)
        // No such item: stale. No id: invalid.
        #expect(similar["isError"] as? Bool != true)
        let gone = call("search_similar", ["id": "999999"])
        #expect(gone["isError"] as? Bool == true)
        let missing = call("search_similar", [:])
        #expect(missing["isError"] as? Bool == true)

        // One with no vector: asking anyway says why.
        try folder.scratch.write("files/租房/新的.md", "# 新的\n租房合同的押金两个月。")
        _ = try folder.indexer.sync([folder.scratch.path + "/files"])
        try folder.indexer.readPending()
        let fresh = try #require(try hits(call("search_query", ["query": "租房合同"])).first { $0["title"] as? String == "新的.md" })
        #expect(!(fresh["actions"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == "search_similar" })
        let none = call("search_similar", ["id": fresh["id"] as? String ?? ""])
        #expect(try hits(none).isEmpty)
        #expect(((none["content"] as? [[String: Any]])?.first?["text"] as? String) == "这条还没算出向量，还找不了相似的。")
    }
}
