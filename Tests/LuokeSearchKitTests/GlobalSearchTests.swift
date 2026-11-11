@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import LuokeSearchKit

/// A Photos library whose pictures take as long as the test likes: drawing one says it has started, then waits for
/// `go`.
final class SlowPhotos: PhotoSource, @unchecked Sendable {
    let base: FakePhotos
    let started = DispatchSemaphore(value: 0)
    let go = DispatchSemaphore(value: 0)

    init(_ base: FakePhotos) { self.base = base }

    var access: PhotoAccess { base.access }
    func assets(shouldStop: () -> Bool, named: Set<String>) throws -> [PhotoAsset] {
        try base.assets(shouldStop: shouldStop, named: named)
    }
    func asset(_ id: String) -> PhotoAsset? { base.asset(id) }
    func image(_ id: String, maxPixels: Int) throws -> CGImage {
        started.signal()
        go.wait()
        return try base.image(id, maxPixels: maxPixels)
    }
    func video(_ id: String) throws -> AVAsset { try base.video(id) }
    func open(_ id: String) { base.open(id) }
    func watch(_ changed: @escaping @Sendable (PhotoChanges?) -> Void) { base.watch(changed) }
}

/// The window's global search (agent tool protocol §1b, luoke-agent#3): the manifest names `search_query`, its hits
/// come in the window's shape, a time alone lists the newest, and results with a picture have a thumbnail.
extension ReadsPictures {
    struct GlobalSearchTests {
        static func hits(_ result: [String: Any]) throws -> [[String: Any]] {
            try #require((result["structuredContent"] as? [String: Any])?["hits"] as? [[String: Any]])
        }

