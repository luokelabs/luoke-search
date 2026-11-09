import Foundation

/// A set of queries with known answers, run against an index (`luoke-search eval`). The format is digup's, so its
/// eval sets run unchanged:
///
///     {"base": "~/DigUpTestbed/zh/corpus",
///      "queries": [{"q": "租房合同里能不能养狗", "expect": ["pdf/租赁合同.pdf@2-2"], "tag": "pdf-page"}, …]}
///
/// An expected answer is a path under `base`, optionally with where in it: `@2-2` pages 2–2 of a PDF (or slides),
/// `@20-35` seconds of a recording or video. Any one of a query's answers counts.
public struct EvalSet: Decodable, Sendable {
    public struct Query: Decodable, Sendable {
        public let q: String
        public let expect: [String]
        public let tag: String?
    }

    public let base: String
    public let queries: [Query]

    public static func load(_ url: URL) throws -> EvalSet {
        try JSONDecoder().decode(EvalSet.self, from: Data(contentsOf: url))
    }

    /// `base` as a folder on this Mac. Eval sets name the testbed `~/DigUpTestbed` (digup's); `testbed` (the
    /// `--testbed` option, or `$LUOKE_SEARCH_TESTBED`) says where it really is.
    public func baseFolder(testbed: String?) -> String {
        var base = base
        if let testbed, base.hasPrefix("~/DigUpTestbed") {
            base = testbed + base.dropFirst("~/DigUpTestbed".count)
        }
        return Crawler.canonical(base)
    }
}

public struct EvalReport: Encodable, Sendable {
    public struct Line: Encodable, Sendable {
        public var count = 0
        public var top1 = 0.0
        public var top5 = 0.0
        public var top10 = 0.0
        public var mrr = 0.0
    }

    public struct Miss: Encodable, Sendable {
        public let q: String
        public let tag: String?
        /// The rank of the first right answer (nil: not in the results).
        public let rank: Int?
        public let top: [String]
    }

    public var all = Line()
    public var byTag: [String: Line] = [:]
    public var misses: [Miss] = []
    public var notes: [String] = []
}

/// `luoke-search eval --refusal`: each question's top result and how sure it looks, and how candidate rules for
/// `confident` would have done.
public struct RefusalReport: Encodable, Sendable {
    public struct Record: Encodable, Sendable {
        public let q: String
        public let tag: String?
        public let answerable: Bool
        /// Where the first right answer ranks (nil: not in the results, or no answer to find).
        public let rank: Int?
        public let hits: Int
        /// Of those, marked strong (at least half the top score).
        public let strong: Int
        public let top: String?
        public let score: Double?
        /// The top result's meaning z, its cosine and modality, and its share of the words.
        public let z: Double?
        public let cosine: Double?
        public let modality: String?
        public let share: Double?
    }

    public struct Rule: Encodable, Sendable {
        public let rule: String
        /// Of the questions without an answer, held back (no results count as held back): higher is better.
        public let refusedWithoutAnswer: Double
        /// The same for the near misses (`none-near`: the corpus is about the topic, not about the question).
        public let refusedNearMisses: Double
        /// Of the questions with an answer, held back although the first result was right: lower is better.
        public let wronglyRefused: Double
        /// Of the questions with an answer, held back at all.
        public let refusedWithAnswer: Double
    }

    public var records: [Record] = []
    public var rules: [Rule] = []
}

public enum Evaluation {
    /// Runs every query with `search` (the same search the command line and MCP do) and scores the ranks.
    public static func run(_ set: EvalSet, testbed: String?, limit: Int = 10,
                           search: (String) throws -> SearchAnswer) rethrows -> EvalReport {
        let base = set.baseFolder(testbed: testbed)
        var report = EvalReport()
        var sums: [String: (count: Int, top1: Int, top5: Int, top10: Int, reciprocal: Double)] = [:]
        for query in set.queries {
            let answer = try search(query.q)
            if let note = answer.partialReason, !report.notes.contains(note) { report.notes.append(note) }
            let expected = query.expect.map { Expected($0, base: base) }
            let rank = answer.hits.prefix(limit).firstIndex { hit in expected.contains { $0.matches(hit) } }
                .map { $0 + 1 }
            if let rank, expected.contains(where: { $0.range != nil }), Expected.onlyPart(answer.hits[rank - 1]),
               !report.notes.contains(Self.rangeNote) {
                report.notes.append(Self.rangeNote)
            }
            for key in ["", query.tag ?? "-"] {
                var sum = sums[key, default: (0, 0, 0, 0, 0)]
                sum.count += 1
                if let rank {
                    if rank <= 1 { sum.top1 += 1 }
                    if rank <= 5 { sum.top5 += 1 }
                    if rank <= 10 { sum.top10 += 1 }
                    sum.reciprocal += 1 / Double(rank)
                }
                sums[key] = sum
            }
            if rank != 1 {
                report.misses.append(.init(q: query.q, tag: query.tag, rank: rank,
                                           top: answer.hits.prefix(3).map { Self.describe($0, base: base) }))
            }
        }
        func line(_ sum: (count: Int, top1: Int, top5: Int, top10: Int, reciprocal: Double)) -> EvalReport.Line {
            let n = Double(max(sum.count, 1))
            return .init(count: sum.count, top1: round2(Double(sum.top1) / n), top5: round2(Double(sum.top5) / n),
                         top10: round2(Double(sum.top10) / n), mrr: round2(sum.reciprocal / n))
        }
        for (key, sum) in sums {
            if key.isEmpty { report.all = line(sum) } else { report.byTag[key] = line(sum) }
        }
        return report
    }

