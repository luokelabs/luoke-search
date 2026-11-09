import Foundation

public struct SearchOptions: Sendable {
    /// Only these kinds (a filter, unlike the kind words in the query, which only add to a kind's score).
    public var kinds: Set<ItemKind>?
    /// Only from these: the folders' files, the Photos library (the window's filter; a video file is a file).
    public var sources: Set<ItemSource>?
    /// The item's time (taken, else modified) within these bounds, seconds since 1970.
    public var since: Double?
    public var until: Double?
    public var limit: Int
    /// Photos the user hasn't allowed aren't found, or counted, whatever the filter says. Their records stay in the
    /// index, so allowing them again needs no rebuild.
    public var hidesPhotos = false

    public init(kinds: Set<ItemKind>? = nil, sources: Set<ItemSource>? = nil, since: Double? = nil,
                until: Double? = nil, limit: Int = 10) {
        self.kinds = kinds
        self.sources = sources
        self.since = since
        self.until = until
        self.limit = limit
    }
}

/// Finds items for a query: by words (FTS5, with the trigram table for Chinese and Japanese) and, when the query has
/// a vector from luoke-core, by meaning, on one scale (digup's fusion, which beat reciprocal-rank fusion on its evals):
/// - an item qualifies by standing out in meaning (z ≥ `zGate`, `VectorMatrix.meaning`) or by holding at least half
///   of the query's words;
/// - it scores its meaning z, plus 2 × (share of the words)^1.5, plus a little for words in its name and for ranking
///   high on them, plus 1 when it's the kind the query names. One common word can't beat a strong meaning match; all
///   of an exact lookup's words usually do.
public final class Searcher {
    public let store: IndexStore

    static let wordWeight = 2.0
    static let nameWeight = 0.5
    static let orderWeight = 0.3
    static let kindBonus = 1.0
    /// An item qualifies on words when it holds at least this share of them.
    static let minimumShare = 0.5
    /// An item qualifies on meaning when its best segment stands this many deviations above the rest of its
    /// modality — or this many, when it's of a kind the query names ("播客里讲失眠的那段"): a recording has no words
    /// to be found by, and among a few recordings the right one rarely stands out by two.
    static let zGate = 2.0
    static let kindGate = 1.0

    /// How meaning is scored; only `eval --scoring` changes it.
    public var meaningScale: MeaningScale = .pooled

    private var matrix: VectorMatrix?
    private var matrixGeneration: String?

    public init(store: IndexStore) {
        self.store = store
    }

    struct Match {
        let segment: Int64
        let item: Int64
        let rank: Double
        let isName: Bool
    }

    struct Candidate {
        var terms = Set<Int>()
        var nameTerms = Set<Int>()
        /// Per segment: the terms it holds and its best rank.
        var segments: [Int64: (terms: Set<Int>, rank: Double, isName: Bool)] = [:]
        var order = 0.0
    }

