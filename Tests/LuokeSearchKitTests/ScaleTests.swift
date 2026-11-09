import Foundation
import Testing
@testable import LuokeSearchKit

// Large indexes (10-21): vectors loaded only where they changed (review B-18), the Photos library followed by
// its changes (review A-20). The timings at scale run only with LUOKE_SEARCH_SCALE=1 (they take a minute).

extension IndexStore {
    /// `count` items of one text segment each, with random vectors in `space`. Returns the segment ids.
    @discardableResult
    func fakeVectors(_ count: Int, from start: Int = 0, space: String = "test/1", seed: UInt64 = 7) throws -> [Int64] {
        var normals = Normals(state: seed &+ UInt64(start))
        var segments: [Int64] = []
        try db.transaction {
            for index in start..<(start + count) {
                try db.query("INSERT INTO items(path, kind, state) VALUES(?, 'doc', 'done')", [.text("/v/\(index).txt")])
                let item = db.lastInsertID
                try db.query("INSERT INTO segments(item, kind, modality, todo) VALUES(?, 'text', 'text', 'text')",
                             [.int(item)])
                segments.append(db.lastInsertID)
            }
        }
        for batch in stride(from: 0, to: segments.count, by: 1000) {
            let part = segments[batch..<min(batch + 1000, segments.count)]
            try setVectors(part.map { ($0, Self.randomVector(&normals)) }, space: space)
        }
        return segments
    }

    static func randomVector(_ normals: inout Normals) -> [Float] {
        VectorMath.normalized((0..<VectorMath.dimension).map { _ in Float(normals.next(0, 1)) })
    }
}

/// What a matrix holds, in a form to compare: each segment's item, modality and score for `query`.
func contents(_ matrix: VectorMatrix, _ query: [Float]) -> [Int64: String] {
    let scores = matrix.scores(query)
    var out: [Int64: String] = [:]
    for (index, row) in matrix.rows.enumerated() {
        out[row.segment] = "\(row.item) \(row.modality) \(String(format: "%.4f", scores[index]))"
    }
    return out
}

struct VectorLoadingTests {
    @Test("B-18: after vectors change, only what changed is read, and the result is what a full load gives")
    func onlyWhatChanged() throws {
        let scratch = try Scratch()
        let store = try scratch.store()
        let segments = try store.fakeVectors(50)
        let searcher = Searcher(store: store)
        let first = try searcher.vectors()
        #expect(first.count == 50)
        var normals = Normals(state: 99)
        let query = IndexStore.randomVector(&normals)

        // New vectors, a vector made again, items gone.
        try store.fakeVectors(10, from: 50)
        try store.setVectors([(segments[3], IndexStore.randomVector(&normals))], space: "test/1")
        var gone: [Int64] = []
        try store.db.query("SELECT item FROM segments WHERE id IN (?, ?, ?)",
                           [.int(segments[0]), .int(segments[10]), .int(segments[49])]) { gone.append($0.int(0)) }
        for item in gone { try store.remove(item) }
        let second = try searcher.vectors()
        #expect(second === first)   // the same rows, brought up to date
        #expect(second.count == 57)
        #expect(contents(second, query) == contents(try store.loadVectors(), query))

        // Nothing changed: nothing read.
        #expect(try searcher.vectors() === second)

        // Another vector space: every vector is new, all of it is read again.
        try store.adoptVectorSpace("test/2")
        let third = try searcher.vectors()
        #expect(third !== second && third.count == 0)
        try store.fakeVectors(5, from: 100, space: "test/2")
        #expect(try searcher.vectors().count == 5)
    }

    @Test("B-18: a matrix's rows are replaced and dropped in place")
    func upsertAndRemove() {
        var normals = Normals(state: 5)
        let matrix = VectorMatrix(), fresh = VectorMatrix()
        var vectors: [Int64: [Float]] = [:]
        for segment in Int64(1)...20 {
            vectors[segment] = IndexStore.randomVector(&normals)
            matrix.append(segment: segment, item: segment, modality: "text", blob: VectorMath.blob(vectors[segment]!))
        }
        vectors[7] = IndexStore.randomVector(&normals)
        matrix.upsert(segment: 7, item: 70, modality: "image", blob: VectorMath.blob(vectors[7]!))
        matrix.remove { $0 % 3 == 0 || $0 == 20 }
        for segment in Int64(1)...20 where !(segment % 3 == 0 || segment == 20) {
            fresh.append(segment: segment, item: segment == 7 ? 70 : segment, modality: segment == 7 ? "image" : "text",
                         blob: VectorMath.blob(vectors[segment]!))
        }
        let query = IndexStore.randomVector(&normals)
        #expect(matrix.count == fresh.count)
        #expect(contents(matrix, query) == contents(fresh, query))
    }

