import Foundation

/// Why questions about recordings do worse (10-21: find out, don't change the scoring). For each question whose
/// answer is a recording: what each of its windows sent to luoke-core was (made again the same way), how close the
/// question came to each window, where the right window ranks among every vector and among the recordings', and how
/// close the same words come written down (a transcript, embedded as a document would be). Changes nothing.
public enum AudioProbe {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public struct Window: Encodable, Sendable {
        public let from: Double
        public let to: Double
        /// The WAV sent: its length, format and size.
        public let seconds: Double
        public let sampleRate: Int
        public let channels: Int
        public let bits: Int
        public let bytes: Int
        /// Loudness: the whole window's RMS, and the share of 20 ms frames under −50 dBFS (silence's threshold).
        public let rmsDBFS: Double
        public let quietShare: Double
        /// The stored vector against one made now from the same window: the same input reaches luoke-core.
        public let remadeVsStored: Double?
        /// The question against the window.
        public let cosine: Double
        /// What is said in the window (the transcript's parts mostly inside it), and that text, embedded as a
        /// document with no title (file names can name the topic), against the question and the window's vector.
        public let transcript: String?
        public let transcriptCosine: Double?
        public let windowVsTranscript: Double?
    }

    public struct Row: Encodable, Sendable {
        public let q: String
        public let tag: String?
        public let file: String
        public let windows: [Window]
        /// The window that holds the part asked about: the one whose own words come closest to the question (the
        /// question sets' time ranges are only roughly where a topic is).
        public let askedWindow: Int?
        /// The best right window by cosine: its place among every vector, and among the recordings' windows.
        public let rankAmongAll: Int?
        public let rankAmongSound: Int?
        public let rows: Int
        public let soundRows: Int
        /// The vector the question comes closest to: its item's name, modality and cosine.
        public let top: String?
        public let topCosine: Double?
        /// Where the asked window's transcript would rank among every vector, had the recording been text.
        public let textWouldRank: Int?
        /// The recording's place in the search (the default scoring; at the answer's time, as `eval` counts), if it's
        /// in the first ten.
        public let searchRank: Int?
    }

    /// A transcript: the whole file's words, or its parts with when each is said.
    public struct Part: Decodable, Sendable {
        public let from: Double
        public let to: Double
        public let text: String

        public init(from: Double, to: Double, text: String) {
            self.from = from
            self.to = to
            self.text = text
        }
    }

    static let audioExtensions: Set<String> = ["m4a", "wav", "mp3", "aif", "aiff", "caf", "flac", "aac", "ogg", "opus"]

