import Foundation
import Testing
@testable import LuokeSearchKit

// The whole-branch review of 11bc2ca: indexing, storage and scoring findings, each reproduced by number.

/// Normally distributed numbers from a fixed seed (Box–Muller over a linear congruential generator).
struct Normals {
    var state: UInt64

    mutating func uniform() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return (Double(state >> 11) + 0.5) / Double(1 << 53)
    }

    mutating func next(_ mean: Double, _ deviation: Double) -> Double {
        mean + deviation * (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
    }
}

struct ReviewIndexTests {
    @Test("A-02: an item whose reading ended the process twice is given up until the file changes")
    func unfinishedReads() throws {
        let scratch = try Scratch()
        let file = try scratch.write("files/坏.md", "# 坏\n读它会让进程退出。")
        let store = try scratch.store()
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        _ = try indexer.sync([scratch.path + "/files"])
        let item = try #require(try store.item(path: file.path))
        // Two reads begun, neither finished: the process ended both times.
        try store.startReading(item.id)
        try store.startReading(item.id)
        #expect(try indexer.readPending() == 1)
        #expect(try store.item(path: file.path)?.state == "failed")
        #expect(try store.pending(limit: 10).isEmpty)   // not first in line again
        // The file changes: it's read again, and this time it finishes.
        try scratch.write("files/坏.md", "# 好了\n这次读得完。")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        _ = try indexer.sync([scratch.path + "/files"])
        #expect(try indexer.readPending() == 1)
        let read = try #require(try store.item(path: file.path))
        #expect(read.state == "done" && read.attempts == 0)
    }

    @Test("A-03: new vectors in reused segment ids are noticed")
    func reusedSegmentIDs() throws {
        let scratch = try Scratch()
        let file = try scratch.write("files/笔记.md", "# 笔记\n第一版的内容。")
        let store = try scratch.store()
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        _ = try indexer.sync([scratch.path + "/files"])
        try indexer.readPending()
        func fill(_ value: Float) throws {
            let todos = try store.textTodos(limit: 10)
            var vector = [Float](repeating: 0, count: VectorMath.dimension)
            vector[0] = value
            vector[1] = 1
            try store.setVectors(todos.map { ($0.segment, VectorMath.normalized(vector)) }, space: "s")
        }
        try fill(1)
        let before = try store.vectorGeneration
        let segments = try store.db.scalarInt("SELECT group_concat(id) FROM segments WHERE vec IS NOT NULL")
        // Changed: its segments are replaced by as many, under the same ids, and get vectors again.
        try scratch.write("files/笔记.md", "# 笔记\n第二版的内容。")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        _ = try indexer.sync([scratch.path + "/files"])
        try indexer.readPending()
        try fill(-1)
        #expect(try store.db.scalarInt("SELECT group_concat(id) FROM segments WHERE vec IS NOT NULL") == segments)
        #expect(try store.vectorGeneration != before)
    }

    @Test("A-18: processes opening a new index at once all get it")
    func concurrentMigration() throws {
        for _ in 0..<8 {
            let scratch = try Scratch()
            let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
            let failures = NSLockedCounter()
            DispatchQueue.concurrentPerform(iterations: 6) { _ in
                do { _ = try IndexStore(directory: data, home: scratch.path) } catch { failures.add() }
            }
            #expect(failures.value == 0)
        }
    }

    /// The review's simulation: many texts around 0.40, pictures around 0.12, one of each standing out by 0.09.
    func simulated(_ texts: Int, _ images: Int, _ scale: MeaningScale) -> (text: Double, picture: Double?) {
        var normals = Normals(state: UInt64(texts * 31 + images))
        var scores: [Float] = [], modalities: [String] = []
        for index in 0..<texts {
            scores.append(Float(normals.next(0.40, 0.03) + (index == 0 ? 0.09 : 0)))
            modalities.append("text")
        }
        for index in 0..<images {
            scores.append(Float(normals.next(0.12, 0.03) + (index == 0 ? 0.09 : 0)))
            modalities.append("image")
        }
        let z = VectorMatrix.meaning(scores, modalities: modalities, scale: scale)
        return (z[0], images > 0 ? z[texts] : nil)
    }

