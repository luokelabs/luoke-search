import Foundation

/// Where in its item a result points.
public struct Location: Codable, Sendable, Equatable {
    /// PDF page or slide number.
    public var page: Int?
    /// Which part of a long document (chunk number, from 1), or which worksheet.
    public var part: Int?
    public var sheet: Int?
    /// Seconds into a video or a recording, and where the matching stretch ends.
    public var time: Double?
    public var end: Double?

    public init(page: Int? = nil, part: Int? = nil, sheet: Int? = nil, time: Double? = nil, end: Double? = nil) {
        self.page = page
        self.part = part
        self.sheet = sheet
        self.time = time
        self.end = end
    }

    public var isEmpty: Bool { page == nil && part == nil && sheet == nil && time == nil }
}

/// One search result. The same shape in `luoke-search search --json` and in MCP's `search_query` answer.
public struct Hit: Codable, Sendable, Equatable {
    /// Stable while the item stays indexed: the item's number, plus where in it ("12#p3": page 3 of item 12).
    public var id: String
    public var kind: ItemKind
    /// What to call it: the file's name.
    public var title: String
    /// The file's path; nil for a Photos library item.
    public var path: String?
    public var `where`: Location?
    /// The item's time: when it was taken if the file says, else when it was last changed (ISO 8601).
    public var date: String
    /// Up to about 160 characters around the matching words, as plain text.
    public var snippet: String?
    /// Why it matches, in a sentence for the user ("第 3 页的文字对得上").
    public var why: String
    public var score: Double
    /// Answers the question for sure on its own, not by its place in the list (`Searcher.isStrong`): the query's
    /// words all in its name, or close in meaning.
    public var strong: Bool
    /// What the score is made of, for measuring a refusal threshold (`luoke-search eval --refusal`); not sent.
    public var signals: Signals? = nil

    public struct Signals: Sendable, Equatable {
        /// How far its best segment stands out in meaning (`VectorMatrix.meaning`), if it has a vector.
        public var z: Double?
        /// That segment's cosine with the query (no scale of its own: comparable within a modality only), and its
        /// modality (text, image, audio).
        public var cosine: Double?
        public var modality: String?
        /// The share of the query's words it holds.
        public var share: Double
        /// The share of them in its name (a file's name, a photo's title).
        public var nameShare: Double = 0
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, path, `where`, date, snippet, why, score, strong
    }
}

/// Where a result is from: a file in the chosen folders, or the Photos library (the window's `source`).
public enum ItemSource: String, CaseIterable, Codable, Sendable {
    case files, photos
}

/// A search's answer.
public struct SearchAnswer: Codable, Sendable, Equatable {
    public var hits: [Hit]
    /// The results may be incomplete: still indexing, segments waiting for vectors, or only words were searched.
    public var partial: Bool
    public var partialReason: String?
    /// Whether the top results really answer the query. Nil until the refusal threshold is turned on (its eval numbers: evals/README.md).
    public var confident: Bool?
    public var tookMs: Int
    /// How many items qualified in all, by where they're from (`files`, `photos`), before the limit and whatever
    /// `SearchOptions.sources` asked (the window's filter shows each source's count). A file deleted since it was
    /// indexed may be counted until the index notices.
    public var totals: [String: Int]? = nil

    enum CodingKeys: String, CodingKey {
        case hits, partial
        case partialReason = "partial_reason"
        case confident
        case tookMs = "took_ms"
        case totals
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hits, forKey: .hits)
        try container.encode(partial, forKey: .partial)
        try container.encode(partialReason, forKey: .partialReason)   // null, not missing
        try container.encode(confident, forKey: .confident)
        try container.encode(tookMs, forKey: .tookMs)
        try container.encodeIfPresent(totals, forKey: .totals)
    }
}

public enum JSONOutput {
    public static func string<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// ISO 8601 in this Mac's time zone ("2026-09-14T10:02:00+0800").
    public static func date(_ seconds: Double) -> String {
        Date(timeIntervalSince1970: seconds).formatted(Date.ISO8601FormatStyle(timeZone: .current))
    }
}
