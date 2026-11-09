@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import LuokeSearchKit

/// A Photos library made up by the test: drawn pictures, and a made-up film for every video. Never the real
/// library (`SystemPhotos` is only used by the app itself).
final class FakePhotos: PhotoSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _assets: [PhotoAsset] { didSet { byID = Self.index(_assets) } }
    /// Each asset by id (a library of tens of thousands is looked up one asset at a time).
    private var byID: [String: PhotoAsset]
    private static func index(_ assets: [PhotoAsset]) -> [String: PhotoAsset] {
        Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
    private var _access: PhotoAccess
    private var _opened: [String] = []
    private var _cloudOnly: Set<String> = []
    /// Each watcher with the library as it last told it (PhotoKit compares a change with the fetch it holds).
    private var watchers: [(changed: @Sendable (PhotoChanges?) -> Void, seen: [String: PhotoAsset])] = []
    /// Run once, right after the library is first listed: a change while a large library is being listed.
    private var _duringFirstListing: (() -> Void)?
    var duringFirstListing: (() -> Void)? {
        get { lock.withLock { _duringFirstListing } }
        set { lock.withLock { _duringFirstListing = newValue } }
    }

    init(_ assets: [PhotoAsset], access: PhotoAccess = .allowed) {
        _assets = assets
        byID = Self.index(assets)
        _access = access
    }

    var access: PhotoAccess {
        get { lock.withLock { _access } }
        set { lock.withLock { _access = newValue } }
    }
    var opened: [String] { lock.withLock { _opened } }
    /// Videos only in iCloud, not on this Mac.
    var cloudOnly: Set<String> {
        get { lock.withLock { _cloudOnly } }
        set { lock.withLock { _cloudOnly = newValue } }
    }

    func assets(shouldStop: () -> Bool, named: Set<String>) throws -> [PhotoAsset] {
        if shouldStop() { throw CancellationError() }
        let (list, during) = lock.withLock { () -> ([PhotoAsset], (() -> Void)?) in
            _listed += 1
            _named += _assets.count { !named.contains($0.id) }
            defer { _duringFirstListing = nil }
            return (_assets.map { named.contains($0.id) ? $0.withoutName : $0 }, _duringFirstListing)
        }
        during?()
        return list
    }

    /// How many times the whole library was listed; how many original names were looked up in those listings.
    var listed: Int { lock.withLock { _listed } }
    var named: Int { lock.withLock { _named } }
    private var _listed = 0
    private var _named = 0

    func asset(_ id: String) -> PhotoAsset? { lock.withLock { _looked += 1; return byID[id] } }
    /// How many times an asset was looked up: the real library asks the user on the first lookup.
    var looked: Int { lock.withLock { _looked } }
    private var _looked = 0

    func image(_ id: String, maxPixels: Int) throws -> CGImage {
        guard let asset = asset(id), !asset.isVideo else { throw SystemPhotos.Failure(description: "not a photo") }
        let scale = min(1, Double(maxPixels) / Double(max(asset.width, asset.height)))
        return Drawn.picture(["图库里的照片"], width: Int(Double(asset.width) * scale),
                             height: Int(Double(asset.height) * scale))
    }

    /// A video's own file, or a film made up in the test, in place of `TestMedia.threePictures`.
    private var _videoFiles: [String: URL] = [:]
    var videoFiles: [String: URL] {
        get { lock.withLock { _videoFiles } }
        set { lock.withLock { _videoFiles = newValue } }
    }
    private var _videoAssets: [String: AVAsset] = [:]
    var videoAssets: [String: AVAsset] {
        get { lock.withLock { _videoAssets } }
        set { lock.withLock { _videoAssets = newValue } }
    }

    func video(_ id: String) throws -> AVAsset {
        guard asset(id)?.isVideo == true else { throw SystemPhotos.Failure(description: "not in the Photos library any more") }
        guard !cloudOnly.contains(id) else { throw SystemPhotos.NotOnThisMac() }
        if let made = videoAssets[id] { return made }
        return AVURLAsset(url: videoFiles[id] ?? TestMedia.threePictures)
    }

    func open(_ id: String) { lock.withLock { _opened.append(id) } }

    func watch(_ changed: @escaping @Sendable (PhotoChanges?) -> Void) {
        lock.withLock { watchers.append((changed, byID)) }   // what it compares with: the library as it is now
    }

    /// Changes the library and tells each watcher what changed since it was last told, from another thread, as
    /// PhotoKit does (new ones with their names, changed ones without); `details: false`, as when PhotoKit can't say.
    func change(details: Bool = true, _ edit: (inout [PhotoAsset]) -> Void) {
        let deliveries = lock.withLock { () -> [(@Sendable (PhotoChanges?) -> Void, PhotoChanges)] in
            edit(&_assets)
            return watchers.indices.map { index in
                let before = watchers[index].seen
                var changes = PhotoChanges()
                for asset in _assets {
                    if let old = before[asset.id] {
                        if old != asset { changes.changed.append(asset.withoutName) }
                    } else {
                        changes.inserted.append(asset)
                    }
                }
                changes.removed = before.keys.filter { byID[$0] == nil }.sorted()
                watchers[index].seen = byID
                return (watchers[index].changed, changes)
            }
        }
        DispatchQueue.global().async { for (watcher, changes) in deliveries { watcher(details ? changes : nil) } }
    }

}