    @Test("Schema 4 → 5: vectors stored before count as stored at 0")
    func schemaFive() throws {
        let scratch = try Scratch()
        let store = try scratch.store()
        try store.fakeVectors(3)
        try store.db.execute("""
            DROP INDEX segments_vec_seq; DROP INDEX segments_vec_unsequenced; ALTER TABLE segments DROP COLUMN vec_seq;
            PRAGMA user_version = 4
            """)
        let again = try scratch.store()
        #expect(try again.db.scalarInt("PRAGMA user_version") == IndexStore.schemaVersion)
        #expect(try again.db.scalarInt("SELECT COUNT(*) FROM segments WHERE vec_seq = 0") == 3)
        #expect(try again.db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name = 'segments_vec_unsequenced'") == 1)
        #expect(try Searcher(store: again).vectors().count == 3)
    }

    @Test("A vector stored without when (an older luoke-search still running) makes the next load a full one")
    func unsequencedVectors() throws {
        let scratch = try Scratch()
        let store = try scratch.store()
        let segments = try store.fakeVectors(5)
        let searcher = Searcher(store: store)
        let first = try searcher.vectors()
        // As a schema-4 process writes: the vector, no vec_seq; the count moves.
        var normals = Normals(state: 11)
        try store.db.query("UPDATE segments SET vec = ?, vec_seq = NULL WHERE id = ?",
                           [.blob(VectorMath.blob(IndexStore.randomVector(&normals))), .int(segments[2])])
        try store.fakeVectors(1, from: 5)
        let second = try searcher.vectors()
        #expect(second !== first && second.count == 6)
        let query = IndexStore.randomVector(&normals)
        #expect(contents(second, query) == contents(try store.loadVectors(), query))
    }
}

struct PhotoChangesTests {
    /// What the index holds of the library: each item's path, time and state.
    func photoState(_ store: IndexStore) throws -> [String: String] {
        Dictionary(try store.photoItems().map { ($0.path, "\($0.mtime) \($0.state)") }, uniquingKeysWith: { a, _ in a })
    }