    static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    /// For a refusal threshold: runs questions with answers and questions without (an empty `expect`), records how
    /// sure each top result looks, and how candidate rules would have done. Nothing here changes what search answers.
    public static func refusal(_ sets: [EvalSet], testbed: String?, limit: Int = 10,
                               search: (String) throws -> SearchAnswer) rethrows -> RefusalReport {
        var report = RefusalReport()
        for set in sets {
            let base = set.baseFolder(testbed: testbed)
            for query in set.queries {
                let answer = try search(query.q)
                let expected = query.expect.map { Expected($0, base: base) }
                let rank = answer.hits.prefix(limit).firstIndex { hit in expected.contains { $0.matches(hit) } }
                    .map { $0 + 1 }
                let top = answer.hits.first
                report.records.append(.init(q: query.q, tag: query.tag, answerable: !query.expect.isEmpty, rank: rank,
                                            hits: answer.hits.count, strong: answer.hits.filter(\.strong).count,
                                            top: top.map { describe($0, base: base) },
                                            score: top?.score, z: top?.signals?.z.map(round2),
                                            cosine: top?.signals?.cosine.map { (($0 * 1000).rounded()) / 1000 },
                                            modality: top?.signals?.modality,
                                            share: top?.signals.map { round2($0.share) }))
            }
        }
        var rules: [(String, (RefusalReport.Record) -> Bool)] = []
        for threshold in [1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0, 3.5, 4.0] {
            rules.append(("score ≥ \(threshold)", { ($0.score ?? 0) >= threshold }))
        }
        for gate in [2.0, 2.5, 3.0, 3.5, 4.0, 5.0] {
            rules.append(("z ≥ \(gate) or every word", { ($0.z ?? 0) >= gate || ($0.share ?? 0) >= 1 }))
        }
        // A floor on the top segment's cosine, per modality (each has its own scale), or every word found. The floors
        // are EmbeddingGemma 2's (vector space embeddinggemma-2/1) on the synthetic corpus: 2026-10-20, and again on
        // 10-21 after each modality was scored on its own (review B-02).
        let candidates = [(0.62, 0.66, 0.72), (0.63, 0.63, 0.70), (0.63, 0.68, 0.70), (0.68, 0.64, 0.68),
                          (0.70, 0.65, 0.70), (0.70, 0.66, 0.70), (0.72, 0.66, 0.72), (0.72, 0.67, 0.72)]
        for (text, image, audio) in candidates {
            let floors = ["text": text, "image": image, "audio": audio]
            rules.append(("cosine ≥ text \(text) / image \(image) / audio \(audio) or every word", { record in
                guard record.score != nil else { return false }
                if (record.share ?? 0) >= 1 { return true }
                guard let cosine = record.cosine, let floor = record.modality.flatMap({ floors[$0] }) else { return false }
                return cosine >= floor
            }))
        }
        let without = report.records.filter { !$0.answerable }, near = without.filter { $0.tag == "none-near" }
        let with = report.records.filter(\.answerable)
        func rate(_ records: [RefusalReport.Record], _ held: (RefusalReport.Record) -> Bool) -> Double {
            records.isEmpty ? 0 : round2(Double(records.filter(held).count) / Double(records.count))
        }
        for (name, confident) in rules {
            report.rules.append(.init(rule: name, refusedWithoutAnswer: rate(without) { !confident($0) },
                                      refusedNearMisses: rate(near) { !confident($0) },
                                      wronglyRefused: rate(with) { $0.rank == 1 && !confident($0) },
                                      refusedWithAnswer: rate(with) { !confident($0) }))
        }
        return report
    }

    static let rangeNote = "有的答案标了范围（行号），结果只指到段：这样的按文件算"

    static func describe(_ hit: Hit, base: String) -> String {
        var name = hit.path.map { $0.hasPrefix(base + "/") ? String($0.dropFirst(base.count + 1)) : $0 } ?? hit.title
        if let page = hit.where?.page { name += " p.\(page)" }
        if let time = hit.where?.time { name += " @\(Int(time))s" }
        return name
    }

    /// One expected answer: a path, and maybe a range of pages or seconds.
    struct Expected {
        let path: String
        let range: ClosedRange<Double>?

        init(_ text: String, base: String) {
            var path = text
            var range: ClosedRange<Double>?
            if let at = text.lastIndex(of: "@") {
                let bounds = text[text.index(after: at)...].split(separator: "-").compactMap { Double($0) }
                if bounds.count == 2, bounds[0] <= bounds[1] {
                    range = bounds[0]...bounds[1]
                    path = String(text[..<at])
                }
            }
            self.path = base + "/" + path
            self.range = range
        }

        /// A hit that points at a part of a text file or a worksheet, not a page or a moment.
        static func onlyPart(_ hit: Hit) -> Bool {
            hit.where?.page == nil && hit.where?.time == nil && (hit.where?.part != nil || hit.where?.sheet != nil)
        }

        func matches(_ hit: Hit) -> Bool {
            guard let hitPath = hit.path, hitPath.precomposedStringWithCanonicalMapping
                    == path.precomposedStringWithCanonicalMapping else { return false }
            guard let range else { return true }
            // A range on a text file (digup's line numbers) can't be compared with a part: the file is the answer
            // (review B-12).
            if Self.onlyPart(hit) { return true }
            if let page = hit.where?.page { return range.contains(Double(page)) }
            if let time = hit.where?.time {
                // A stretch of sound counts if it overlaps; a video frame if it falls inside.
                if let end = hit.where?.end { return time < range.upperBound + 0.5 && end > range.lowerBound }
                return range.contains(time)
            }
            return false
        }
    }
}