    /// `meaning`: the query's vector (`QueryMeaning.make`); without one, or in another vector space than the index's,
    /// only words are searched. `meaningNote`: why there's no vector, for `partial_reason`.
    /// `started`: when the caller began (before asking luoke-core for the query's vector), so `took_ms` is all of it.
    public func search(_ text: String, options: SearchOptions = SearchOptions(), meaning: QueryMeaning? = nil,
                       meaningNote: String? = nil, started: Date = Date()) throws -> SearchAnswer {
        // No words, only a time or kinds (the window's global search, agent tool protocol §1b): the newest within
        // them. Complete once every file has been listed and read.
        if Self.isBlank(text) {
            let kinds = options.kinds ?? Set(ItemKind.allCases)
            let hits = try newest(of: kinds, options: options, why: "时间对得上（最新的在前）")
            let reason = Self.stillReading(try store.counts())
            return SearchAnswer(hits: hits, partial: reason != nil, partialReason: reason,
                                confident: hits.isEmpty ? false : nil,
                                tookMs: Int(Date().timeIntervalSince(started) * 1000),
                                totals: try newestTotals(of: kinds, options: options))
        }
        let query = Query(text)
        var candidates: [Int64: Candidate] = [:]

        for (index, term) in query.terms.enumerated() {
            let matches = try self.matches(term)
            // Where each item first appears in this term's list (best rank first) makes a small tie-breaker.
            var position: [Int64: Int] = [:]
            for match in matches where position[match.item] == nil { position[match.item] = position.count }
            for match in matches {
                var candidate = candidates[match.item, default: Candidate()]
                candidate.terms.insert(index)
                if match.isName { candidate.nameTerms.insert(index) }
                var segment = candidate.segments[match.segment] ?? ([], .infinity, match.isName)
                segment.terms.insert(index)
                segment.rank = min(segment.rank, match.rank)
                candidate.segments[match.segment] = segment
                candidates[match.item] = candidate
            }
            for (item, place) in position {
                candidates[item]?.order += 1 / (1 + Double(place) / 10)
            }
        }

        // Meaning: every vector on this query's scale; each item keeps its best segment.
        var note = meaningNote
        var best: [Int64: (z: Double, segment: Int64, modality: String)] = [:]
        var cosines: [Int64: Double] = [:]
        if let meaning {
            let space = try store.vectorSpace
            if space != nil, meaning.space != nil, space != meaning.space {
                note = "螺壳换了向量，正在重算，这次只按字词搜"
            } else {
                let matrix = try vectors()
                let raw = matrix.scores(meaning.vector)
                let z = VectorMatrix.meaning(raw, modalities: matrix.rows.map(\.modality), scale: meaningScale)
                for (index, row) in matrix.rows.enumerated() where z[index] > (best[row.item]?.z ?? -.infinity) {
                    best[row.item] = (z[index], row.segment, row.modality)
                    cosines[row.item] = Double(raw[index])
                }
            }
        }

        // The share counts the required terms only; optional ones (`Query.Term.optional`: characters the tokenizer
        // left alone, joined) add a little each when found, and can't make an item qualify on their own (review
        // B-04). A query of optional terms only counts them all.
        let termCount = Double(max(query.countedTerms, 1))
        let required = Set(query.terms.indices.filter { !query.terms[$0].optional })
        let (meaningWeight, wordWeight) = query.isLookup ? (0.5, Self.wordWeight * 2) : (1.0, Self.wordWeight)
        var ids = Set(candidates.keys)
        let gate = query.kindHints.isEmpty ? Self.zGate : Self.kindGate
        for (item, value) in best where value.z >= gate { ids.insert(item) }
        let items = try itemInfo(Array(ids))
        var scored: [(item: Int64, score: Double)] = []
        var shares: [Int64: Double] = [:]
        var totals = Self.noTotals
        for id in ids {
            guard let item = items[id], allowed(item, options, bySource: false) else { continue }
            let candidate = candidates[id] ?? Candidate()
            let foundRequired = candidate.terms.intersection(required).count
            let share = query.terms.isEmpty ? 0 : required.isEmpty ? min(1, Double(candidate.terms.count) / termCount)
                : Double(foundRequired) / Double(required.count)
            let optionalBonus = required.isEmpty ? 0 : min(0.3, 0.1 * Double(candidate.terms.count - foundRequired))
            let z = best[id]?.z ?? 0
            guard share >= Self.minimumShare || z >= (query.kindHints.contains(item.kind) ? Self.kindGate : Self.zGate)
            else { continue }
            totals[item.from.rawValue, default: 0] += 1
            guard options.sources?.contains(item.from) ?? true else { continue }
            shares[id] = share
            var score = meaningWeight * max(z, 0) + wordWeight * pow(share, 1.5) + optionalBonus
            score += Self.nameWeight * min(1, Double(candidate.nameTerms.count) / termCount)
            score += Self.orderWeight * candidate.order / Double(max(candidate.terms.count, 1))
            if query.kindHints.contains(item.kind) { score += Self.kindBonus }
            scored.append((id, score))
        }
        scored.sort { $0.score > $1.score || ($0.score == $1.score && $0.item < $1.item) }

        var hits: [Hit] = []
        for (id, score) in scored {
            guard hits.count < options.limit, let item = items[id] else { break }
            if item.source == "file", !FileManager.default.fileExists(atPath: item.path) { continue }
            var hit = try hit(item, candidates[id], meaning: best[id], score: score, query: query)
            hit.signals = Hit.Signals(z: best[id]?.z, cosine: cosines[id], modality: best[id]?.modality,
                                      share: shares[id] ?? 0)
            hits.append(hit)
        }
        if let top = hits.first?.score, top > 0 {
            for index in hits.indices { hits[index].strong = hits[index].score >= top * 0.5 }
        }

        // Nothing but kind words ("截图", "录音") and nothing found by meaning: the newest of those kinds. Found from
        // another source than the filter asks is found: the filter emptying the list doesn't make it another search.
        if query.terms.isEmpty, !query.kindHints.isEmpty, hits.isEmpty, totals.values.allSatisfy({ $0 == 0 }) {
            let kinds = options.kinds.map { $0.intersection(query.kindHints) } ?? query.kindHints
            hits = try newest(of: kinds, options: options)
            totals = try newestTotals(of: kinds, options: options)
        }

        let reason = try partialReason(meaningUsed: meaning != nil && note == nil, note: note)
        // Nothing found: certainly not. Something found: unknown until there is a refusal threshold (review B-11).
        return SearchAnswer(hits: hits, partial: reason != nil, partialReason: reason, confident: hits.isEmpty ? false : nil,
                            tookMs: Int(Date().timeIntervalSince(started) * 1000), totals: totals)
    }

    // MARK: Similar

