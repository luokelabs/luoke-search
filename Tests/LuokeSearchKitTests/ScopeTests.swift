import Foundation
import Testing
@testable import LuokeSearchKit

// 11-10: the whole home folder and iCloud Drive by default, what of it isn't the user's left out, the usual places read
// first, the protected ones inside reported, disks searched only when tapped, and folders in the home folder skipped
// on the page. Synthetic folders in scratch homes only.
extension ReadsPictures {
    struct ScopeTests {
        typealias Window = WindowTests
        typealias Page = PageFoldersTests

        /// A scratch home with something in each place the rules talk about.
        static func home(_ scratch: Scratch) throws -> String {
            for (path, text) in [
                ("Desktop/会议纪要.txt", "周三下午三点开会"),
                ("Documents/Music/乐理笔记.txt", "五线谱的读法"),
                ("Documents/go/围棋.txt", "定式和布局"),
                ("工作资料/报价.md", "团队版每人每月 18 元"),
                ("Music/歌词.txt", "曲库里的歌词"),
                ("Music/Library/song.mp3", "not really"),
                ("miniconda3/pkgs/readme.txt", "conda docs"),
                ("anaconda3/readme.txt", "conda docs"),
                ("Applications/某个工具/说明.txt", "tool docs"),
                ("go/pkg/readme.md", "go docs"),
                ("opt/share/readme.txt", "unix tree"),
                ("Parallels/readme.txt", "vm docs"),
                ("Documents/Windows.vmwarevm/notes.txt", "vm docs"),
                ("Library/Preferences/notes.txt", "settings"),
                ("Library/CloudStorage/Dropbox/云盘.txt", "Dropbox 里的"),
                ("Library/Mobile Documents/com~apple~CloudDocs/云笔记.txt", "iCloud 云盘里的笔记"),
                ("Library/Mobile Documents/com~apple~Pages/Documents/方案.txt", "Pages 的文稿"),
            ] {
                try scratch.write("home/" + path, text)
            }
            return Crawler.canonical(scratch.path + "/home")
        }

        @Test("The home folder and iCloud Drive by name, as the app's activation writes them")
        func theDefaultPlacesByName() throws {
            let scratch = try Scratch()
            let home = try Self.home(scratch)
            #expect(Settings.folder(named: "home", home: home) == home)
            #expect(Settings.folder(named: "个人文件夹", home: home) == home)
            #expect(Settings.folder(named: "icloud", home: home) == home + "/Library/Mobile Documents")
            #expect(Settings.folder(named: "iCloud 云盘", home: home) == home + "/Library/Mobile Documents")
            #expect(Settings.homeScope(home: home) == [home, home + "/Library/Mobile Documents"])
            // Both are places the app as it ships searches; other cloud storage isn't.
            #expect(Settings.homeScope(home: home).allSatisfy { Settings.searchable($0, home: home) })
            #expect(!Settings.searchable(home + "/Library/CloudStorage/Dropbox", home: home))
            // Written as luoke's activation writes them (absolute paths, iCloud Drive's own folder): named the same.
            let service = try SearchService(directory: DataDirectory(url: scratch.url.appendingPathComponent("data")),
                                            hub: nil, opener: Opened().opener, home: scratch.path + "/home")
            #expect(service.quietName(home) == "个人文件夹")
            #expect(service.quietName(home + "/Library/Mobile Documents") == "iCloud 云盘")
            #expect(service.quietName(home + "/Library/Mobile Documents/com~apple~CloudDocs") == "iCloud 云盘")
            #expect(Settings.searchable(home + "/Library/Mobile Documents/com~apple~CloudDocs", home: home))
        }

