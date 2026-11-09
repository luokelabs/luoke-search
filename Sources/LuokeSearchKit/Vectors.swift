import Accelerate
import Foundation

/// Vectors as the index keeps them: 768 dimensions, L2-normalized, stored as float16 (1.5 KB each).
public enum VectorMath {
    public static let dimension = 768

    public static func normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    public static func blob(_ vector: [Float]) -> Data {
        var halves = vector.map { Float16($0) }
        return Data(bytes: &halves, count: halves.count * MemoryLayout<Float16>.stride)
    }

    public static func vector(_ blob: Data) -> [Float]? {
        guard blob.count == dimension * MemoryLayout<Float16>.stride else { return nil }
        return blob.withUnsafeBytes { raw in raw.bindMemory(to: Float16.self).map(Float.init) }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, aa: Float = 0, bb: Float = 0
        for (x, y) in zip(a, b) {
            dot += x * y
            aa += x * x
            bb += y * y
        }
        return dot / max(sqrt(aa) * sqrt(bb), .leastNonzeroMagnitude)
    }
}

/// How a query's cosines are turned into how far each row stands out (`VectorMatrix.meaning`). Compared on the real
/// model on 10-21 (asked for: try a middle way, keep what does best overall; PR #16): `pooled` came first on all 190
/// questions with answers (178 first, against 177 for `shrunk(k: 40)` and 164 for `ownModality`; the tie with k 40
/// went to fewer wrongly refused). `centredPooled` was added for folders of many documents and few pictures (PR #17)
/// and didn't do better. The others are kept for `eval --scoring` only.
public enum MeaningScale: Equatable, Sendable {
    /// digup's, and the default: modalities with 20 rows or more centred on their own mean, one deviation for all. A
    /// modality with fewer rows is measured on the level of all of them. When a question scores the pictures far below
    /// the texts, fewer than 20 pictures don't stand out by meaning (the case review B-02 was about; they're still found
    /// by their words), and the gap widens the one deviation, so the right text can fall under the gate too. In
    /// folders of 200 documents about other things and 5–19 pictures it didn't change a rank: every picture asked about
    /// came first (10-21, PR #17), with less room than on the other scales (lowest z 2.3, against 3.2 and 4.4).
    case pooled
    /// Review B-02's: each modality measured only against itself.
    case ownModality
    /// Each modality against itself, its mean and variance pulled towards all rows' as if `k` more rows had them.
    case shrunk(k: Double)
    /// Each modality centred on its own mean, whatever its size (a modality of fewer than 3 rows on all rows' mean);
    /// one deviation for all rows, as `pooled`. Tried on 10-21 for folders of many texts and few pictures.
    case centredPooled

    /// "a" (pooled), "b" (own modality), "c20" (shrunk, k 20), "d" (centred, pooled deviation): `eval --scoring`.
    public init?(_ text: String) {
        switch text.lowercased() {
        case "a": self = .pooled
        case "b": self = .ownModality
        case "d": self = .centredPooled
        case let c where c.hasPrefix("c"):
            guard let k = Double(c.dropFirst()), k.isFinite, k >= 0 else { return nil }
            self = .shrunk(k: k)
        default: return nil
        }
    }
}

/// All of an index's vectors in memory, one float16 row each, scored against a query in blocks: a block is widened to
/// float32 and multiplied with the query (vDSP). No vector database: at this scale (tens of thousands of rows) a
/// full pass takes a few milliseconds, and every row's score is what the meaning scale needs anyway.
final class VectorMatrix {
    static let blockRows = 1024

    struct Row {
        let segment: Int64
        let item: Int64
        let modality: String
    }

    private(set) var rows: [Row] = []
    private var halves: [Float16] = []
    /// Where each segment's row is.
    private var position: [Int64: Int] = [:]

    var count: Int { rows.count }

    func append(segment: Int64, item: Int64, modality: String, blob: Data) {
        upsert(segment: segment, item: item, modality: modality, blob: blob)
    }