    /// What else is like a result (`search_similar`, agent tool protocol §1b): its id (`12`, `12#p3`, `12#t25.0`)
    /// gives the part's vectors (the whole item's when it names none, or that part has none), and every other item is
    /// scored by its closest segment, its z taken among the other items (a search takes it among segments). Only
    /// vectors already in the index: luoke-core isn't
    /// asked. Items that stand no higher than the rest (z ≤ 0) aren't listed; `strong` is the search's meaning gate.
    /// Nil: no such item.
    public func similar(to id: String, options: SearchOptions = SearchOptions(), started: Date = Date()) throws
        -> SearchAnswer? {
        let parts = id.split(separator: "#", maxSplits: 1)
        guard let item = Int64(parts.first ?? ""), let from = try itemInfo([item])[item] else { return nil }
        // A hidden photo is no starting point either: what's near it would tell what's in it.
        if options.hidesPhotos, from.from == .photos {
            return SearchAnswer(hits: [], partial: false, partialReason: nil, confident: false,
                                tookMs: Int(Date().timeIntervalSince(started) * 1000), totals: Self.noTotals)
        }
        let matrix = try vectors()
        var segments = try vectorSegments(item: item, part: parts.count == 2 ? String(parts[1]) : nil)
        if segments.isEmpty, parts.count == 2 { segments = try vectorSegments(item: item, part: nil) }
        let own = segments.compactMap { matrix.vector(ofSegment: $0) }
        guard !own.isEmpty else {
            return SearchAnswer(hits: [], partial: true, partialReason: "这条还没算出向量，还找不了相似的", confident: false,
                                tookMs: Int(Date().timeIntervalSince(started) * 1000), totals: Self.noTotals)
        }
        var probe = [Float](repeating: 0, count: VectorMath.dimension)
        for vector in own { for index in probe.indices { probe[index] += vector[index] } }
        let norm = probe.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm > 0 { probe = probe.map { $0 / norm } }

        // Each other item by its closest segment, then items against items: a long file with many segments like the
        // probe counts once, and doesn't lift the scale the rest are measured on (as rows against rows would).
        let raw = matrix.scores(probe)
        var closest: [Int64: (cosine: Float, segment: Int64, modality: String)] = [:]
        for (index, row) in matrix.rows.enumerated() where row.item != item && raw[index] > (closest[row.item]?.cosine ?? -2) {
            closest[row.item] = (raw[index], row.segment, row.modality)
        }
        let others = Array(closest)
        let z = VectorMatrix.meaning(others.map(\.value.cosine), modalities: others.map(\.value.modality), scale: meaningScale)
        var best: [Int64: (z: Double, segment: Int64, modality: String)] = [:]
        var cosines: [Int64: Double] = [:]
        for (index, other) in others.enumerated() where z[index] > 0 {
            best[other.key] = (z[index], other.value.segment, other.value.modality)
            cosines[other.key] = Double(other.value.cosine)
        }
        let items = try itemInfo(Array(best.keys))
        var totals = Self.noTotals
        for (id, _) in best {
            guard let info = items[id], allowed(info, options, bySource: false) else { continue }
            totals[info.from.rawValue, default: 0] += 1
        }
        let ranked = best.sorted { $0.value.z > $1.value.z || ($0.value.z == $1.value.z && $0.key < $1.key) }
        var hits: [Hit] = []
        for (id, meaning) in ranked {
            guard hits.count < options.limit else { break }
            guard let info = items[id], allowed(info, options) else { continue }
            if info.source == "file", !FileManager.default.fileExists(atPath: info.path) { continue }
            var hit = try hit(info, nil, meaning: meaning, score: meaning.z, query: Query(""), similar: true)
            hit.strong = meaning.z >= Self.zGate
            hit.signals = Hit.Signals(z: meaning.z, cosine: cosines[id], modality: meaning.modality, share: 0)
            hits.append(hit)
        }
        let reason = try partialReason(meaningUsed: true, note: nil)
        return SearchAnswer(hits: hits, partial: reason != nil, partialReason: reason, confident: hits.isEmpty ? false : nil,
                            tookMs: Int(Date().timeIntervalSince(started) * 1000), totals: totals)
    }

    /// The segments of `item` with a vector: those of the part a result id names after its `#` (`p3`, `t25.0`), as
    /// `hitID` writes them (so a time is matched as it was rounded), or all of them. A moment that is both a frame and
    /// a stretch of sound goes by the frame: what the window shows of it is the picture.
    func vectorSegments(item: Int64, part: String?) throws -> [Int64] {
        var found: [(id: Int64, kind: SegmentKind?)] = []
        try store.db.query("SELECT id, kind, loc FROM segments WHERE item = ? AND vec IS NOT NULL ORDER BY id",
                           [.int(item)]) { row in
            let kind = SegmentKind(rawValue: row.text(1) ?? "")
            if let part {
                guard let kind, !row.isNull(2),
                      Self.hitID(item, kind, row.double(2)) == "\(item)#\(part)" else { return }
            }
            found.append((row.int(0), kind))
        }
        if part != nil, found.contains(where: { $0.kind == .frame }) { found.removeAll { $0.kind == .audio } }
        return found.map(\.id)
    }