        static func toolNames(_ agent: Agent) -> Set<String> {
            let tools = (agent.request("tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
            return Set(tools.compactMap { $0["name"] as? String })
        }

        /// A thumbnail as the window gets it: a JPEG, and its size. Nil when there's none.
        static func thumb(_ agent: Agent, _ uri: String) -> (data: Data, width: Int, height: Int)? {
            guard let result = agent.request("resources/read", ["uri": uri])["result"] as? [String: Any],
                  let content = (result["contents"] as? [[String: Any]])?.first,
                  content["mimeType"] as? String == "image/jpeg", content["uri"] as? String == uri,
                  let blob = content["blob"] as? String, let data = Data(base64Encoded: blob) else { return nil }
            return picture(data).map { (data, $0.width, $0.height) }
        }

        static func picture(_ data: Data) -> CGImage? {
            guard data.starts(with: [0xFF, 0xD8, 0xFF]), let source = CGImageSourceCreateWithData(data as CFData, nil)
            else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }

        static func item(_ agent: Agent, _ relative: String) throws -> String {
            var id: Int64?
            try agent.library.store.db.query("SELECT id FROM items WHERE path = ?",
                                             [.text(agent.library.root + "/" + relative)]) { id = $0.int(0) }
            return String(try #require(id))
        }

        /// The red, green and blue of one pixel (from the top left).
        static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
            return Array(bytes.prefix(3))
        }

        @Test func theWindowSearchesWithSearchQuery() throws {
            let service = try #require(AgentTools.manifestCapabilities["service"] as? [String: Any])
            #expect(service["ask"] as? [String: String] == ["search": "search_query"])
            // Read-only, and a time alone will do: no word is required.
            let agent = try Agent()
            let tools = (agent.request("tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
            let search = try #require(tools.first { $0["name"] as? String == "search_query" })
            #expect((search["annotations"] as? [String: Bool])?["readOnlyHint"] == true)
            #expect(((search["inputSchema"] as? [String: Any])?["required"] as? [String] ?? []).isEmpty)
        }

        @Test func hitsInTheWindowsShape() throws {
            let agent = try Agent()
            let names = Self.toolNames(agent)
            let found = agent.call("search_query", ["query": "押金"])
            let first = try #require(try Self.hits(found).first)
            #expect(first["title"] as? String == "租赁合同摘要.md")
            #expect(first["source"] as? String == "files")
            // 「押金」 is only in the text, and there are no vectors here: found, not sure.
            #expect(first["kind"] as? String == "doc" && first["strong"] as? Bool == false)
            let named = try #require(try Self.hits(agent.call("search_query", ["query": "租赁合同"])).first)
            #expect(named["title"] as? String == "租赁合同摘要.md" && named["strong"] as? Bool == true)
            #expect(first["kind_label"] as? String == "文档")
            #expect(first["thumb"] == nil)   // a document has no picture
            // Ours as it was, for the agent's model; the card still comes as the fallback.
            #expect(first["why"] is String && first["path"] is String && first["date"] is String)
            #expect((found["structuredContent"] as? [String: Any])?["card"] is [Any])
            // The card's buttons: each a tool of this server, with this result's id.
            let actions = first["actions"] as? [[String: Any]] ?? []
            #expect(actions.map { $0["title"] as? String } == ["打开", "在访达中显示"])
            #expect(actions.map { $0["primary"] as? Bool } == [true, false])
            for action in actions {
                #expect(names.contains(action["name"] as? String ?? ""))
                #expect((action["args"] as? [String: Any])?["id"] as? String == first["id"] as? String)
            }
            #expect((actions.last?["args"] as? [String: Any])?["reveal"] as? Bool == true)
            // A slide: the line says which.
            let slide = try #require(try Self.hits(agent.call("search_query", ["query": "团队版"]))
                .first { $0["title"] as? String == "发布会.pptx" })
            #expect(slide["line"] as? String == "第 2 页")
            // A screenshot: its thumbnail, by item.
            let shot = try #require(try Self.hits(agent.call("search_query", ["query": "构建失败"]))
                .first { $0["kind"] as? String == "screenshot" })
            let item = try Self.item(agent, "app/Screenshot 2026-10-01 at 10.00.00.png")
            #expect(shot["thumb"] as? String == "thumb/\(item)")
            #expect(shot["kind_label"] as? String == "截图")
        }

        @Test func aTimeAloneLists() throws {
            let agent = try Agent()
            let march = DateComponents(calendar: .current, year: 2025, month: 3, day: 9, hour: 12).date!
            try FileManager.default.setAttributes([.modificationDate: march],
                                                  ofItemAtPath: agent.library.root + "/notes/running.txt")
            _ = try agent.library.index()
            let listed = try Self.hits(agent.call("search_query", ["since": "2025-03-01", "until": "2025-03-31"]))
            #expect(listed.map { $0["title"] as? String } == ["running.txt"])
            #expect(listed.first?["why"] as? String == "时间对得上（最新的在前）")
            // A time without its zone is this Mac's, not the whole day.
            let around = try Self.hits(agent.call("search_query", ["since": "2025-03-09T11:00:00",
                                                                     "until": "2025-03-09T13:00"]))
            #expect(around.map { $0["title"] as? String } == ["running.txt"])
            let after = try Self.hits(agent.call("search_query", ["since": "2025-03-09T12:30", "until": "2025-03-09"]))
            #expect(after.isEmpty)
            let garbled = agent.call("search_query", ["since": "2025-03-09Tnoon"])
            #expect((garbled["structuredContent"] as? [String: Any])?["code"] as? String == "invalid")
            // Blank words are none; the newest first.
            let yesterday = Date().addingTimeInterval(-86_400).formatted(.iso8601.year().month().day())
            let recent = try Self.hits(agent.call("search_query", ["query": " ", "since": yesterday, "limit": 50]))
            #expect(recent.count > 3 && !recent.contains { $0["title"] as? String == "running.txt" })
            let times = recent.compactMap { ($0["date"] as? String).flatMap { try? Date($0, strategy: .iso8601) } }
            #expect(times.count == recent.count && zip(times, times.dropFirst()).allSatisfy { $0 >= $1 })
            // Kinds alone too.
            let shots = try Self.hits(agent.call("search_query", ["kinds": ["screenshot"]]))
            #expect(shots.map { $0["kind"] as? String } == ["screenshot"])
            // Nothing in that time: certainly not found.
            let none = try #require(agent.call("search_query", ["until": "2000-01-01"])["structuredContent"]
                                    as? [String: Any])
            #expect((none["hits"] as? [Any])?.isEmpty == true && none["confident"] as? Bool == false)
            // Nothing at all, or words that aren't words: still a question.
            for arguments: [String: Any] in [[:], ["query": ""], ["query": 3, "since": yesterday]] {
                let asked = agent.call("search_query", arguments)
                #expect(asked["isError"] as? Bool == true)
                #expect((asked["structuredContent"] as? [String: Any])?["code"] as? String == "invalid")
            }
        }

        @Test func filesGoneSinceAreReplacedByTheNextNewest() throws {
            let agent = try Agent()
            // More than a page of the newest, all gone since they were indexed (a drive unplugged).
            let later = DateComponents(calendar: .current, year: 2030, month: 1, day: 1).date!
            for number in 0..<60 {
                let file = try agent.library.scratch.write("files/盘/\(number).txt", "第 \(number) 个")
                try FileManager.default.setAttributes([.modificationDate: later.addingTimeInterval(Double(number))],
                                                      ofItemAtPath: file.path)
            }
            _ = try agent.library.index()
            try FileManager.default.removeItem(atPath: agent.library.root + "/盘")
            let listed = try Self.hits(agent.call("search_query", ["since": "2000-01-01", "limit": 3]))
            #expect(listed.count == 3)
            #expect(listed.allSatisfy { FileManager.default.fileExists(atPath: $0["path"] as? String ?? "") })
        }

        @Test func thumbnailsAsTheWindowTakesThem() throws {
            let agent = try Agent()
            let scratch = agent.library.scratch
            try scratch.write("files/扫描/合同.pdf", data: Drawn.pdf(textPage: ["租赁合同"], scannedPage: ["签字页"]))
            // A picture with a transparent background: on white, not black.
            let clear = CGContext(data: nil, width: 600, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            clear.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            clear.fill(CGRect(x: 250, y: 100, width: 100, height: 100))
            try scratch.write("files/图/透明.png", data: Drawn.png(clear.makeImage()!))
            try scratch.write("files/图/图标.svg",
                              "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\"/></svg>")
            _ = try agent.library.index()

            // The screenshot (1200 × 600): 400 on its long side, a JPEG under the window's limit.
            let shot = try #require(Self.thumb(agent, "thumb/" + Self.item(agent, "app/Screenshot 2026-10-01 at 10.00.00.png")))
            #expect(shot.width == Thumbs.pixels && shot.height == Thumbs.pixels / 2)
            #expect(shot.data.count <= Thumbs.maxBytes)
            // A PDF: its first page, upright.
            let pdf = try #require(Self.thumb(agent, "thumb/" + Self.item(agent, "扫描/合同.pdf")))
            #expect(pdf.height == Thumbs.pixels && pdf.width < pdf.height)
            let transparent = try #require(Self.thumb(agent, "thumb/" + Self.item(agent, "图/透明.png")))
            let picture = try #require(Self.picture(transparent.data))
            #expect(Self.pixel(picture, x: 2, y: 2).allSatisfy { $0 > 240 })
            #expect(Self.pixel(picture, x: picture.width / 2, y: picture.height / 2).allSatisfy { $0 < 40 })

            // None: a document, SVG, an id that isn't an item's, a file gone since.
            let svg = try Self.item(agent, "图/图标.svg"), text = try Self.item(agent, "notes/running.txt")
            for uri in ["thumb/" + text, "thumb/" + svg, "thumb/abc", "thumb/0",
                        "thumb/+3", "thumb/999999", "thumb/", "thumb/\(svg)#p1"] {
                #expect(Self.thumb(agent, uri) == nil, "\(uri)")
                #expect((agent.request("resources/read", ["uri": uri])["error"] as? [String: Any])?["code"] as? Int
                        == -32002)
            }
            let item = try Self.item(agent, "扫描/合同.pdf")
            try FileManager.default.removeItem(atPath: agent.library.root + "/扫描/合同.pdf")
            #expect(Self.thumb(agent, "thumb/" + item) == nil)
            // Only in iCloud: not read, as the crawler doesn't (it would be downloaded).
            let inCloud = "thumb/" + (try Self.item(agent, "图/透明.png"))
            agent.service.isDataless = { _ in true }
            #expect(Self.thumb(agent, inCloud) == nil)
            // Not listed with the others: their ids come in the hits.
            let listed = (agent.request("resources/list")["result"] as? [String: Any])?["resources"] as? [[String: Any]]
            #expect(listed?.contains { ($0["uri"] as? String ?? "").hasPrefix("thumb/") } == false)
        }

        @Test func photosHaveTheirOwnSourceAndNoFinder() throws {
            let photos = FakePhotos([.photo("A1", "IMG_1001.HEIC"), .video("V1", "IMG_2002.MOV")])
            let agent = try Agent(photos: photos)
            _ = try PhotoIndexing.sync(photos, store: agent.library.store)
            let hit = try #require(try Self.hits(agent.call("search_query", ["query": "IMG_1001"])).first)
            #expect(hit["source"] as? String == "photos")
            #expect((hit["actions"] as? [[String: Any]])?.map { $0["title"] as? String } == ["打开"])
            let uri = try #require(hit["thumb"] as? String)
            let photo = try #require(Self.thumb(agent, uri))
            #expect(photo.width == Thumbs.pixels && photo.height == Thumbs.pixels * 3 / 4)
            // A video in the library: a frame of it.
            let video = try #require(try Self.hits(agent.call("search_query", ["query": "IMG_2002"])).first)
            let videoURI = try #require(video["thumb"] as? String)
            let frame = try #require(Self.thumb(agent, videoURI))
            #expect(max(frame.width, frame.height) <= Thumbs.pixels)
            // Gone from the library: none.
            photos.change { $0.removeAll { $0.id == "A1" } }
            #expect(Self.thumb(agent, uri) == nil)
        }

        /// The row under the window's results (§1b, "照片还没允许搜"): what the search didn't look in, or only partly,
        /// and why.
        @Test func photosNotSearchedSaySo() throws {
            let photos = FakePhotos([.photo("A1", "IMG_1001.HEIC")], access: .notAsked)
            let agent = try Agent(photos: photos)
            func skipped(_ agent: Agent, _ arguments: [String: Any] = ["query": "IMG_1001"])
                throws -> (rows: [[String: Any]], text: String, hits: [[String: Any]]) {
                let result = agent.call("search_query", arguments)
                let structured = try #require(result["structuredContent"] as? [String: Any])
                let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
                return (try #require(structured["skipped"] as? [[String: Any]]), text,
                        try #require(structured["hits"] as? [[String: Any]]))
            }
            // Not chosen in the settings: said in the structure only, not to the model with every search.
            var settings = Settings()
            try settings.save(agent.directory)
            var (rows, text, hits) = try skipped(agent)
            #expect(rows.count == 1 && rows[0]["source"] as? String == "photos" && rows[0]["why"] as? String == "off")
            #expect(rows[0]["permission"] == nil && rows[0]["text"] as? String == "没在搜照片图库")
            #expect(rows[0]["detail"] as? String == "要搜的话，在螺壳搜索的设置里打开照片图库")
            #expect(!text.contains("没在搜"))
            // Chosen, macOS not asked yet: the permission the window asks with (the manifest's `request`).
            settings.photos = true
            try settings.save(agent.directory)
            (rows, text, _) = try skipped(agent)
            #expect(rows.map { $0["why"] as? String } == ["needs_access"])
            #expect(rows[0]["permission"] as? String == "photos" && rows[0]["text"] as? String == "照片还没允许搜")
            #expect(text.hasSuffix("（照片还没允许搜）"))
            #expect(rows[0]["detail"] as? String == "允许以后，照片里的字和画面也能搜到")
            #expect(!text.contains("画面"))   // the line under it is the window's, not the model's
            // Only the folders' files asked for: the library isn't left out, it's not asked.
            (rows, _, _) = try skipped(agent, ["query": "IMG_1001", "sources": ["files"]])
            #expect(rows.isEmpty)
            (rows, _, _) = try skipped(agent, ["query": "IMG_1001", "sources": ["photos"]])
            #expect(rows.count == 1)
            // Refused.
            photos.access = .denied
            (rows, text, _) = try skipped(agent)
            #expect(rows.map { $0["why"] as? String } == ["denied"] && rows[0]["permission"] as? String == "photos")
            #expect(text.hasSuffix("（照片没允许读，要在系统设置里允许）"))
            #expect((rows[0]["detail"] as? String)?.hasPrefix("在 系统设置 › 隐私与安全性 › 照片 里允许以后") == true)
            // Only kinds the library doesn't have: nothing to say.
            (rows, _, _) = try skipped(agent, ["query": "IMG_1001", "kinds": ["doc", "pdf"]])
            #expect(rows.isEmpty)
            (rows, _, _) = try skipped(agent, ["query": "IMG_1001", "kinds": ["video"]])
            #expect(rows.count == 1)
            // Allowed: an empty list, and the text as it was.
            photos.access = .allowed
            _ = try PhotoIndexing.sync(photos, store: agent.library.store)
            (rows, text, hits) = try skipped(agent)
            #expect(rows.isEmpty && hits.first?["source"] as? String == "photos")
            #expect(!text.contains("允许") && !text.contains("没在搜"))
            // Refused after it was read: what was read is still found, so not "not searched".
            photos.access = .denied
            (rows, text, hits) = try skipped(agent)
            #expect(hits.first?["source"] as? String == "photos")
            #expect(rows.map { $0["why"] as? String } == ["not_updated"] && rows[0]["permission"] as? String == "photos")
            #expect(text.hasSuffix("（照片没允许读了，只搜得到以前读过的）"))
            #expect(rows[0]["detail"] as? String == "再允许以后，新拍的照片也能搜到")
            // Permission taken back after it was read: what was read isn't found either, and the row says to allow.
            photos.access = .notAsked
            (rows, text, hits) = try skipped(agent)
            #expect(hits.isEmpty)
            #expect(rows.map { $0["why"] as? String } == ["needs_access"] && rows[0]["permission"] as? String == "photos")
            #expect(text.hasSuffix("（照片还没允许搜）"))
            // A process that has the library but doesn't judge access (the app's program run in a terminal): its
            // answer is the terminal's, so nothing about access, and nothing hidden; the settings' choice still.
            agent.service.judgesAccess = false
            (rows, _, hits) = try skipped(agent)
            #expect(rows.isEmpty && hits.first?["source"] as? String == "photos")
            settings.photos = false
            try settings.save(agent.directory)
            (rows, _, _) = try skipped(agent)
            #expect(rows.map { $0["why"] as? String } == ["off"])
            // A process that doesn't read Photos (the command line): nothing at all.
            let terminal = try Agent()
            var chosen = Settings()
            chosen.photos = true
            try chosen.save(terminal.directory)
            #expect(try skipped(terminal, ["query": "x"]).rows.isEmpty)
            try Settings().save(terminal.directory)
            #expect(try skipped(terminal, ["query": "x"]).rows.isEmpty)
        }

        /// Permission taken back: the records stay, nothing finds them; allowed again they're found with no new reading.
        @Test func photosWithoutPermissionAreNotFoundButStayInTheIndex() throws {
            let photos = FakePhotos([.photo("A1", "Zephyrine-1.HEIC"), .photo("A2", "Zephyrine-2.HEIC")], access: .allowed)
            let agent = try Agent(photos: photos)
            let store = agent.library.store
            try agent.library.scratch.write("files/notes/zephyrine.txt", "zephyrine")
            _ = try agent.library.index()
            _ = try PhotoIndexing.sync(photos, store: store)
            let photo = try #require(try store.item(path: "photos:A1"))

            func answer(_ options: SearchOptions = SearchOptions(), text: String = "Zephyrine") throws -> SearchAnswer {
                try agent.service.search(text, options: options)
            }
            func newest(_ sources: Set<ItemSource>? = nil) throws -> SearchAnswer {
                try answer(SearchOptions(kinds: [.photo], sources: sources), text: "")
            }
            let before = try answer()
            #expect(before.totals == ["files": 1, "photos": 2] && before.hits.count == 3)
            #expect(try newest().totals?["photos"] == 2)
            #expect(try answer(text: "照片").totals?["photos"] == 2)

            photos.access = .notAsked
            let hidden = try answer()
            #expect(hidden.totals == ["files": 1, "photos": 0])
            #expect(hidden.hits.map(\.path) == [agent.library.root + "/notes/zephyrine.txt"])
            #expect(try answer(SearchOptions(sources: [.photos])).hits.isEmpty)
            #expect(try newest().hits.isEmpty && newest().totals?["photos"] == 0)
            #expect(try newest([.photos]).hits.isEmpty)
            #expect(try answer(text: "照片").totals?["photos"] == 0)
            #expect(try store.photoItems().count == 2)
            // A result still on screen: 找相似的 doesn't start from it. Not "no vectors yet": there's nothing to wait for.
            let similar = try #require(try agent.service.similar(String(photo.id), options: SearchOptions()))
            #expect(similar.hits.isEmpty && similar.partialReason == nil)

            // Refused in System Settings: what was read is still found (the user's own permission stands).
            photos.access = .denied
            #expect(try answer().totals?["photos"] == 2)

            photos.access = .allowed
            let back = try answer()
            #expect(back.totals == before.totals && back.hits.count == before.hits.count)
            #expect(try store.item(path: "photos:A1")?.id == photo.id)
        }

        /// The window's filter (全部 / 文件 / 照片和视频) and its counts ("文件 12"): `sources` keeps to one, `totals`
        /// counts each whatever the limit and the filter.
        @Test func countsAndSourcesForTheWindowsFilter() throws {
            let photos = FakePhotos([.photo("A1", "Zephyrine.HEIC"), .photo("A2", "IMG_1002.HEIC")], access: .allowed)
            let agent = try Agent(photos: photos)
            for number in 1...3 {
                try agent.library.scratch.write("files/zeph/\(number).txt", "Zephyrine notes, part \(number).")
            }
            _ = try agent.library.index()
            _ = try PhotoIndexing.sync(photos, store: agent.library.store)
            func search(_ arguments: [String: Any]) throws -> (hits: [[String: Any]], totals: [String: Int]) {
                let structured = try #require(agent.call("search_query", arguments)["structuredContent"] as? [String: Any])
                return (try #require(structured["hits"] as? [[String: Any]]),
                        try #require(structured["totals"] as? [String: Int]))
            }
            let sources = { (hits: [[String: Any]]) in Set(hits.compactMap { $0["source"] as? String }) }
            var (hits, totals) = try search(["query": "zephyrine", "limit": 1])
            #expect(hits.count == 1 && totals == ["files": 3, "photos": 1])
            (hits, totals) = try search(["query": "zephyrine", "sources": ["photos"]])
            #expect(hits.map { $0["title"] as? String } == ["Zephyrine.HEIC"] && totals == ["files": 3, "photos": 1])
            (hits, totals) = try search(["query": "zephyrine", "sources": ["files"]])
            #expect(hits.count == 3 && sources(hits) == ["files"] && totals == ["files": 3, "photos": 1])
            // A source this tool doesn't know: every source, as with no filter.
            (hits, _) = try search(["query": "zephyrine", "sources": ["mail"]])
            #expect(sources(hits) == ["files", "photos"])
            // Nothing found: each source's zero, not missing.
            (_, totals) = try search(["query": "qwxzvbnm"])
            #expect(totals == ["files": 0, "photos": 0])
            // A time alone: the newest of that source, and how many there are of each.
            (hits, totals) = try search(["since": "2000-01-01", "sources": ["photos"], "limit": 50])
            #expect(hits.count == 2 && sources(hits) == ["photos"] && totals["photos"] == 2)
            let everything = try search(["since": "2000-01-01", "limit": 50]).hits
            #expect(totals["files"] == everything.count - 2)
            // Only a kind's word, nothing by meaning: the newest of that kind, counted as listed.
            (hits, totals) = try search(["query": "截图"])
            #expect(!hits.isEmpty && hits.allSatisfy { $0["kind"] as? String == "screenshot" })
            #expect(totals == ["files": hits.count, "photos": 0])
            // A source alone, no words: the newest from it (the filter tapped with nothing typed).
            (hits, _) = try search(["sources": ["photos"]])
            #expect(hits.count == 2 && sources(hits) == ["photos"])
            // The search the agent's model makes: as before, with the counts too.
            #expect(try Searcher(store: agent.library.store).search("zephyrine", options: SearchOptions(sources: [.files]))
                .hits.count == 3)
        }

        /// Asks on a thread of its own (the server's lock would hold the test up otherwise): whether the answer came
        /// within `within` seconds, and whether it was a blob.
        static func ask(_ server: MCPServer, _ uri: String, within: TimeInterval) -> (answered: Bool, blob: Bool) {
            final class Box: @unchecked Sendable { var blob = false }
            let box = Box(), done = DispatchSemaphore(value: 0)
            onAnotherThread {
                let answer = server.handle(["jsonrpc": "2.0", "id": 1, "method": "resources/read",
                                            "params": ["uri": uri]])
                box.blob = ((answer?["result"] as? [String: Any])?["contents"] as? [[String: Any]])?.first?["blob"] != nil
                done.signal()
            }
            let answered = done.wait(timeout: .now() + within) == .success
            return (answered, answered && box.blob)
        }

        @Test func drawnOutsideTheLockTwoAtATime() throws {
            let photos = SlowPhotos(FakePhotos([.photo("A1", "IMG_1001.HEIC")]))
            let agent = try Agent(photos: photos)
            _ = try PhotoIndexing.sync(photos, store: agent.library.store)
            var item: Int64?
            try agent.library.store.db.query("SELECT id FROM items WHERE path = 'photos:A1'") { item = $0.int(0) }
            let uri = "thumb/\(try #require(item))", server = agent.server
            // Two being drawn, as long as it takes.
            agent.service.thumbWait = 30
            let drawing = DispatchGroup()
            final class Count: @unchecked Sendable { var blobs = 0; let lock = NSLock() }
            let count = Count()
            for _ in 0..<2 {
                drawing.enter()
                onAnotherThread {
                    if Self.ask(server, uri, within: 60).blob { count.lock.withLock { count.blobs += 1 } }
                    drawing.leave()
                }
                #expect(photos.started.wait(timeout: .now() + 5) == .success)
            }
            // Meanwhile the rest is answered at once, and a third gets none rather than a wait.
            #expect(Self.ask(server, "summary", within: 5).answered)
            #expect(Self.ask(server, uri, within: 5) == (true, false))
            // They end with their pictures; their slots are free again.
            photos.go.signal()
            photos.go.signal()
            #expect(drawing.wait(timeout: .now() + 10) == .success)
            #expect(count.lock.withLock { count.blobs } == 2)
            // One that takes too long: none, and it keeps its slot until it ends.
            agent.service.thumbWait = 0.2
            #expect(Self.ask(server, uri, within: 5) == (true, false))
            #expect(photos.started.wait(timeout: .now() + 5) == .success)
            photos.go.signal()
            photos.go.signal()   // for the next
            agent.service.thumbWait = 30
            var drawn = false
            for _ in 0..<100 where !drawn {
                drawn = Self.ask(server, uri, within: 5).blob
                if !drawn { Thread.sleep(forTimeInterval: 0.05) }
            }
            #expect(drawn)
        }

        @Test func framesFormatsAndLimits() throws {
            let video = SearchService.Target(path: TestMedia.threePictures.path,
                                             kind: .video, location: nil)
            let frame = try #require(Thumbs.make(video, photos: nil).flatMap(Self.picture))
            #expect(max(frame.width, frame.height) <= Thumbs.pixels)
            // A video file AVFoundation can't open has none to ask for.
            func hit(_ path: String, _ kind: ItemKind) -> Hit {
                Hit(id: "7#t3.0", kind: kind, title: "", path: path, where: nil, date: "", snippet: nil, why: "",
                    score: 0, strong: true)
            }
            #expect(SearchService.thumbID(hit("/a/片段.mkv", .video)) == nil)
            #expect(SearchService.thumbID(hit("/a/片段.MOV", .video)) == "thumb/7")
            #expect(SearchService.thumbID(hit("/a/片段.mp4", .video)) == "thumb/7")
            // A PDF page drawn at its size, once; a locked one has none (it would draw blank).
            let scratch = try Scratch()
            let open = try scratch.write("合同.pdf", data: Drawn.pdf(textPage: ["合同"], scannedPage: ["签字"]))
            let page = try #require(Thumbs.make(.init(path: open.path, kind: .pdf, location: nil), photos: nil)
                .flatMap(Self.picture))
            #expect(page.height == Thumbs.pixels && page.width == 283)   // 595 × 842
            let locked = try scratch.write("锁.pdf", data: Drawn.pdf(textPage: ["合同"], scannedPage: ["签字"],
                                                                    password: "1234"))
            #expect(Thumbs.make(.init(path: locked.path, kind: .pdf, location: nil), photos: nil) == nil)
            // Noise is what JPEG does worst: still within the window's limit.
            let width = 800, height = 800
            var bytes = (0..<(width * height * 4)).map { _ in UInt8.random(in: 0...255) }
            let noise = bytes.withUnsafeMutableBytes { buffer in
                CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
            }
            let data = try #require(Thumbs.jpeg(noise))
            #expect(data.count <= Thumbs.maxBytes)
        }
    }
}