        @Test("A walk of the home folder leaves out Music, tools' folders and virtual machines; iCloud Drive is its own")
        func whatTheHomeWalkLeavesOut() throws {
            let scratch = try Scratch()
            let home = try Self.home(scratch)
            let walk = Crawler(home: home).walk(Settings.homeScope(home: home))
            let found = Set(walk.files.map { String($0.path.dropFirst(home.count + 1)) })
            #expect(found == [
                "Desktop/会议纪要.txt", "Documents/Music/乐理笔记.txt", "Documents/go/围棋.txt", "工作资料/报价.md",
                "Library/Mobile Documents/com~apple~CloudDocs/云笔记.txt",
                "Library/Mobile Documents/com~apple~Pages/Documents/方案.txt",
            ])
            #expect(walk.skipped["~/Music"] == 1)
            #expect(walk.skipped["tool folder"] == 6)
            #expect((walk.skipped["virtual machine"] ?? 0) + (walk.skipped["package"] ?? 0) >= 1)
            // Chosen itself, the Music folder is searched.
            let music = Crawler(home: home).walk([home + "/Music"])
            #expect(music.files.map { ($0.path as NSString).lastPathComponent }.contains("歌词.txt"))
        }

        @Test("What changes later under the home folder follows the same rules")
        func changesFollowTheRules() throws {
            let scratch = try Scratch()
            let home = try Self.home(scratch)
            let changed = Crawler(home: home).walk([home + "/Music/歌词.txt", home + "/go/pkg/readme.md",
                                                    home + "/Desktop/会议纪要.txt"], under: home)
            #expect(changed.files.map(\.path) == [home + "/Desktop/会议纪要.txt"])
        }

        @Test("The desktop, documents, downloads and what changed lately are read before the rest")
        func theUsualPlacesFirst() throws {
            let scratch = try Scratch()
            let home = Crawler.canonical(scratch.path + "/home")
            let old = Date(timeIntervalSince1970: 1_600_000_000)
            for path in ["Pictures/旧的.txt", "Desktop/旧的.txt", "Pictures/新的.txt", "50%_off/旧的.txt", "Documents/旧的.txt"] {
                try scratch.write("home/" + path, "一段话")
                if path.contains("旧") {
                    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: home + "/" + path)
                }
            }
            let store = try scratch.store()
            _ = try Indexer(store: store, crawler: Crawler(home: home)).sync([home])
            let first = Indexer.usualFirst(home: home)
            let order = try store.pending(limit: 10, first: first).map { String($0.path.dropFirst(home.count + 1)) }
            #expect(Set(order.prefix(3)) == ["Desktop/旧的.txt", "Documents/旧的.txt", "Pictures/新的.txt"])
            #expect(Set(order.suffix(2)) == ["Pictures/旧的.txt", "50%_off/旧的.txt"])
            // Without it, newest first, as before.
            #expect(try store.pending(limit: 10).first.map { $0.path.hasSuffix("新的.txt") } == true)
        }

        @Test("The protected places inside a searched home folder are reported too, unless skipped")
        func protectedPlacesInside() throws {
            let home = "/Users/someone"
            #expect(SearchService.accessTargets([home], skipped: [], home: home)
                    == [home, home + "/Desktop", home + "/Documents", home + "/Downloads"])
            #expect(SearchService.accessTargets([home, home + "/Desktop"], skipped: [home + "/Documents"], home: home)
                    == [home, home + "/Desktop", home + "/Downloads"])
            #expect(SearchService.accessTargets([home + "/工作"], skipped: [], home: home) == [home + "/工作"])
        }

        @Test("A desktop macOS doesn't let it read gets its needs-access card, by the name the user knows")
        func theDesktopNotAllowed() throws {
            let setup = try SetupHome()
            try setup.scratch.write("home/Desktop/a.txt", "一段话")
            setup.service.folderAccess = FolderAccess(patience: 30, read: { !$0.hasSuffix("/Desktop") })
            var settings = Settings()
            settings.folders = Settings.homeScope(home: setup.home)
            try settings.save(setup.directory)
            let access = setup.items.filter { $0["kind"] as? String == "needs-access" }
            #expect(access.map { $0["title"] as? String } == ["螺壳搜索读不了「桌面」"])
        }

        @Test("Nothing chosen yet: the setup card offers the home folder and iCloud Drive, and its 好 chooses them")
        func setupOffersTheHomeFolder() throws {
            let setup = try SetupHome()
            try FileManager.default.createDirectory(atPath: setup.home + "/Library/Mobile Documents",
                                                    withIntermediateDirectories: true)
            let item = try #require(setup.setup)
            #expect((item["summary"] as? String)?.contains("「个人文件夹」和「iCloud 云盘」") == true)
            let result = setup.tap(try setup.planID(item))
            #expect(SetupHome.code(result) == nil)
            #expect(Settings.load(setup.directory).folders == Settings.homeScope(home: setup.home))
            #expect(setup.setup == nil)
        }

        @Test("Disks: searched where they're mounted by their UUID, kept while unplugged, not another disk at their place")
        func disksByUUID() throws {
            let chosen = [ChosenVolume(uuid: "U1", path: "/Volumes/备份")]
            #expect(Volumes.roots(chosen, mounted: []) == ["/Volumes/备份"])
            #expect(Volumes.roots(chosen, mounted: [MountedVolume(uuid: "U1", path: "/Volumes/备份 1", name: "备份")])
                    == ["/Volumes/备份 1"])
            #expect(Volumes.roots(chosen, mounted: [MountedVolume(uuid: "U2", path: "/Volumes/备份", name: "备份")]).isEmpty)
            var settings = Settings()
            settings.folders = ["/Users/someone"]
            settings.volumes = chosen
            let elsewhere = [MountedVolume(uuid: "U1", path: "/Volumes/备份 1", name: "备份")]
            #expect(settings.searched(restricted: true, home: "/Users/someone", mounted: elsewhere)
                    == ["/Users/someone", "/Volumes/备份 1"])
            #expect(settings.keptRoots(mounted: elsewhere) == ["/Users/someone", "/Volumes/备份", "/Volumes/备份 1"])
            #expect(Volumes.isOffered("/Volumes/备份") && !Volumes.isOffered("/Volumes/备份/里面"))
            #expect(!Volumes.isOffered("/Volumes/com.apple.TimeMachine.localsnapshots") && !Volumes.isOffered("/private/var"))
        }

        @Test("A disk plugged in is offered on the page; 也搜这块盘 searches it, 不搜了 takes it and its files out")
        func aDiskOnThePage() throws {
            let (agent, _, _) = try Page.agent()
            let disk = agent.library.scratch.path + "/volume"
            try agent.library.scratch.write("volume/盘上的笔记.txt", "外接盘上的笔记")
            agent.service.mountedVolumes = { [MountedVolume(uuid: "U1", path: disk, name: "备份盘")] }
            let page = try Window.read(agent, "page/overview")
            #expect(Window.pageTexts(page).contains("备份盘"))
            // The UUID hashed, as a folder's path is: nothing on the page names the device.
            #expect(Page.buttons(page, "也搜这块盘").map { ($0["context"] as? [String: String])?["disk"] }
                    == [SearchService.diskID("U1")])
            #expect(!(try Page.json(page)).contains("U1"))
            let tapped = agent.call("search_settings_apply", ["disk": SearchService.diskID("U1")],
                                    tapped: SearchService.overviewPage)
            #expect(Window.code(tapped) == nil)
            #expect(Settings.load(agent.directory).volumes == [ChosenVolume(uuid: "U1", path: disk)])
            // Searched now: its line has 不搜了, and it isn't offered again.
            let after = try Window.read(agent, "page/overview")
            #expect(Page.buttons(after, "也搜这块盘").isEmpty)
            #expect(Page.buttons(after, "不搜了").contains { ($0["context"] as? [String: String])?["folder"] == SearchService.folderID(disk) })
            _ = try agent.library.indexer.sync([disk])
            #expect(try agent.library.store.item(path: disk + "/盘上的笔记.txt") != nil)
            let off = Page.tap(agent, disk)
            #expect(Window.code(off) == nil && Window.text(off).contains("这块盘"))
            #expect(Settings.load(agent.directory).volumes.isEmpty)
            #expect(try agent.library.store.item(path: disk + "/盘上的笔记.txt") == nil)
            // One not plugged in can't be added; only a tap on the page counts.
            #expect(Window.code(agent.call("search_settings_apply", ["disk": SearchService.diskID("U9")],
                                           tapped: SearchService.overviewPage)) == "invalid")
            #expect(Window.code(agent.call("search_settings_apply", ["disk": SearchService.diskID("U1")],
                                           tapped: "s-plan-x")) == "needs_user_action")
        }

        @Test("A disk's place taken by what isn't that disk (a share, an image, a folder): told by the volume's UUID")
        func aDiskPlaceTaken() throws {
            let chosen = [ChosenVolume(uuid: "U1", path: "/Volumes/备份")]
            #expect(Volumes.roots(chosen, mounted: [], occupied: { _, _ in true }).isEmpty)
            #expect(Volumes.roots(chosen, mounted: [], occupied: { _, _ in false }) == ["/Volumes/备份"])
            // Mounted where it was, by its UUID, wins over whatever is asked of the path.
            #expect(Volumes.roots(chosen, mounted: [MountedVolume(uuid: "U1", path: "/Volumes/备份", name: "备份")],
                                  occupied: { _, _ in true }) == ["/Volumes/备份"])
            // The real check: nothing there isn't another; a folder on this Mac's own volume is, unless that's the one.
            let scratch = try Scratch()
            let here = try #require(try scratch.url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
            #expect(!Volumes.holdsAnother(scratch.path + "/没有这个", "U1"))
            #expect(Volumes.holdsAnother(scratch.path, "U1"))
            #expect(!Volumes.holdsAnother(scratch.path, here))
            // The mount table, asked without waiting on any file system: this Mac's own volume is local; a folder
            // isn't a mount point.
            let root = try #require(Volumes.mountFlags(at: "/"))
            #expect(root & UInt32(MNT_LOCAL) != 0)
            #expect(Volumes.mountFlags(at: scratch.path) == nil)
        }

        @Test("A chosen disk whose place something else took: not searched, its line says 没接上, 不搜了 takes it out")
        func aDiskPlaceTakenOnThePage() throws {
            let (agent, _, _) = try Page.agent()
            let place = agent.library.scratch.path + "/备份"
            try agent.library.scratch.write("备份/别的盘上的.txt", "不是那块盘")
            var settings = Settings.load(agent.directory)
            settings.volumes = [ChosenVolume(uuid: "U1", path: place)]
            try settings.save(agent.directory)
            agent.service.mountedVolumes = { [] }
            #expect(!Settings.load(agent.directory).searched(restricted: false, mounted: []).contains(place))
            #expect(Window.pageTexts(try Window.read(agent, "page/overview")).contains("备份（没接上）"))
            let off = Page.tap(agent, place)
            #expect(Window.code(off) == nil && Window.text(off).contains("这块盘"))
            #expect(Settings.load(agent.directory).volumes.isEmpty)
        }

        @Test("A chosen disk that isn't plugged in says so on its line and keeps what was read of it")
        func aDiskUnplugged() throws {
            let (agent, notes, _) = try Page.agent()
            var settings = Settings.load(agent.directory)
            settings.volumes = [ChosenVolume(uuid: "U1", path: agent.library.scratch.path + "/gone")]
            try settings.save(agent.directory)
            agent.service.mountedVolumes = { [] }
            #expect(Window.pageTexts(try Window.read(agent, "page/overview")).contains("gone（没接上）"))
            _ = Page.tap(agent, notes)   // another folder taken out: a prune, which keeps the disk's place
            #expect(Settings.load(agent.directory).volumes.count == 1)
        }

        @Test("The home folder's own folders can be skipped on the page, and searched again")
        func skipAndUnskip() throws {
            let agent = try Agent()
            let home = agent.library.scratch.path
            for path in ["Desktop/a.txt", "工作资料/b.txt", "Music/c.txt", ".config/d.txt", "miniconda3/e.txt"] {
                try agent.library.scratch.write(path, "一段话")
            }
            try Window.choose(agent, home)
            let page = try Window.read(agent, "page/overview")
            let texts = Window.pageTexts(page)
            #expect(texts.contains("个人文件夹里") && texts.contains("桌面") && texts.contains("工作资料"))
            #expect(!texts.contains("Music") && !texts.contains(".config") && !texts.contains("miniconda3"))
            // The usual places first.
            let skips = Page.buttons(page, "跳过").compactMap { ($0["context"] as? [String: String])?["skip"] }
            let work = SearchService.folderID(Crawler.canonical(home) + "/工作资料")
            #expect(skips.first == SearchService.folderID(Crawler.canonical(home) + "/Desktop") && skips.contains(work))
            let skipped = agent.call("search_settings_apply", ["skip": work], tapped: SearchService.overviewPage)
            #expect(Window.code(skipped) == nil && Window.text(skipped).contains("工作资料"))
            #expect(Settings.load(agent.directory).skipFolders == [Crawler.canonical(home) + "/工作资料"])
            let after = try Window.read(agent, "page/overview")
            #expect(!Page.buttons(after, "跳过").contains { ($0["context"] as? [String: String])?["skip"] == work })
            #expect(Page.buttons(after, "不跳过了").map { ($0["context"] as? [String: String])?["unskip"] } == [work])
            let again = agent.call("search_settings_apply", ["unskip": work], tapped: SearchService.overviewPage)
            #expect(Window.code(again) == nil)
            #expect(Settings.load(agent.directory).skipFolders.isEmpty)
            // Two at once, or not on the page: refused.
            #expect(Window.code(agent.call("search_settings_apply", ["skip": work, "photos": true],
                                           tapped: SearchService.overviewPage)) == "invalid")
            #expect(Window.code(agent.call("search_settings_apply", ["skip": work])) == "needs_user_action")
        }

        @Test("Without the home folder searched, the page has no 跳过; a full page stays within a card's 200 components")
        func pageLimits() throws {
            let agent = try Agent()
            let home = agent.library.scratch.path
            for index in 0..<30 { try agent.library.scratch.write("文件夹\(index)/a.txt", "一段话") }
            try Window.choose(agent, home + "/文件夹0")
            #expect(Page.buttons(try Window.read(agent, "page/overview"), "跳过").isEmpty)
            try Window.choose(agent, home)
            var settings = Settings.load(agent.directory)
            settings.skipFolders = (20..<30).map { Crawler.canonical(home) + "/文件夹\($0)" }
            settings.folders += (0..<25).map { home + "/文件夹\($0)/a" }
            try settings.save(agent.directory)
            agent.service.mountedVolumes = { (0..<5).map { MountedVolume(uuid: "U\($0)", path: "/Volumes/盘\($0)", name: "盘\($0)") } }
            let page = try Window.read(agent, "page/overview")
            let components = ((page as? [[String: Any]]) ?? []).flatMap {
                (($0["updateComponents"] as? [String: Any])?["components"] as? [[String: Any]]) ?? []
            }
            #expect(components.count <= 200)
            #expect(Page.buttons(page, "跳过").count == Cards.maxInHomeShown)
            #expect(Page.buttons(page, "不跳过了").count == Cards.maxSkippedShown)
            #expect(Page.buttons(page, "也搜这块盘").count == Cards.maxDisksShown)
        }
    
        @Test("The watcher ignores what a walk wouldn't go into: ~/Library's churn, Music, tools; not iCloud Drive")
        func theWatcherFollowsTheRules() throws {
            let home = "/Users/someone", iCloud = home + "/Library/Mobile Documents"
            let ignored = Resident.ignored(skipping: [home + "/旧项目"], roots: [home, iCloud], home: home)
            for path in [home + "/Library/Caches/com.example/x", home + "/Library", home + "/Music/a.mp3",
                         home + "/miniconda3/pkgs/a.txt", home + "/旧项目/a.txt", home + "/Documents/Win.vmwarevm/a.txt"] {
                #expect(ignored(path), "\(path)")
            }
            for path in [home + "/Desktop/a.txt", iCloud + "/com~apple~CloudDocs/a.txt", home + "/Documents/Music/a.txt"] {
                #expect(!ignored(path), "\(path)")
            }
            #expect(FolderWatcher.innermost(iCloud + "/a/b.txt", [home, iCloud]) == iCloud)
        }

        @Test("iCloud Drive not readable inside a readable home folder keeps what was read of it, whole walk or changes")
        func iCloudUnreadableKeepsItsItems() throws {
            let scratch = try Scratch()
            let home = try Self.home(scratch)
            let store = try scratch.store()
            let indexer = Indexer(store: store, crawler: Crawler(home: home))
            let roots = Settings.homeScope(home: home)
            _ = try indexer.sync(roots)
            let note = home + "/Library/Mobile Documents/com~apple~CloudDocs/云笔记.txt"
            #expect(try store.item(path: note) != nil)
            chmod(roots[1], 0o000)
            defer { chmod(roots[1], 0o755) }
            let report = try indexer.sync(roots)
            #expect(report.removed == 0 && report.unreachable == [roots[1]])
            #expect(try store.item(path: note) != nil)
            _ = try indexer.sync(roots, changed: [home, note])
            #expect(try store.item(path: note) != nil)
            #expect(try store.item(path: home + "/Desktop/会议纪要.txt") != nil)
        }

        @Test("A needs-access item for the desktop keeps its id when the settings change otherwise")
        func accessItemsStay() throws {
            let setup = try SetupHome()
            setup.service.folderAccess = FolderAccess(patience: 30, read: { !$0.hasSuffix("/Desktop") })
            var settings = Settings()
            settings.folders = [setup.homeFolder]
            try settings.save(setup.directory)
            let before = setup.items.filter { $0["kind"] as? String == "needs-access" }.compactMap { $0["id"] as? String }
            #expect(before.count == 1)
            var change = SearchService.Change()
            change.onBattery = true
            _ = try setup.service.apply(planID: try setup.service.plan(change).0.id, surfaceID: nil)
            #expect(setup.items.filter { $0["kind"] as? String == "needs-access" }.compactMap { $0["id"] as? String } == before)
        }

        @Test("The home folder chosen with its desktop not allowed: chosen all the same, the desktop reported")
        func homeChosenDesktopRefused() throws {
            let setup = try SetupHome()
            chmod(setup.home + "/Desktop", 0o000)
            defer { chmod(setup.home + "/Desktop", 0o755) }
            let result = setup.tap(try setup.planID(setup.setup))
            #expect(SetupHome.code(result) == nil)
            #expect(Settings.load(setup.directory).folders == [setup.homeFolder])
        }

        @Test("A disk mounted at another path is followed there; the old path is let go")
        func aDiskThatMoved() throws {
            let scratch = try Scratch()
            let directory = DataDirectory(url: scratch.url.appendingPathComponent("data"))
            var settings = Settings()
            settings.volumes = [ChosenVolume(uuid: "U1", path: "/Volumes/备份")]
            try settings.save(directory)
            #expect(try !Settings.followDisks(directory, mounted: []))
            #expect(try Settings.followDisks(directory, mounted: [MountedVolume(uuid: "U1", path: "/Volumes/备份 1", name: "备份")]))
            let moved = Settings.load(directory)
            #expect(moved.volumes == [ChosenVolume(uuid: "U1", path: "/Volumes/备份 1")])
            #expect(moved.keptRoots(mounted: []) == ["/Volumes/备份 1"])
        }

        @Test("A disk is taken out by its path in the conversation; a folder chosen on its own isn't offered to skip")
        func diskByPathAndOwnRoots() throws {
            let (agent, _, _) = try Page.agent()
            let disk = agent.library.scratch.path + "/volume"
            try agent.library.scratch.write("volume/a.txt", "一段话")
            agent.service.mountedVolumes = { [MountedVolume(uuid: "U1", path: disk, name: "备份盘")] }
            var change = SearchService.Change()
            change.addVolumes = ["U1"]
            _ = try agent.service.apply(planID: try agent.service.plan(change).0.id, surfaceID: nil)
            var off = SearchService.Change()
            off.removeFolders = [disk]
            let (plan, _) = try agent.service.plan(off)
            #expect(plan.removeVolumes == ["U1"] && plan.removeFolders.isEmpty)
            // The home folder and its desktop both chosen (an earlier version's): the desktop has 不搜了, not 跳过.
            let home = agent.library.scratch.path
            try agent.library.scratch.write("Desktop/a.txt", "一段话")
            try Window.choose(agent, home)
            try Window.choose(agent, home + "/Desktop")
            let page = try Window.read(agent, "page/overview")
            let desktop = SearchService.folderID(Crawler.canonical(home) + "/Desktop")
            #expect(!Page.buttons(page, "跳过").contains { ($0["context"] as? [String: String])?["skip"] == desktop })
        }
}
}