    /// Of `items`, those with at least one vector (`search_similar` has something to go on).
    public func withVectors(_ items: [Int64]) throws -> Set<Int64> {
        guard !items.isEmpty else { return [] }
        var found = Set<Int64>()
        let marks = items.map { _ in "?" }.joined(separator: ",")
        try store.db.query("SELECT DISTINCT item FROM segments WHERE vec IS NOT NULL AND item IN (" + marks + ")",
                           items.map { .int($0) }) { found.insert($0.int(0)) }
        return found
    }

    /// Why results may be incomplete, the most important reason first.
    func partialReason(meaningUsed: Bool, note: String?) throws -> String? {
        let counts = try store.counts()
        if let reading = Self.stillReading(counts) { return reading }
        // The rest of long files is read after everything else: what's on page 100 may not be found yet (review D-5).
        if counts.waitingForRest > 0 { return "还有 \(counts.waitingForRest) 个长文件没读完，结果可能不全" }
        if !meaningUsed { return note ?? "这次只按字词搜" }
        if counts.waitingForVectors > 0 {
            return "还有 \(counts.waitingForVectors) 段在等螺壳算向量，按意思搜可能不全"
        }
        // Not "waiting for luoke-core": some wait for their files to be on this Mac again (`MediaInputs.Source`).
        // Files, not pictures: a PDF's scanned pages may wait while its text is found by meaning, a video may have
        // some frames' vectors and not the rest.
        if counts.waitingForMedia > 0 {
            return "\(counts.waitingForMedia) 个文件的图片和声音还没全有按意思搜的向量，这些暂时只能按名字和里面的字找到"
        }
        return nil
    }

    /// Files still waiting to be read: their names and times may be listed already, not what's in them.
    static func stillReading(_ counts: IndexStore.Counts) -> String? {
        counts.waitingToRead > 0 ? "还在建索引（还有 \(counts.waitingToRead) 个文件没读），结果可能不全" : nil
    }

    static func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The vectors, loaded once and again whenever they change.
    func vectors() throws -> VectorMatrix {
        let generation = try store.vectorGeneration
        if let matrix, generation == matrixGeneration { return matrix }
        // In the same vector space, only what changed since the last load is read (review B-18: while the first pass
        // adds vectors, every search would read them all again). Another space: every vector is new.
        if let matrix, let loaded = matrixGeneration, loaded.split(separator: ":", maxSplits: 1).dropFirst().first
            == generation.split(separator: ":", maxSplits: 1).dropFirst().first,
           let since = Int64(loaded.prefix { $0 != ":" }), try !store.hasUnsequencedVectors() {
            try store.updateVectors(matrix, since: since)
            matrixGeneration = generation
            return matrix
        }
        let loaded = try store.loadVectors()
        matrix = loaded
        matrixGeneration = generation
        return loaded
    }

    /// Frees the vectors' memory (tens of MB for a large index); the next meaning search loads them again.
    var vectorsLoaded: Bool { matrix != nil }

    public func releaseVectors() {
        matrix = nil
        matrixGeneration = nil
    }

    /// The newest items of `kinds` within the options' times; a file gone since it was indexed is left out, as in a
    /// search, and the next newest taken in its place (a page at a time, until there are enough or no more).
    func newest(of kinds: Set<ItemKind>, options: SearchOptions, why: String = "类型对得上（最新的在前）") throws -> [Hit] {
        guard !kinds.isEmpty else { return [] }
        var hits: [Hit] = []
        let list = kinds.map { "'\($0.rawValue)'" }.joined(separator: ",")
        var (bounds, values) = Self.bounds(options)
        if let sources = options.sources {
            // The index writes a file's source as `file`.
            bounds += " AND source IN (" + sources.map { $0 == .photos ? "'photos'" : "'file'" }.joined(separator: ",") + ")"
        }
        let page = max(options.limit, 50)
        var offset = 0
        while hits.count < options.limit {
            var rows = 0
            try store.db.query("""
                SELECT id, path, source, kind, coalesce(taken, mtime), title FROM items
                WHERE kind IN (\(list)) AND state != 'skipped'\(bounds)
                ORDER BY coalesce(taken, mtime) DESC, id DESC LIMIT ? OFFSET ?
                """, values + [.int(Int64(page)), .int(Int64(offset))]) { row in
                rows += 1
                let info = ItemInfo(id: row.int(0), path: row.text(1) ?? "", source: row.text(2) ?? "file",
                                    kind: ItemKind(rawValue: row.text(3) ?? "") ?? .doc, date: row.double(4),
                                    title: row.text(5))
                guard hits.count < options.limit,
                      info.source != "file" || FileManager.default.fileExists(atPath: info.path) else { return }
                hits.append(Hit(id: String(info.id), kind: info.kind,
                                title: Secrets.mask(info.name), path: info.source == "file" ? info.path : nil,
                                where: nil, date: JSONOutput.date(row.double(4)), snippet: nil,
                                why: why, score: 0, strong: true))
            }
            if rows < page { break }
            offset += page
        }
        return hits
    }