    /// A segment's row: replaced if it's there (a reused segment id, a vector made again), else added.
    func upsert(segment: Int64, item: Int64, modality: String, blob: Data) {
        let dimension = VectorMath.dimension
        guard blob.count == dimension * MemoryLayout<Float16>.stride else { return }
        if let at = position[segment] {
            rows[at] = Row(segment: segment, item: item, modality: modality)
            blob.withUnsafeBytes { raw in
                let values = raw.bindMemory(to: Float16.self)
                halves.withUnsafeMutableBufferPointer { halves in
                    for index in 0..<dimension { halves[at * dimension + index] = values[index] }
                }
            }
            return
        }
        position[segment] = rows.count
        blob.withUnsafeBytes { raw in halves.append(contentsOf: raw.bindMemory(to: Float16.self)) }
        rows.append(Row(segment: segment, item: item, modality: modality))
    }

    /// A segment's vector, if it has a row.
    func vector(ofSegment segment: Int64) -> [Float]? {
        guard let at = position[segment] else { return nil }
        let dimension = VectorMath.dimension
        return (0..<dimension).map { Float(halves[at * dimension + $0]) }
    }

    /// Drops the rows of segments `gone` says are gone; the last row fills each hole (row order means nothing).
    func remove(where gone: (Int64) -> Bool) {
        let dimension = VectorMath.dimension
        var at = 0
        while at < rows.count {
            guard gone(rows[at].segment) else {
                at += 1
                continue
            }
            let last = rows.count - 1
            position[rows[at].segment] = nil
            if at != last {
                rows[at] = rows[last]
                position[rows[at].segment] = at
                halves.withUnsafeMutableBufferPointer { halves in
                    for index in 0..<dimension { halves[at * dimension + index] = halves[last * dimension + index] }
                }
            }
            rows.removeLast()
            halves.removeLast(dimension)
        }
    }