    public static func run(_ sets: [EvalSet], testbed: String?, store: IndexStore, hub: Hub,
                           transcripts: [String: [Part]]) throws -> [Row] {
        let task = try hub.embedTask()
        let matrix = try store.loadVectors()
        let searcher = Searcher(store: store)
        var rows: [Row] = []
        for set in sets {
            let base = set.baseFolder(testbed: testbed)
            for query in set.queries {
                guard let expected = query.expect.first(where: {
                    audioExtensions.contains((($0.split(separator: "@").first.map(String.init) ?? $0) as NSString)
                        .pathExtension.lowercased())
                }) else { continue }
                let relative = String(expected.split(separator: "@").first ?? "")
                let answer = Evaluation.Expected(expected, base: base)
                guard let item = try store.item(path: base + "/" + relative) else { continue }
                // The model may still be loading for the first questions: asked again a few times, and never skipped
                // without saying so.
                var meaning: QueryMeaning?
                for attempt in 0..<10 where meaning == nil {
                    if attempt > 0 { Thread.sleep(forTimeInterval: 3) }
                    meaning = QueryMeaning.make(query.q, hub: hub).0
                }
                guard let meaning else { throw Failure(description: "luoke-core gave no vector for \"\(query.q)\"") }
                let question = meaning.vector
                let scores = matrix.scores(question)
                var windows: [Window] = []
                var raw: [(question: Double, text: Double?)] = []   // unrounded, for ranks
                var right: [Int64: [Float]] = [:]
                var segments: [(id: Int64, from: Double, to: Double, vector: [Float])] = []
                try store.db.query("""
                    SELECT id, loc, loc_end, vec FROM segments WHERE item = ? AND kind = 'audio' AND vec IS NOT NULL
                    ORDER BY loc
                    """, [.int(item.id)]) { row in
                    if let blob = row.blob(3), let vector = VectorMath.vector(blob) {
                        segments.append((row.int(0), row.double(1), row.double(2), vector))
                    }
                }
                let parts = transcripts[relative] ?? []
                for segment in segments {
                    right[segment.id] = segment.vector
                    let source = MediaInputs.Source(
                        path: item.path, kind: item.kind,
                        wanted: [MediaInputs.Wanted(segment: segment.id, kind: .audio, loc: segment.from, locEnd: segment.to)],
                        task: task, photos: nil)
                    guard case .made(let made)? = source.next(), case .audio(let wav) = made.input else { continue }
                    let format = Self.format(wav)
                    let remade = try? hub.embed(inputs: [made.input], priority: .userWaiting).vectors.first ?? nil
                    let said = parts.filter { Self.mostlyInside($0, from: segment.from, to: segment.to) }
                        .map(\.text).joined(separator: " ")
                    var spoken: [Float]?
                    if !said.isEmpty {
                        spoken = try hub.embed([Prompts.document(title: nil, text: said)], priority: .userWaiting)
                            .vectors.first
                    }
                    raw.append((Double(VectorMath.cosine(question, segment.vector)),
                                spoken.map { Double(VectorMath.cosine(question, $0)) }))
                    windows.append(Window(
                        from: segment.from, to: segment.to, seconds: format.seconds, sampleRate: format.rate,
                        channels: format.channels, bits: format.bits, bytes: wav.count, rmsDBFS: format.rms,
                        quietShare: format.quiet, remadeVsStored: remade.map { round(VectorMath.cosine($0, segment.vector)) },
                        cosine: round(VectorMath.cosine(question, segment.vector)),
                        transcript: said.isEmpty ? nil : said,
                        transcriptCosine: spoken.map { round(VectorMath.cosine(question, $0)) },
                        windowVsTranscript: spoken.map { round(VectorMath.cosine(segment.vector, $0)) }))
                }
                let best = raw.map(\.question).max()
                let asked = raw.indices.filter { raw[$0].text != nil }.max { raw[$0].text! < raw[$1].text! }
                    ?? (windows.count == 1 ? 0 : nil)
                let askedText = asked.flatMap { raw[$0].text }
                func rank(_ value: Double?, among modality: String? = nil) -> Int? {
                    guard let value else { return nil }
                    var above = 0
                    for (index, row) in matrix.rows.enumerated() where modality == nil || row.modality == modality {
                        if Double(scores[index]) > value + 1e-6 && right[row.segment] == nil { above += 1 }
                    }
                    return above + 1
                }
                let topIndex = scores.indices.max { scores[$0] < scores[$1] }
                var top: String?
                if let topIndex {
                    let row = matrix.rows[topIndex]
                    try store.db.query("SELECT path FROM items WHERE id = ?", [.int(row.item)]) { item in
                        top = ((item.text(0) ?? "") as NSString).lastPathComponent + " (\(row.modality))"
                    }
                }
                let hits = try searcher.search(query.q, options: SearchOptions(limit: 10), meaning: meaning).hits
                rows.append(Row(
                    q: query.q, tag: query.tag, file: relative, windows: windows,
                    askedWindow: asked, rankAmongAll: rank(best), rankAmongSound: rank(best, among: "audio"), rows: matrix.count,
                    soundRows: matrix.rows.filter { $0.modality == "audio" }.count, top: top,
                    topCosine: topIndex.map { round(Double(scores[$0])) },
                    textWouldRank: rank(askedText), searchRank: hits.firstIndex { answer.matches($0) }.map { $0 + 1 }))
            }
        }
        return rows
    }

    /// A transcript part belongs to a window when most of it is said inside it, or it fills most of the window.
    static func mostlyInside(_ part: Part, from: Double, to: Double) -> Bool {
        let shared = max(0, min(part.to, to) - max(part.from, from))
        return shared >= 0.5 * (part.to - part.from) || shared >= 0.5 * (to - from)
    }

    static func round(_ value: Float) -> Double { round(Double(value)) }
    static func round(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    /// A 16-bit PCM WAV's format (as `AudioWindows.wav` writes it) and how loud it is.
    static func format(_ wav: Data) -> (rate: Int, channels: Int, bits: Int, seconds: Double, rms: Double, quiet: Double) {
        let bytes = [UInt8](wav)
        guard bytes.count > 44 else { return (0, 0, 0, 0, 0, 0) }
        func int(_ at: Int, _ size: Int) -> Int { (0..<size).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) } }
        let rate = int(24, 4), channels = int(22, 2), bits = int(34, 2)
        var samples: [Double] = []
        samples.reserveCapacity((bytes.count - 44) / 2)
        var at = 44
        while at + 1 < bytes.count {
            samples.append(Double(Int16(bitPattern: UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8)) / 32768)
            at += 2
        }
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Double(max(samples.count, 1))).squareRoot()
        let frame = max(rate / 50, 1)
        var quiet = 0, frames = 0
        for start in stride(from: 0, to: samples.count, by: frame) {
            let slice = samples[start..<min(start + frame, samples.count)]
            let level = (slice.reduce(0) { $0 + $1 * $1 } / Double(slice.count)).squareRoot()
            if level <= 0.003 { quiet += 1 }
            frames += 1
        }
        return (rate, channels, bits, Double(samples.count) / Double(max(rate * max(channels, 1), 1)),
                round(20 * log10(max(rms, 1e-9))), round(Double(quiet) / Double(max(frames, 1))))
    }
}