    /// What `newest` would list from each source, unlimited (`SearchAnswer.totals`).
    func newestTotals(of kinds: Set<ItemKind>, options: SearchOptions) throws -> [String: Int] {
        var totals = Self.noTotals
        guard !kinds.isEmpty else { return totals }
        let (bounds, values) = Self.bounds(options)
        try store.db.query("""
            SELECT source = 'photos', count(*) FROM items
            WHERE kind IN (\(kinds.map { "'\($0.rawValue)'" }.joined(separator: ","))) AND state != 'skipped'\(bounds)
            GROUP BY 1
            """, values) { row in totals[(row.int(0) != 0 ? ItemSource.photos : .files).rawValue] = Int(row.int(1)) }
        return totals
    }

    static func bounds(_ options: SearchOptions) -> (sql: String, values: [SQLValue]) {
        var sql = options.hidesPhotos ? " AND source != 'photos'" : ""
        var values: [SQLValue] = []
        if let since = options.since { sql += " AND coalesce(taken, mtime) >= ?"; values.append(.double(since)) }
        if let until = options.until { sql += " AND coalesce(taken, mtime) <= ?"; values.append(.double(until)) }
        return (sql, values)
    }

    /// Every source, counted or not.
    static var noTotals: [String: Int] { Dictionary(uniqueKeysWithValues: ItemSource.allCases.map { ($0.rawValue, 0) }) }

    // MARK: Matching words

    func matches(_ term: Query.Term) throws -> [Match] {
        var out: [Match] = []
        let row = { (r: Row) in
            out.append(Match(segment: r.int(0), item: r.int(1), rank: r.double(2), isName: r.int(3) != 0))
        }
        if !term.unspaced {
            var pattern = Self.quoted(term.text)
            if try Script.inflects(term.text) || term.text.count >= 3 && !isIndexed(pattern) { pattern += "*" }
            try store.db.query("""
                SELECT s.id, s.item, bm25(fts, 3.0, 1.0), s.kind = 'name' FROM fts
                JOIN segments s ON s.id = fts.rowid WHERE fts MATCH ? ORDER BY bm25(fts, 3.0, 1.0) LIMIT 5000
                """, [.text(pattern)], row)
        } else if term.text.count >= 3 {
            try store.db.query("""
                SELECT s.id, s.item, bm25(fts_tri, 3.0, 1.0), s.kind = 'name' FROM fts_tri
                JOIN segments s ON s.id = fts_tri.rowid WHERE fts_tri MATCH ? ORDER BY bm25(fts_tri, 3.0, 1.0) LIMIT 5000
                """, [.text(Self.quoted(term.text))], row)
        } else {
            // Too short for trigrams. Names first: a short word in a file's name says more than one in its text.
            let like = SQLValue.text("%" + Self.escapedLike(term.text) + "%")
            try store.db.query("""
                SELECT s.id, s.item, 0, s.kind = 'name' FROM fts_tri JOIN segments s ON s.id = fts_tri.rowid
                WHERE fts_tri.name LIKE ? ESCAPE '\\' OR fts_tri.body LIKE ? ESCAPE '\\'
                ORDER BY s.kind = 'name' DESC LIMIT 5000
                """, [like, like], row)
        }
        return out
    }

    /// A word that isn't in the index as typed matches as the start of longer ones ("grok" finds "Grok4"); one that
    /// is stays whole, so "cat" doesn't bring in "category".
    func isIndexed(_ pattern: String) throws -> Bool {
        var found = false
        try store.db.query("SELECT 1 FROM fts WHERE fts MATCH ? LIMIT 1", [.text(pattern)]) { _ in found = true }
        return found
    }