    @Test("B-02, kept for comparison: each modality on its own scale, the right text and the right picture both stand out")
    func modalitiesOnTheirOwnScale() {
        for (texts, images) in [(200, 0), (200, 5), (200, 19), (200, 20), (1000, 19), (5000, 10)] {
            let z = simulated(texts, images, .ownModality)
            #expect(z.text >= 2, "text, \(texts) texts and \(images) pictures: \(z.text)")
            if let picture = z.picture { #expect(picture >= 2, "picture, \(texts) texts and \(images) pictures: \(picture)") }
        }
        // Two of a kind: nothing to stand out from.
        #expect(VectorMatrix.meaning([0.9, 0.1, 0.4, 0.41, 0.39], modalities: ["audio", "audio", "text", "text", "text"],
                                     scale: .ownModality).prefix(2) == [0, 0])
    }

    @Test("The default (digup's, chosen on 10-21): with no pictures or 20 and more, the right text and picture stand out")
    func pooledScale() {
        // (texts, pictures, the right text stands out, the right picture stands out). Fewer than 20 pictures are
        // measured on the texts' level, and the gap between the two widens the one deviation: the picture is found by
        // its words only, and the right text can fall under the gate too (200 + 19). This is what review B-02 changed
        // and the 10-21 comparison changed back (evals/README.md).
        let cases: [(Int, Int, Bool, Bool?)] = [(200, 0, true, nil), (200, 5, true, false), (200, 19, false, false),
                                                (200, 20, true, true), (200, 60, true, true), (1000, 19, true, false),
                                                (5000, 10, true, false)]
        for (texts, images, text, picture) in cases {
            let z = simulated(texts, images, .pooled)
            #expect((z.text >= 2) == text, "text, \(texts) + \(images): \(z.text)")
            #expect(z.picture.map { $0 >= 2 } == picture, "picture, \(texts) + \(images): \(String(describing: z.picture))")
        }
        #expect(VectorMatrix.meaning([0.62, 0.21, 0.19, 0.23], modalities: ["text", "text", "text", "text"])
                == VectorMatrix.meaning([0.62, 0.21, 0.19, 0.23], modalities: ["text", "text", "text", "text"], scale: .pooled))
    }

    @Test("Centred, pooled deviation (tried on 10-21): the right text and the right picture stand out at every count")
    func centredPooledScale() {
        // (From 5 pictures: with 3, the mean of the other two is too noisy to say.)
        for (texts, images) in [(200, 0), (200, 5), (200, 19), (200, 20), (200, 60), (1000, 19), (5000, 10)] {
            let z = simulated(texts, images, .centredPooled)
            #expect(z.text >= 2, "text, \(texts) + \(images): \(z.text)")
            if let picture = z.picture { #expect(picture >= 2, "picture, \(texts) + \(images): \(picture)") }
        }
        // One of a kind: measured on all rows' mean, as `pooled` does.
        let z = VectorMatrix.meaning([0.9, 0.4, 0.41, 0.39, 0.42], modalities: ["audio", "text", "text", "text", "text"],
                                     scale: .centredPooled)
        #expect(z[0] > 2 && z[1...].allSatisfy { abs($0) < 2 })
        #expect(MeaningScale("d") == .centredPooled)
    }

    /// Review B-02's scale as it was written before the comparison (0aa9da7), to hold `ownModality` to it.
    static func ownModalityAsBefore(_ scores: [Float], modalities: [String]) -> [Double] {
        var sums: [String: Double] = [:], squares: [String: Double] = [:], counts: [String: Double] = [:]
        for (score, modality) in zip(scores, modalities) {
            let value = Double(score)
            sums[modality, default: 0] += value
            squares[modality, default: 0] += value * value
            counts[modality, default: 0] += 1
        }
        return zip(scores, modalities).map { score, modality in
            let own = Double(score)
            let others = counts[modality, default: 0] - 1
            guard others >= 2 else { return 0 }
            let mean = (sums[modality, default: 0] - own) / others
            let variance = max((squares[modality, default: 0] - own * own) / others - mean * mean, 0)
            let deviation = ((others * variance + 5 * 0.03 * 0.03) / (others + 5)).squareRoot()
            return (own - mean) / max(deviation, 0.02)
        }
    }

    @Test("The middle way: k 0 is exactly B-02's scale; a larger k pulls each modality towards all rows")
    func shrunkScale() {
        for (texts, images) in [(200, 5), (200, 19), (1000, 19), (50, 60)] {
            var normals = Normals(state: UInt64(texts * 7 + images))
            var scores: [Float] = [], modalities: [String] = []
            for _ in 0..<texts { scores.append(Float(normals.next(0.40, 0.03))); modalities.append("text") }
            for _ in 0..<images { scores.append(Float(normals.next(0.12, 0.03))); modalities.append("image") }
            scores.append(0.3)
            modalities.append("audio")   // one recording: nothing to stand out from
            let before = Self.ownModalityAsBefore(scores, modalities: modalities)
            #expect(VectorMatrix.meaning(scores, modalities: modalities, scale: .ownModality) == before)
            #expect(VectorMatrix.meaning(scores, modalities: modalities, scale: .shrunk(k: 0)) == before)
        }
        let scores: [Float] = [0.62, 0.21, 0.19, 0.23, 0.25, 0.9, 0.1, 0.12, 0.11]
        let modalities = ["text", "text", "text", "text", "text", "image", "image", "image", "image"]
        let near = VectorMatrix.meaning(scores, modalities: modalities, scale: .shrunk(k: 1))
        let far = VectorMatrix.meaning(scores, modalities: modalities, scale: .shrunk(k: 1000))
        #expect(near[5] > far[5])   // the picture stands out less once it's measured on everything's spread
        #expect(MeaningScale("a") == .pooled && MeaningScale("B") == .ownModality && MeaningScale("c20") == .shrunk(k: 20))
        for text in ["c", "e", "c-1", "cnan", "cinf", "cinfinity", "c1e400"] { #expect(MeaningScale(text) == nil, "\(text)") }
    }
}

final class NSLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

struct ReviewDecodingTests {
    @Test("A-13: a GBK file cut at the size limit in the middle of a character is still Chinese")
    func cutGBK() throws {
        let text = String(repeating: "第一章 天气很好，我们去公园散步。", count: 40)
        var data = try #require(text.data(using: TextDecoding.gb18030))
        data.removeLast()   // half a character at the end, as a read up to a limit leaves it
        #expect(TextDecoding.decode(data).encoding != TextDecoding.gb18030)   // whole: no longer decodes
        let decoded = TextDecoding.decode(data, cut: true)
        #expect(decoded.encoding == TextDecoding.gb18030)
        #expect(decoded.text.hasPrefix("第一章"))
    }

    @Test("A-14: an English line quoting Chinese in curly quotes, saved as GBK, is read as Chinese")
    func curlyQuotes() throws {
        let data = try #require("He said “你好” to me.".data(using: TextDecoding.gb18030))
        #expect(TextDecoding.decode(data).text == "He said “你好” to me.")
    }

    @Test("A-15: English UTF-16 without a mark is UTF-16, and NUL characters don't end the text")
    func utf16AndNul() throws {
        let data = try #require("Meeting notes for Monday".data(using: .utf16LittleEndian))
        #expect(TextDecoding.decode(data).text == "Meeting notes for Monday")
        #expect(TextDecoding.decode(Data("abc\0def".utf8)).text == "abcdef")
        let scratch = try Scratch()
        let store = try scratch.store()
        try store.db.execute("CREATE TABLE t(v TEXT)")
        try store.db.query("INSERT INTO t VALUES(?)", [.text("before\0after")])
        #expect(try store.db.scalarInt("SELECT length(CAST(v AS BLOB)) FROM t") == 12)
    }

    @Test("A-16: a scrolling screenshot keeps a readable width for OCR")
    func longScreenshots() {
        #expect(Reader.ocrSize(width: 1440, height: 12_000) >= 8_000)   // 1440 × 12000: about 1000 px wide at least
        #expect(Reader.ocrSize(width: 2880, height: 1800) == 2880)
        #expect(Reader.ocrSize(width: 6000, height: 4000) == 3000)
        #expect(Reader.ocrSize(width: 800, height: 100_000) == 16_000)
    }

    @Test("A-17: a PDF page whose text comes out as private-use characters is read as a picture")
    func garbledPages() {
        #expect(PDFReading.garbled(String(repeating: "\u{E001}\u{E002}\u{E003} ", count: 100)))
        #expect(!PDFReading.garbled("房屋租赁合同，出租方和承租方。"))
    }
}

struct ReviewRenameTests {
    @Test("A-19: renamed only in case: one item, moved, not two")
    func caseOnlyRename() throws {
        let scratch = try Scratch()
        try scratch.write("files/notes.txt", "Lantern festival notes.")
        let store = try scratch.store()
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        _ = try indexer.sync([scratch.path + "/files"])
        try indexer.readPending()
        let root = scratch.path + "/files"
        try FileManager.default.moveItem(atPath: root + "/notes.txt", toPath: root + "/Notes.txt")
        let report = try indexer.sync([root], changed: [root + "/notes.txt", root + "/Notes.txt"])
        #expect(report.moved == 1 && report.added == 0)
        #expect(try store.db.scalarInt("SELECT COUNT(*) FROM items") == 1)
        #expect(try store.item(path: root + "/Notes.txt") != nil)
    }
}