    @Test("A-20: what PhotoKit says changed gives the index a full listing would")
    func applyEqualsListing() throws {
        let start = (0..<30).map { PhotoAsset.photo("P\($0)", "IMG_\($0).HEIC") }
        let photos = FakePhotos(start)
        let (one, two) = (try Scratch(), try Scratch())
        let (byChanges, byListing) = (try one.store(), try two.store())
        _ = try PhotoIndexing.sync(photos, store: byChanges)
        _ = try PhotoIndexing.sync(photos, store: byListing)
        let changes = PhotoChangesBox()
        photos.watch { changes.add($0) }
        photos.change {
            $0[2] = .photo("P2", "IMG_2.HEIC", modified: 2_000)      // edited
            $0.remove(at: 5)                                        // deleted
            $0.append(.photo("N1", "IMG_9001.HEIC"))                // new
        }
        #expect(eventually { changes.all.count == 1 })
        let change = try #require(changes.all.first ?? nil)
        #expect(change.inserted.map(\.id) == ["N1"] && change.inserted.first?.filename == "IMG_9001.HEIC")
        #expect(change.changed.map(\.id) == ["P2"] && change.removed == ["P5"])
        let report = try PhotoIndexing.apply(change, source: photos, store: byChanges)
        #expect((report.added, report.changed, report.removed) == (1, 1, 1))
        _ = try PhotoIndexing.sync(photos, store: byListing)
        #expect(try photoState(byChanges) == photoState(byListing))
        #expect(try byChanges.item(path: "photos:N1")?.state == "pending")
        // A change to one the index doesn't have yet: added, its name looked up.
        let late = PhotoChanges(changed: [PhotoAsset.photo("P7", nil)])
        try byChanges.remove(try #require(try byChanges.item(path: "photos:P7")).id)
        #expect(try PhotoIndexing.apply(late, source: photos, store: byChanges).added == 1)
        var title: String?
        try byChanges.db.query("SELECT title FROM items WHERE path = 'photos:P7'") { title = $0.text(0) }
        #expect(title == "IMG_7.HEIC")
    }

    @Test("A-20: a listing looks up original names only for photos the index doesn't have")
    func namesOnlyForNew() throws {
        let photos = FakePhotos((0..<20).map { PhotoAsset.photo("P\($0)", "IMG_\($0).HEIC") })
        let scratch = try Scratch()
        let store = try scratch.store()
        _ = try PhotoIndexing.sync(photos, store: store)
        #expect(photos.named == 20)
        photos.change { $0.append(.photo("N1", "IMG_9001.HEIC")) }
        _ = try PhotoIndexing.sync(photos, store: store)
        #expect(photos.named == 21)   // only the new one's
        var titles = 0
        try store.db.query("SELECT COUNT(*) FROM items WHERE title IS NOT NULL") { titles = Int($0.int(0)) }
        #expect(titles == 21)
    }

    @Test("A-20: a photo taken while a large library is first listed isn't lost")
    func changeDuringFirstListing() throws {
        let scratch = try Scratch()
        let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        var settings = Settings()
        settings.photos = true
        try settings.save(data)
        let photos = FakePhotos([.photo("A1", "IMG_1001.HEIC")])
        photos.duringFirstListing = { photos.change { $0.append(.photo("N1", "IMG_9001.HEIC")) } }
        let resident = try Resident(directory: data, hub: nil, photos: photos)
        resident.readsBacklog = false
        resident.photosQuiet = 0.3
        resident.start()
        defer { resident.stop() }
        let store = try IndexStore(directory: data, home: scratch.path)
        #expect(eventually { (try? store.item(path: "photos:N1")) != .some(nil) })
        #expect(photos.listed == 1)
    }

    @Test("A-20: the resident follows the library by its changes, and lists it again only when PhotoKit can't say")
    func residentFollowsChanges() throws {
        let scratch = try Scratch()
        let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        var settings = Settings()
        settings.photos = true
        try settings.save(data)
        let photos = FakePhotos([.photo("A1", "IMG_1001.HEIC")])
        let resident = try Resident(directory: data, hub: nil, photos: photos)
        resident.readsBacklog = false
        resident.photosQuiet = 0.3
        resident.start()
        defer { resident.stop() }
        let store = try IndexStore(directory: data, home: scratch.path)
        #expect(eventually { (try? store.item(path: "photos:A1"))??.state == "done" })
        let listed = photos.listed
        for index in 0..<50 { photos.change { $0.append(.photo("B\(index)", "IMG_\(index).HEIC")) } }
        photos.change { $0.removeAll { $0.id == "A1" } }
        #expect(eventually { (try? store.photoItems().count) == 50 && (try? store.item(path: "photos:A1")) == .some(nil) })
        #expect(photos.listed == listed)   // not listed again
        photos.change(details: false) { $0.append(.photo("C1", "IMG_3001.HEIC")) }
        #expect(eventually { (try? store.photoItems().count) == 51 })
        #expect(photos.listed == listed + 1)
    }
}

final class PhotoChangesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [PhotoChanges?] = []
    func add(_ change: PhotoChanges?) { lock.withLock { changes.append(change) } }
    var all: [PhotoChanges?] { lock.withLock { changes } }
}