    static func quoted(_ term: String) -> String {
        "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func escapedLike(_ term: String) -> String {
        term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: Items

    struct ItemInfo {
        let id: Int64
        let path: String
        let source: String
        let kind: ItemKind
        let date: Double
        var title: String? = nil

        /// What results call it: a file's name; a Photos item's original file name, else "照片" or "视频".
        var name: String {
            source == "photos" ? title ?? (kind == .video ? "视频" : "照片") : (path as NSString).lastPathComponent
        }

        var from: ItemSource { source == "photos" ? .photos : .files }
    }

    func itemInfo(_ ids: [Int64]) throws -> [Int64: ItemInfo] {
        var out: [Int64: ItemInfo] = [:]
        for start in stride(from: 0, to: ids.count, by: 500) {
            let slice = ids[start..<min(start + 500, ids.count)]
            try store.db.query("""
                SELECT id, path, source, kind, coalesce(taken, mtime), title FROM items
                WHERE id IN (\(slice.map(String.init).joined(separator: ",")))
                """) { row in
                out[row.int(0)] = ItemInfo(id: row.int(0), path: row.text(1) ?? "", source: row.text(2) ?? "file",
                                           kind: ItemKind(rawValue: row.text(3) ?? "") ?? .doc, date: row.double(4),
                                           title: row.text(5))
            }
        }
        return out
    }

    /// Within the options' kinds and times, and (`bySource`) their sources. Hidden photos never are.
    func allowed(_ item: ItemInfo, _ options: SearchOptions, bySource: Bool = true) -> Bool {
        if options.hidesPhotos, item.from == .photos { return false }
        if let kinds = options.kinds, !kinds.contains(item.kind) { return false }
        if bySource, let sources = options.sources, !sources.contains(item.from) { return false }
        if let since = options.since, item.date < since { return false }
        if let until = options.until, item.date > until { return false }
        return true
    }

    // MARK: Hits

    func hit(_ item: ItemInfo, _ candidate: Candidate?, meaning: (z: Double, segment: Int64, modality: String)?,
             score: Double, query: Query, similar: Bool = false) throws -> Hit {
        // Point at the segment holding the most of the query's words; on a tie, at the content rather than the name
        // (a result that says "page 3" is more use), then the better ranked. Point at the best meaning segment
        // instead when meaning qualified the item, or no words matched.
        let order = { (a: (key: Int64, value: (terms: Set<Int>, rank: Double, isName: Bool)),
                      b: (key: Int64, value: (terms: Set<Int>, rank: Double, isName: Bool))) -> Bool in
            if a.value.terms.count != b.value.terms.count { return a.value.terms.count < b.value.terms.count }
            if a.value.isName != b.value.isName { return a.value.isName }
            return a.value.rank > b.value.rank
        }
        var words = candidate?.segments.max(by: order)
        // The name holds more of the words, but the content holds some too ("港湾咖啡的小票" against
        // 港湾咖啡小票.pdf, whose page says 港湾咖啡): point at the content, where the page and a snippet are.
        var nameToo = false
        if words?.value.isName == true, let content = candidate?.segments.filter({ !$0.value.isName }).max(by: order) {
            words = content
            nameToo = true
        }
        let byMeaning = meaning.map { $0.z >= Self.zGate || words == nil } ?? false
        let segment = byMeaning ? meaning?.segment : words?.key
        var kind = SegmentKind.name, loc: Double?, locEnd: Double?
        if let segment {
            try store.db.query("SELECT kind, loc, loc_end FROM segments WHERE id = ?", [.int(segment)]) { row in
                kind = SegmentKind(rawValue: row.text(0) ?? "") ?? .name
                loc = row.isNull(1) ? nil : row.double(1)
                locEnd = row.isNull(2) ? nil : row.double(2)
            }
        }
        var snippet: String?
        if let segment, kind != .name, let text = try store.text(ofSegment: segment), !text.isEmpty {
            let terms = query.terms.map(\.text)
            snippet = kind == .sheet ? Self.sheetSnippet(text, terms: terms) ?? Self.snippet(text, terms: terms)
                : Self.snippet(text, terms: terms)
        }
        let name = Secrets.mask(item.name)
        let location = Self.location(kind, loc: loc, locEnd: locEnd)
        let why = byMeaning ? Self.whyMeaning(kind, loc: loc, modality: meaning?.modality, alsoWords: words != nil,
                                              similar: similar)
            : nameToo ? Self.whyNameAnd(kind, loc: loc)
            : Self.why(kind, loc: loc, name: item.name, terms: query.terms.map(\.text))
        return Hit(id: Self.hitID(item.id, kind, loc), kind: item.kind, title: name,
                   path: item.source == "file" ? item.path : nil, where: location.isEmpty ? nil : location,
                   date: JSONOutput.date(item.date), snippet: snippet, why: why,
                   score: (score * 1000).rounded() / 1000, strong: true)
    }

    /// The words are in the name and (some of them) inside, where the result points.
    static func whyNameAnd(_ kind: SegmentKind, loc: Double?) -> String {
        let page = loc.map { Int($0) }
        switch kind {
        case .page: return page.map { "名字和第 \($0) 页的文字都对得上" } ?? "名字和里面的文字都对得上"
        case .slide: return page.map { "名字和第 \($0) 页幻灯片的文字都对得上" } ?? "名字和幻灯片里的文字都对得上"
        case .ocr: return "名字和图里的文字都对得上"
        default: return "名字和里面的文字都对得上"
        }
    }

    /// `similar`: next to another result (`similar(to:)`), "…和它相近" in place of "…对得上".
    static func whyMeaning(_ kind: SegmentKind, loc: Double?, modality: String?, alsoWords: Bool,
                           similar: Bool = false) -> String {
        let page = loc.map { Int($0) }
        let base: String = switch kind {
        case .page where modality == "image": page.map { "第 \($0) 页的画面对得上" } ?? "画面对得上"
        case .page: page.map { "第 \($0) 页的意思对得上" } ?? "意思对得上"
        case .slide: page.map { "第 \($0) 页幻灯片的意思对得上" } ?? "意思对得上"
        case .image, .ocr: "画面对得上"
        case .frame: loc.map { "\(Self.clock($0)) 的画面对得上" } ?? "画面对得上"
        case .audio: loc.map { "\(Self.clock($0)) 听到的内容对得上" } ?? "听到的内容对得上"
        default: "意思对得上"
        }
        if similar { return String(base.dropLast("对得上".count)) + "和它相近" }
        return alsoWords ? base + "，也有查的字词" : base
    }

    static func clock(_ seconds: Double) -> String {
        let whole = seconds.isFinite ? Int(min(max(seconds, 0), 1e9)) : 0
        return whole >= 3600 ? String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
            : String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// "12" for the item, "12#p3" for its page 3; slides `s`, worksheets `w`, document parts `c`, times `t`.
    static func hitID(_ item: Int64, _ kind: SegmentKind, _ loc: Double?) -> String {
        guard let loc else { return String(item) }
        switch kind {
        case .page: return "\(item)#p\(Int(loc))"
        case .slide: return "\(item)#s\(Int(loc))"
        case .sheet: return "\(item)#w\(Int(loc))"
        case .text: return "\(item)#c\(Int(loc))"
        case .frame, .audio: return "\(item)#t\(String(format: "%.1f", loc))"
        default: return String(item)
        }
    }

    static func location(_ kind: SegmentKind, loc: Double?, locEnd: Double?) -> Location {
        guard let loc else { return Location() }
        switch kind {
        case .page, .slide: return Location(page: Int(loc))
        case .text: return Location(part: Int(loc))
        case .sheet: return Location(sheet: Int(loc))
        case .frame, .audio: return Location(time: loc, end: locEnd)
        default: return Location()
        }
    }

    static func why(_ kind: SegmentKind, loc: Double?, name: String, terms: [String]) -> String {
        let page = loc.map { Int($0) }
        switch kind {
        case .name:
            let spaced = Folded(IndexStore.spaced(name))   // a word of it may be split by a soft hyphen, or stretched
            return terms.contains(where: { spaced.find($0) != nil }) ? "名字对得上" : "所在文件夹的名字对得上"
        case .page: return page.map { "第 \($0) 页的文字对得上" } ?? "里面的文字对得上"
        case .slide: return page.map { "第 \($0) 页幻灯片的文字对得上" } ?? "幻灯片里的文字对得上"
        case .sheet: return "表格里的文字对得上"
        case .ocr: return "图里的文字对得上"
        default: return "里面的文字对得上"
        }
    }

    /// About 160 characters around the first of the query's words found in `text`, as plain text on one line.
    /// Both kinds of snippet go out with credentials masked (`Secrets.mask`): masked once the text is laid out as it's
    /// shown (lines joined, so a card number wrapped over two is one; a cell under its column's name, "护照号：…") and
    /// before it's cut (one cut at the edge isn't recognised any more).
    /// A worksheet's rows that have the words (else its first rows), at most two, each cell under its column's name
    /// when the sheet's first row names them: "「十月开支」日期：10-05，项目：物业费，金额（元）：420". A sheet is its
    /// name, then rows of tab-separated cells (`Office.xlsx`); a later part of a long one starts with neither.
    static func sheetSnippet(_ text: String, terms: [String], length: Int = 160) -> String? {
        var rows = text.split(whereSeparator: \.isNewline).map { $0.split(separator: "\t", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) } }
        var name: String?, header: [String]?
        if rows.count >= 2, rows[0].count == 1 {
            name = rows[0][0]
            rows.removeFirst()
            // The columns' names, under a title or two if the sheet has them (`TextShapes.headerRow`); the titles
            // aren't rows of the table. A sheet of labels and values may have its first pair there ("WiFi 密码 |
            // 8888…"): a value after a label is masked, a column's name after one ("密码 | 备注") isn't.
            if let at = TextShapes.headerRow(rows), rows.count > at + 1 {
                header = Self.labelled(rows[at], onlyValues: true)
                rows.removeFirst(at + 1)
            }
        }
        guard !rows.isEmpty else { return nil }
        // The columns that hold credentials: by their names; with none named so (no names at all, or names that say
        // something else), the ones most of whose cells here look like passwords (10-23: a sheet without its
        // names in the first row was left unmasked).
        var columns = header?.map(Secrets.label) ?? []
        if !columns.contains(where: { $0 != nil }) {
            let width = rows.map(\.count).max() ?? 0
            columns = (0..<width).map { column in
                let cells = rows.compactMap { column < $0.count && !$0[column].isEmpty ? $0[column] : nil }
                let like = cells.filter { Secrets.passwordLike($0, withSign: header != nil) }.count
                return !cells.isEmpty && like * 5 >= cells.count * 3 ? "password" : nil
            }
        }
        let matching = rows.filter { row in
            let cells = row.map(Folded.init)
            return terms.contains { term in cells.contains { $0.find(term) != nil } }
        }
        let shown = (matching.isEmpty ? rows : matching).prefix(2).map { row -> String in
            // A password's column masked whole (pre-release review, must-fix 4).
            Self.labelled(row).enumerated().filter { !$0.element.isEmpty }.map { index, cell in
                let value = index < columns.count ? columns[index].map { Self.masked(cell, kind: $0) } ?? cell : cell
                guard let header, index < header.count, !header[index].isEmpty else { return value }
                return header[index] + "：" + value
            }.joined(separator: "，")
        }
        var piece = Secrets.mask((name.map { "「\($0)」" } ?? "") + shown.joined(separator: "；"))
        if piece.count > length { piece = String(piece.prefix(length - 1)) + "…" }
        return piece
    }

    /// A row with the cell after a label ("WiFi 密码", "Password"; empty cells between skipped) masked whole:
    /// "WiFi 密码 | 〔密码〕". `onlyValues`: only a cell that looks like a value, not a word ("Pw!2026x", "8888kv", not
    /// "备注", "Notes"): a header row's.
    static func labelled(_ row: [String], onlyValues: Bool = false) -> [String] {
        row.enumerated().map { index, cell in
            guard !cell.isEmpty, let before = row[..<index].last(where: { !$0.isEmpty }),
                  let kind = Secrets.label(before), !onlyValues || Secrets.valueLike(cell) else { return cell }
            return Self.masked(cell, kind: kind)
        }
    }

    /// A cell said to be a credential, masked; left as it is when it can't be one: words in Chinese without a digit
    /// ("用户通过短信找回", a requirement's description), a key or token under a dozen characters ("ETH").
    static func masked(_ cell: String, kind: String) -> String {
        let han = cell.unicodeScalars.count { Script.isUnspaced($0) }
        if han * 2 >= cell.unicodeScalars.count, !cell.contains(where: \.isNumber) { return cell }
        if kind == "key", cell.count < 12 { return cell }
        return Secrets.replacement(cell, kind: kind)
    }

    /// A text, to find a question's words (`Script.normalized`, lowercased) in as written, ignoring case, accents and
    /// width. Where normalizing changes the text (a soft hyphen or zero-width joiner inside a word, tatweel, harakat,
    /// Arabic presentation forms), a word is also looked for in it normalized a character at a time, and the place
    /// mapped back. That is made once for the text, and only when a word isn't found as written.
    final class Folded {
        let text: String
        private lazy var folding: (text: NSString, origin: [String.Index])? = Self.fold(text)

        init(_ text: String) { self.text = text }

        func find(_ term: String) -> Range<String.Index>? {
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            if let range = text.range(of: term, options: options) { return range }
            guard !term.isEmpty, let folding else { return nil }
            let hit = folding.text.range(of: term, options: options)
            guard hit.location != NSNotFound, hit.length > 0, hit.upperBound <= folding.origin.count else { return nil }
            return folding.origin[hit.location]..<text.index(after: folding.origin[hit.upperBound - 1])
        }

        /// Nil when normalizing leaves the text as it is (it's looked in as written then).
        private static func fold(_ text: String) -> (text: NSString, origin: [String.Index])? {
            guard text.unicodeScalars.contains(where: Script.normalizedAway)
                    || text.precomposedStringWithCompatibilityMapping != text else { return nil }
            var folded = "", origin: [String.Index] = []   // for each UTF-16 unit of `folded`, its character in `text`
            var index = text.startIndex
            for character in text {
                // A zero-width space left out: the words either side of it are found whichever way the index has it.
                let piece = character == "\u{200B}" ? "" : Script.normalized(String(character)).lowercased()
                folded += piece
                origin += Array(repeating: index, count: piece.utf16.count)
                index = text.index(after: index)
            }
            return (folded as NSString, origin)
        }
    }

    static func find(_ term: String, in text: String) -> Range<String.Index>? { Folded(text).find(term) }

    static func snippet(_ text: String, terms: [String], length: Int = 160) -> String? {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        var first: String.Index?
        let folded = Folded(flat)
        for term in terms {
            // Stemming matches "running" for "run"; look for the word's start when the whole isn't there.
            let probes = term.count > 4 && !Script.hasUnspaced(term) ? [term, String(term.prefix(4))] : [term]
            for probe in probes {
                if let range = folded.find(probe) {
                    if first == nil || range.lowerBound < first! { first = range.lowerBound }
                    break
                }
            }
        }
        // The words are found as written (a credential asked for is in the text as written), and the place carried
        // over to the masked text.
        let (masked, place) = Secrets.mask(flat, keeping: first.map { $0.utf16Offset(in: flat) } ?? 0)
        let characters = Array(masked)
        let at = masked.distance(from: masked.startIndex, to: String.Index(utf16Offset: place, in: masked))
        var start = max(0, at - length / 3)
        let end = min(characters.count, start + length)
        start = max(0, min(start, end - length))
        var piece = String(characters[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > 0 { piece = "…" + piece }
        if end < characters.count { piece += "…" }
        return piece
    }
}