extension PhotoAsset {
    var withoutName: PhotoAsset {
        PhotoAsset(id: id, isVideo: isVideo, created: created, modified: modified, width: width, height: height, filename: nil)
    }

    static func photo(_ id: String, _ name: String?, taken: String = "2026-09-14T10:02:00+08:00", modified: Double = 1_000,
                      size: Int = 3024) -> PhotoAsset {
        PhotoAsset(id: id, isVideo: false, created: date(taken), modified: modified, width: size, height: size * 3 / 4,
                   filename: name)
    }

    static func video(_ id: String, _ name: String?, taken: String = "2026-09-18T18:30:00+08:00") -> PhotoAsset {
        PhotoAsset(id: id, isVideo: true, created: date(taken), modified: 1_000, width: 720, height: 720, filename: name)
    }

    static func date(_ text: String) -> Double { ISO8601DateFormatter().date(from: text)!.timeIntervalSince1970 }
}

extension IndexStore {
    /// An item's segments other than its name, in order: kind and place.
    func readSegments(_ path: String) throws -> [String] {
        var out: [String] = []
        try db.query("""
            SELECT s.kind, s.loc FROM segments s JOIN items i ON i.id = s.item
            WHERE i.path = ? AND s.kind != 'name' ORDER BY s.id
            """, [.text(path)]) { row in
            out.append(row.text(0)! + (row.text(1).map { "@" + $0 } ?? ""))
        }
        return out
    }
}

extension ReadsPictures {
    struct PhotosTests {
        @Test("The user's say for this app is separate from macOS's: photos off means not read")
        func anAppNotAllowedReadsNothing() {
            #expect(SystemPhotos.notAllowed("photos"))
            #expect(SystemPhotos.notAllowed("fda, photos "))
            #expect(!SystemPhotos.notAllowed(nil))
            #expect(!SystemPhotos.notAllowed(""))
            #expect(!SystemPhotos.notAllowed("photos2"))
        }