    /// Cosine similarity of `query` (normalized) with every row, in row order.
    func scores(_ query: [Float]) -> [Float] {
        let dimension = VectorMath.dimension
        var scores = [Float](repeating: 0, count: rows.count)
        guard !rows.isEmpty, query.count == dimension else { return scores }
        var block = [Float](repeating: 0, count: Self.blockRows * dimension)
        halves.withUnsafeBufferPointer { halves in
            block.withUnsafeMutableBufferPointer { block in
                scores.withUnsafeMutableBufferPointer { scores in
                    var row = 0
                    while row < rows.count {
                        let count = min(Self.blockRows, rows.count - row)
                        let values = count * dimension
                        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: halves.baseAddress! + row * dimension),
                                                   height: 1, width: vImagePixelCount(values),
                                                   rowBytes: values * MemoryLayout<Float16>.stride)
                        var destination = vImage_Buffer(data: block.baseAddress!, height: 1,
                                                        width: vImagePixelCount(values),
                                                        rowBytes: values * MemoryLayout<Float>.stride)
                        vImageConvert_Planar16FtoPlanarF(&source, &destination, 0)
                        // (count × 768) · (768 × 1) → count
                        vDSP_mmul(block.baseAddress!, 1, query, 1, scores.baseAddress! + row, 1,
                                  vDSP_Length(count), 1, vDSP_Length(dimension))
                        row += count
                    }
                }
            }
        }
        return scores
    }

    /// How far each row stands out for this query, in standard deviations ("z"), as digup scored meaning, on `scale`
    /// (`MeaningScale`). Whatever the scale:
    /// - each row is compared with the *other* rows (leave-one-out), so in a small index the match doesn't inflate the
    ///   scale it's measured on;
    /// - the deviation is pulled towards a typical 0.03 (measured on the real model: queries against unrelated text
    ///   spread 0.021–0.038) as if 5 more rows had it, so a handful of vectors still gives a usable scale.
    static func meaning(_ scores: [Float], modalities: [String], scale: MeaningScale = .pooled) -> [Double] {
        switch scale {
        case .pooled: pooled(scores, modalities: modalities)
        case .ownModality: shrunk(scores, modalities: modalities, k: 0)
        case .shrunk(let k): shrunk(scores, modalities: modalities, k: k)
        case .centredPooled: centredPooled(scores, modalities: modalities)
        }
    }

    /// Each row less the mean of the other rows of its modality (all other rows' when its modality has fewer than 3),
    /// over one deviation: that of every other row from its own modality's mean (leaving this row out of its own).
    private static func centredPooled(_ scores: [Float], modalities: [String]) -> [Double] {
        var sums: [String: Double] = [:], squares: [String: Double] = [:], counts: [String: Double] = [:]
        var allSum = 0.0
        for (score, modality) in zip(scores, modalities) {
            let value = Double(score)
            sums[modality, default: 0] += value
            squares[modality, default: 0] += value * value
            counts[modality, default: 0] += 1
            allSum += value
        }
        // Each modality's sum of squares about its own mean.
        var within: [String: Double] = [:]
        for (modality, count) in counts {
            within[modality] = max(squares[modality]! - sums[modality]! * sums[modality]! / count, 0)
        }
        let total = within.values.reduce(0, +)
        let allOthers = Double(scores.count) - 1
        return zip(scores, modalities).map { score, modality in
            let own = Double(score)
            guard allOthers >= 2 else { return 0 }
            let count = counts[modality, default: 0], others = count - 1
            let mean = others >= 2 ? (sums[modality, default: 0] - own) / others : (allSum - own) / allOthers
            // Leaving this row out of its own modality takes count / others · (own − modality mean)² off its sum.
            let modalMean = sums[modality, default: 0] / count
            let left = others > 0 ? count / others * (own - modalMean) * (own - modalMean) : 0
            let variance = max(total - left, 0) / allOthers
            return (own - mean) / typical(variance, allOthers)
        }
    }

    /// digup's (and this tool's before review B-02): a modality with at least 20 rows is centred on its own mean, a
    /// smaller one on the mean of all rows; then one deviation for all rows together.
    private static func pooled(_ scores: [Float], modalities: [String]) -> [Double] {
        var sums: [String: Double] = [:], counts: [String: Int] = [:]
        for (score, modality) in zip(scores, modalities) {
            sums[modality, default: 0] += Double(score)
            counts[modality, default: 0] += 1
        }
        let overall = sums.values.reduce(0, +) / Double(max(scores.count, 1))
        var means: [String: Double] = [:]
        for (modality, count) in counts { means[modality] = count >= 20 ? sums[modality]! / Double(count) : overall }
        let centred = zip(scores, modalities).map { Double($0) - means[$1, default: overall] }
        let n = Double(centred.count)
        let sum = centred.reduce(0, +)
        let squares = centred.reduce(0) { $0 + $1 * $1 }
        return centred.map { own in
            let others = n - 1
            guard others > 0 else { return 0 }
            let mean = (sum - own) / others
            let variance = max((squares - own * own) / others - mean * mean, 0)
            return (own - mean) / typical(variance, others)
        }
    }

    /// Each modality's own mean and variance, pulled towards those of all rows as if `k` more rows had them. `k` 0 is
    /// review B-02's: each modality only against itself, and one with fewer than 3 rows has nothing to stand out from.
    private static func shrunk(_ scores: [Float], modalities: [String], k: Double) -> [Double] {
        var sums: [String: Double] = [:], squares: [String: Double] = [:], counts: [String: Double] = [:]
        var allSum = 0.0, allSquares = 0.0
        for (score, modality) in zip(scores, modalities) {
            let value = Double(score)
            sums[modality, default: 0] += value
            squares[modality, default: 0] += value * value
            counts[modality, default: 0] += 1
            allSum += value
            allSquares += value * value
        }
        let allOthers = Double(scores.count) - 1
        return zip(scores, modalities).map { score, modality in
            let own = Double(score)
            let others = counts[modality, default: 0] - 1
            if k == 0 {
                guard others >= 2 else { return 0 }
            } else {
                guard allOthers >= 2 else { return 0 }
            }
            let modalMean = others > 0 ? (sums[modality, default: 0] - own) / others : 0
            let modalVariance = others > 0
                ? max((squares[modality, default: 0] - own * own) / others - modalMean * modalMean, 0) : 0
            let allMean = (allSum - own) / max(allOthers, 1)
            let allVariance = max((allSquares - own * own) / max(allOthers, 1) - allMean * allMean, 0)
            // k 0 uses the modality's own values as they are: exactly B-02's, and a NaN elsewhere stays elsewhere.
            let pull = k / (others + k)
            let mean = k == 0 ? modalMean : modalMean + pull * (allMean - modalMean)
            let variance = k == 0 ? modalVariance : modalVariance + pull * (allVariance - modalVariance)
            return (own - mean) / typical(variance, others + k)
        }
    }

    /// The deviation of `variance` measured on `rows` rows, pulled towards the typical one.
    private static func typical(_ variance: Double, _ rows: Double) -> Double {
        max(((rows * variance + typicalWeight * typicalDeviation * typicalDeviation) / (rows + typicalWeight)).squareRoot(),
            0.02)
    }

    static let typicalDeviation = 0.03
    static let typicalWeight = 5.0
}