/// Timings at scale, before and after the two changes: LUOKE_SEARCH_SCALE=1 swift test --filter ScaleTimings.
/// "Before" is the path that was the only one (a full reload, a full listing), which is still there.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LUOKE_SEARCH_SCALE"] != nil))
struct ScaleTimings {
    func seconds(_ work: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    @Test("B-18 at scale: a full reload against reading what changed", arguments: [20_000, 100_000, 200_000])
    func vectors(_ count: Int) throws {
        let scratch = try Scratch()
        let store = try scratch.store()
        let fill = try seconds { try store.fakeVectors(count) }
        let searcher = Searcher(store: store)
        var matrix: VectorMatrix?
        let first = try seconds { matrix = try searcher.vectors() }
        // 100 new vectors and 100 gone, as while the first pass goes on.
        try store.fakeVectors(100, from: count)
        var gone: [Int64] = []
        try store.db.query("SELECT id FROM items ORDER BY id LIMIT 100") { gone.append($0.int(0)) }
        for item in gone { try store.remove(item) }
        let full = try seconds { _ = try store.loadVectors() }
        let changed = try seconds { matrix = try searcher.vectors() }
        var normals = Normals(state: 3)
        let meaning = QueryMeaning(vector: IndexStore.randomVector(&normals), space: "test/1")
        var times: [Double] = []
        for _ in 0..<20 {
            times.append(try seconds { _ = try searcher.search("季度报告", meaning: meaning) })
        }
        times.sort()
        let size = (try FileManager.default.attributesOfItem(atPath: store.file.path)[.size] as? NSNumber)?.intValue ?? 0
        print(String(format: "SCALE vectors %d: fill %.1f s, index %.0f MB, first load %.3f s; after +100/-100: full reload %.3f s, only what changed %.3f s; matrix %.0f MB; search p50 %.3f s max %.3f s",
                     count, fill, Double(size) / 1e6, first, full, changed,
                     Double((matrix?.count ?? 0) * VectorMath.dimension * 2) / 1e6, times[times.count / 2], times.last!))
        #expect(matrix?.count == count)
    }

    @Test("A-20 at scale: a library of tens of thousands, listed against followed by its changes", arguments: [50_000])
    func photos(_ count: Int) throws {
        let scratch = try Scratch()
        let store = try scratch.store()
        let photos = FakePhotos((0..<count).map { PhotoAsset.photo("P\($0)", "IMG_\($0).HEIC", modified: 1_000) })
        let first = try seconds { _ = try PhotoIndexing.sync(photos, store: store) }
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        indexer.photos = photos
        var read = 0
        let reading = try seconds { read = try indexer.readPending(batch: 500) }
        let changes = PhotoChangesBox()
        photos.watch { changes.add($0) }
        photos.change {
            for index in 0..<50 { $0[index * 7] = .photo("P\(index * 7)", "IMG_\(index * 7).HEIC", modified: 2_000) }
            $0.removeLast(25)
            for index in 0..<25 { $0.append(.photo("N\(index)", "IMG_N\(index).HEIC")) }
        }
        #expect(eventually { changes.all.count == 1 })
        let change = try #require(changes.all.first ?? nil)
        let applied = try seconds { _ = try PhotoIndexing.apply(change, source: photos, store: store) }
        let listedAgain = try seconds { _ = try PhotoIndexing.sync(photos, store: store) }
        let size = (try FileManager.default.attributesOfItem(atPath: store.file.path)[.size] as? NSNumber)?.intValue ?? 0
        print(String(format: "SCALE photos %d: first sync %.1f s, read %d in %.1f s, index %.0f MB; 100 changes: listed again %.3f s (fake library: PhotoKit's own listing not counted), applied %.3f s",
                     count, first, read, reading, Double(size) / 1e6, listedAgain, applied))
        #expect(try store.photoItems().count == count)
    }
}

struct VectorSliceTests {
    /// 200 notes read without vectors (a backlog luoke-core fills one at a time, slowly) and a resident started on them.
    func backlog(slice: TimeInterval) throws -> (Scratch, IndexStore, Resident, FakeHub) {
        let scratch = try Scratch()
        let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        var settings = Settings()
        settings.folders = [scratch.path + "/files"]
        settings.onBattery = true   // (reading must not wait for mains power in the test)
        try settings.save(data)
        for index in 0..<200 { try scratch.write("files/old/note \(index).md", "# Note \(index)\n\n这是第 \(index) 篇旧笔记。") }
        let store = try IndexStore(directory: data, home: scratch.path)
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        _ = try indexer.sync([scratch.path + "/files"])
        try indexer.readPending()
        let fake = try FakeHub()
        fake.batch = 1
        fake.delay = 0.1   // 200 requests: 20 s of filling
        let resident = try Resident(directory: data, hub: Hub(socket: fake.path, environment: [:]))
        resident.newFilesPerChange = 2
        resident.backlogEvery = 0.5
        resident.vectorSlice = slice
        resident.start()
        return (scratch, store, resident, fake)
    }

    @Test("Scale: a backlog of vectors doesn't hold changed files back (at 50,000 files, 150 waited over half an hour)")
    func backlogYieldsToReading() throws {
        let (scratch, store, resident, fake) = try backlog(slice: 0.5)
        defer { resident.stop() }
        #expect(eventually { ((try? store.counts().vectors) ?? 0) > 0 })   // filling has begun
        for index in 0..<10 { try scratch.write("files/new/fresh \(index).md", "# Fresh \(index)\n\n刚写的笔记 \(index)。") }
        // Two are read right away; the other eight on the next step, not after the backlog.
        #expect(eventually(8) {
            (try? store.counts().waitingToRead) == 0
                && (try? store.item(path: scratch.path + "/files/new/fresh 9.md"))??.state == "done"
        })
        #expect(try store.counts().waitingForVectors > 0)   // the backlog is still being filled
        _ = fake
    }
}