        @Test func theLibraryIsIndexedReadAndKeptInStep() throws {
            let scratch = try Scratch()
            let store = try scratch.store()
            let photos = FakePhotos([
                .photo("A1/L0/001", "IMG_1001.HEIC", taken: "2026-09-14T10:02:00+08:00"),
                .photo("A2/L0/001", nil, taken: "2026-09-15T08:00:00+08:00"),
                .photo("A3/L0/001", "IMG_0003.PNG", size: 120),   // an icon-sized picture
                .video("V1/L0/001", "VID_0001.MOV"),
            ])
            #expect(try PhotoIndexing.sync(photos, store: store).added == 4)
            // Its name is searchable before anything is read; it's not a file.
            let searcher = Searcher(store: store)
            let early = try #require(try searcher.search("IMG_1001").hits.first)
            #expect(early.title == "IMG_1001.HEIC")
            #expect(early.path == nil)
            // With no library to read from in this process, Photos items wait; folders' pruning leaves them alone.
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            #expect(try indexer.readPending() == 0)
            #expect(try indexer.prune(keeping: []) == 0)
            indexer.photos = photos
            #expect(try indexer.readPending() == 4)
            #expect(try store.readSegments("photos:A1/L0/001") == ["image"])
            #expect(try store.item(path: "photos:A3/L0/001")?.state == "skipped")
            #expect(try store.readSegments("photos:V1/L0/001") == ["frame@0.5", "frame@6.5", "frame@12.5"])
            // "照片" alone: the newest photos, those in folders and in Photos alike; one without a name is "照片".
            let newest = try searcher.search("照片").hits
            #expect(newest.map(\.title) == ["照片", "IMG_1001.HEIC"])
            #expect(newest.last?.date.hasPrefix("2026-09-14") == true)   // when it was taken
            // Edited, deleted: read again, gone.
            photos.change {
                $0[0] = .photo("A1/L0/001", "IMG_1001.HEIC", modified: 2_000)
                $0.remove(at: 1)
            }
            let again = try PhotoIndexing.sync(photos, store: store)
            #expect((again.added, again.changed, again.removed, again.unchanged) == (0, 1, 1, 2))
            #expect(try store.item(path: "photos:A1/L0/001")?.state == "pending")
            #expect(try store.item(path: "photos:A2/L0/001") == nil)
            // Turned off: all of them leave the index.
            #expect(try PhotoIndexing.removeAll(store: store) == 3)
            #expect(try searcher.search("IMG_1001").hits.isEmpty)
        }

        @Test func picturesAndFramesGoToTheHubLikeFiles() throws {
            let scratch = try Scratch()
            let store = try scratch.store()
            let photos = FakePhotos([.photo("A1", "IMG_1001.HEIC"), .video("V1", "VID_0001.MOV")])
            _ = try PhotoIndexing.sync(photos, store: store)
            let indexer = Indexer(store: store)
            indexer.photos = photos
            try indexer.readPending()
            #expect(try store.counts().waitingForMedia == 2)   // the photo; the video (three frames)
            let fake = try FakeHub()
            fake.takesMedia = true
            let hub = Hub(socket: fake.path, environment: [:])
            // Not in a process that may read the library: they wait, nothing is given up.
            #expect(VectorFiller(store: store, hub: hub).run(wait: false).embeddedMedia == 0)
            #expect(try store.counts().waitingForMedia == 2)
            let filler = VectorFiller(store: store, hub: hub)
            filler.photos = photos
            let report = filler.run(wait: false)
            #expect(report.embeddedMedia == 4)
            #expect(try store.counts().waitingForMedia == 0)
            let sent = fake.inputRequests.flatMap { $0 }
            #expect(sent.compactMap { $0["budget"] as? Int }.sorted() == [70, 70, 70, 140])
            // A video only in iCloud isn't downloaded: its frames wait, not given up (review A-10).
            photos.cloudOnly = ["V1"]
            let frame = MediaInputs.Wanted(segment: 9, kind: .frame, loc: 0.5)
            let cloud = MediaInputs.Source(path: "photos:V1", kind: .video, wanted: [frame], task: HubTask(status: .available),
                                           photos: photos)
            guard case .later(9, "only in iCloud")? = cloud.next() else { Issue.record("not waiting"); return }
            let none = MediaInputs.make(path: "photos:A1", kind: .photo, wanted: [frame], task: HubTask(status: .available))
            #expect(none.made.isEmpty && none.impossible.isEmpty)
        }

        @Test func theAgentOpensPhotosAndSaysWhatsNeeded() throws {
            let photos = FakePhotos([.photo("A1", "IMG_1001.HEIC")])
            let agent = try Agent(photos: photos)
            _ = try PhotoIndexing.sync(photos, store: agent.library.store)
            let hits = try #require((agent.call("search_query", ["query": "IMG_1001"])["structuredContent"]
                                     as? [String: Any])?["hits"] as? [[String: Any]])
            #expect(hits.first?["title"] as? String == "IMG_1001.HEIC")
            #expect(hits.first?["path"] == nil || hits.first?["path"] is NSNull)
            let id = try #require(hits.first?["id"] as? String)
            let opened = agent.call("search_open", ["id": id], tapped: "q-1")
            let text = try #require((opened["content"] as? [[String: Any]])?.first?["text"] as? String)
            #expect(text.hasPrefix("已打开「照片」。这张是 2026-09-"))
            #expect(photos.opened == ["A1"])
            #expect(agent.opened.log.isEmpty)   // nothing opened as a file
            // Status and outbox: on, then not allowed.
            #expect(try agent.service.status()["photos"] as? String == "off")
            var settings = Settings()
            settings.photos = true
            try settings.save(agent.directory)
            #expect(try agent.service.status()["photos"] as? String == "on")
            #expect((agent.service.outbox()["items"] as? [Any])?.isEmpty == true)
            photos.access = .denied
            #expect(try agent.service.status()["photos"] as? String == "needs_access")
            let outbox = try #require(agent.service.outbox()["items"] as? [[String: Any]])
            #expect(outbox.map { $0["id"] as? String }
                    == [SearchService.photosID(ToolState.load(agent.directory).photosItem)])
            #expect(outbox.first?["card"] != nil)
            #expect(outbox.first?["permission"] as? String == "photos" && outbox.first?["urgency"] as? String == "low")
            // Not allowed: can't be read, not gone (luoke-search#46, defect 6). Allowed again and deleted from the
            // library: stale.
            let unread = agent.call("search_open", ["id": id], tapped: "q-1")
            #expect((unread["structuredContent"] as? [String: Any])?["code"] as? String == "failed")
            photos.access = .allowed
            photos.change { $0.removeAll() }
            let gone = agent.call("search_open", ["id": id], tapped: "q-1")
            #expect((gone["structuredContent"] as? [String: Any])?["code"] as? String == "stale")
        }

        /// The resident never asks macOS itself (§1a): the outbox says so, luoke's own program asks, and the resident
        /// finds the answer at its next look, told by nobody. Then it follows the library.
        @Test func residentNeverAsksThenFollowsTheLibrary() throws {
            let scratch = try Scratch()
            let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
            var settings = Settings()
            settings.photos = true
            try settings.save(data)
            let photos = FakePhotos([.photo("A1", "IMG_1001.HEIC")], access: .notAsked)
            let resident = try Resident(directory: data, hub: nil, photos: photos)
            resident.readsBacklog = false
            resident.backlogEvery = 0.2
            resident.start()
            defer { resident.stop() }
            let store = try IndexStore(directory: data, home: scratch.path)
            let searcher = Searcher(store: store)
            resident.queue.sync {}   // its first look (queued first) is over
            #expect(try store.item(path: "photos:A1") == nil)
            // Allowed in luoke's own window: noticed at the next look.
            photos.access = .allowed
            #expect(try eventually { try store.item(path: "photos:A1")?.state == "done" })
            #expect(try searcher.search("IMG_1001").hits.first?.title == "IMG_1001.HEIC")
            // A photo taken now is searchable a moment after.
            photos.change { $0.append(.photo("A2", "IMG_2002.HEIC")) }
            #expect(try eventually { try store.item(path: "photos:A2")?.state == "done" })
            // Turned off: Photos items leave the index.
            settings.photos = false
            try settings.save(data)
            resident.settingsChanged()
            #expect(try eventually { try store.photoItems().isEmpty })
        }

        @Test func firstPassTakesPhotosOnlyWhenOnAndAllowed() throws {
            let scratch = try Scratch()
            let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
            let store = try IndexStore(directory: data, home: scratch.path)
            let photos = FakePhotos([.photo("A1", "IMG_1001.HEIC"), .photo("A2", "IMG_1002.HEIC")], access: .denied)
            let pass = FirstPass(directory: data, store: store, hub: nil, photos: photos)
            var settings = Settings()
            settings.photos = true
            try settings.save(data)
            #expect(try pass.run().sync.added == 0)   // not allowed: nothing taken
            photos.access = .allowed
            let report = try pass.run()
            #expect((report.sync.added, report.read) == (2, 2))
            #expect(ToolState.load(data).firstPassDone != nil)
            settings.photos = false
            try settings.save(data)
            #expect(try pass.run().sync.removed == 2)
            #expect(try store.photoItems().isEmpty)
        }
    }
}
