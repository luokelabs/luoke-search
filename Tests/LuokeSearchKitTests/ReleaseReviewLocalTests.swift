import Foundation
import Testing
@testable import LuokeSearchKit

// The pre-release security review (10-23), should-fix 8, 9 and 12: what another process of the same user could
// have luoke-search do with the folders and Photos library macOS lets it read. The app as it ships takes no
// development switch; a plan takes only folders worth searching; a file is read only if it's still the one listed.
struct ReleaseReviewSwitchTests {
    @Test("Should-fix 8: what counts as the app as it ships; a development build of it doesn't")
    func whoIsShipped() {
        #expect(CommandArguments.shipped(app: true, command: "serve", flags: [], developmentApp: false))
        #expect(CommandArguments.shipped(app: true, command: "index", flags: ["--job"], developmentApp: false))
        #expect(CommandArguments.shipped(app: true, command: "settings", flags: [], developmentApp: false))
        #expect(CommandArguments.shipped(app: false, command: "serve", flags: ["--resident"], developmentApp: false))
        #expect(!CommandArguments.shipped(app: false, command: "serve", flags: ["--no-watch"], developmentApp: false))
        #expect(!CommandArguments.shipped(app: false, command: "index", flags: ["--resident"], developmentApp: false))
        #expect(!CommandArguments.shipped(app: true, command: "serve", flags: ["--resident"], developmentApp: true))
    }

    @Test("Should-fix 8: what the app as it ships won't run: another data directory or home, development commands")
    func refusals() throws {
        func refusal(_ arguments: [String], _ command: String?, _ environment: [String: String] = [:]) throws -> String? {
            try CommandArguments(ArraySlice(arguments)).shippedRefusal(command: command, environment: environment)
        }
        #expect(try refusal(["--resident"], "serve") == nil)
        #expect(try refusal(["--job"], "index") == nil)
        #expect(try refusal([], "status", ["LUOKE_HUB_SOCKET": "/x.sock", "LUOKE_SEARCH_OPENER": "dry"]) == nil)
        #expect(try refusal(["--index", "/x"], "serve")?.contains("--index") == true)
        #expect(try refusal(["--socket=/y.sock"], "serve")?.contains("--socket") == true)
        #expect(try refusal([], "serve", ["LUOKE_SEARCH_HOME": "/z"])?.contains("LUOKE_SEARCH_HOME") == true)
        #expect(try refusal([], "serve", ["CFFIXED_USER_HOME": "/z"])?.contains("CFFIXED_USER_HOME") == true)
        #expect(try refusal([], "serve", ["CFFIXED_USER_HOME": ""])?.contains("CFFIXED_USER_HOME") == true)
        for command in ["eval", "photos-probe", "probe-audio"] {   // settings: taken since 10-26 (SetupTests)
            #expect(try refusal([], command) != nil, "\(command)")
        }
        #expect(try refusal(["/home/someone/Documents"], "index") != nil)   // folders only from the settings
    }

    /// The built command line as luoke-core runs the service, with the environment given: its exit code and stderr.
    static func resident(_ extra: [String], environment: [String: String], in scratch: Scratch) throws -> (Int32, String) {
        let executable = try #require(BuiltCommand.url, "luoke-search isn't next to the test bundle")
        let err = scratch.url.appendingPathComponent("serve-\(UUID().uuidString.prefix(6)).err")
        FileManager.default.createFile(atPath: err.path, contents: nil)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--resident", "--no-watch"] + extra
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": scratch.path, "TMPDIR": NSTemporaryDirectory()]
            .merging(environment) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: err)
        try process.run()
        #expect(eventually(30) { !process.isRunning })
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return (process.terminationStatus, (try? String(contentsOf: err, encoding: .utf8)) ?? "")
    }

    @Test("Should-fix 8: the app's code outside its bundle (through a link) is still the app; this test process isn't")
    func appCodeOutsideItsBundle() throws {
        #expect(!LuokeSearch.isApp)
        let scratch = try Scratch()
        let built = try #require(BuiltCommand.url, "luoke-search isn't next to the test bundle")
        let copy = scratch.url.appendingPathComponent("luoke-search")
        try FileManager.default.copyItem(at: built, to: copy)
        // Signed as the app's executable is (codesign names it by the bundle id), outside any bundle.
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--identifier", LuokeSearch.bundleID, copy.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        try #require(sign.terminationStatus == 0)
        // Only runs that stop before any data directory is opened; and were one not to, an empty CFFIXED_USER_HOME
        // makes the home folder the working directory, this scratch folder, not the real one.
        for (arguments, switches) in [(["serve", "--no-watch", "--index", scratch.path + "/given"], "--index、CFFIXED_USER_HOME"),
                                      (["status"], "CFFIXED_USER_HOME")] {
            let process = Process()
            process.executableURL = copy
            process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": scratch.path, "TMPDIR": NSTemporaryDirectory(),
                                   "CFFIXED_USER_HOME": ""]
            process.currentDirectoryURL = scratch.url
            let err = scratch.url.appendingPathComponent("copy-\(arguments[0]).err")
            FileManager.default.createFile(atPath: err.path, contents: nil)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = try FileHandle(forWritingTo: err)
            try process.run()
            #expect(eventually(30) { !process.isRunning })
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            let said = (try? String(contentsOf: err, encoding: .utf8)) ?? ""
            #expect(process.terminationStatus == 1 && said.contains("发布版不认开发用的 \(switches)"), "\(arguments): \(said)")
        }
        #expect(!FileManager.default.fileExists(atPath: scratch.path + "/given"))
        #expect(!FileManager.default.fileExists(atPath: scratch.path + "/.luoke-search"))
    }

    @Test("Should-fix 8: serve --resident refuses another data directory, and drops the other development variables")
    func residentTakesNone() throws {
        let scratch = try Scratch()
        let socket = "/tmp/lsres-\(UUID().uuidString.prefix(6)).sock"
        let (given, saidGiven) = try Self.resident(["--index", scratch.path + "/given", "--socket", socket],
                                                   environment: [:], in: scratch)
        #expect(given == 1 && saidGiven.contains("发布版不认开发用的 --index、--socket"), "\(saidGiven)")
        let (home, saidHome) = try Self.resident([], environment: ["LUOKE_SEARCH_HOME": scratch.path + "/from-env",
                                                                   "CFFIXED_USER_HOME": scratch.path + "/fake-home"], in: scratch)
        #expect(home == 1 && saidHome.contains("LUOKE_SEARCH_HOME、CFFIXED_USER_HOME"), "\(saidHome)")
        // The others are dropped; then, not started by 螺壳 (no channel on descriptor 3, `FromApp`), it stops before
        // opening any data directory.
        let (rest, saidRest) = try Self.resident([], environment: ["LUOKE_HUB_SOCKET": scratch.path + "/hub.sock",
                                                                   "LUOKE_SEARCH_OPENER": "dry"], in: scratch)
        #expect(rest == FromApp.refusedExitCode, "\(saidRest)")
        #expect(saidRest.contains("发布版不认开发用的 LUOKE_HUB_SOCKET、LUOKE_SEARCH_OPENER，已忽略"), "\(saidRest)")
        #expect(saidRest.contains("不是螺壳起的"), "\(saidRest)")
        // luoke-core's jobs set LUOKE_HUB_SOCKET to its own socket: nothing to say about that one.
        let (_, saidHub) = try Self.resident([], environment: ["LUOKE_HUB_SOCKET": Hub.installedSocket], in: scratch)
        #expect(!saidHub.contains("LUOKE_HUB_SOCKET"), "\(saidHub)")
        for made in ["given", "from-env", "fake-home"] {
            #expect(!FileManager.default.fileExists(atPath: scratch.path + "/" + made), "\(made)")
        }
        #expect(!FileManager.default.fileExists(atPath: socket))
    }
}

struct ReleaseReviewFolderTests {
    @Test("Should-fix 9: which folders may be searched")
    func searchable() throws {
        let scratch = try Scratch()
        let home = scratch.path + "/home"
        for folder in ["notes/.git", ".ssh", "Library/Messages/Attachments", "Library/Mobile Documents/com~apple~CloudDocs/工作"] {
            try FileManager.default.createDirectory(atPath: home + "/" + folder, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(atPath: home + "/etc-link", withDestinationPath: "/etc")
        try FileManager.default.createSymbolicLink(atPath: home + "/notes-link", withDestinationPath: home + "/notes")
        let yes = [home, home + "/notes", home + "/Library/Mobile Documents/com~apple~CloudDocs/工作", home + "/notes-link",
                   home + "/没有这个", "/Volumes/备份盘/照片"]
        let no = [home + "/.ssh", home + "/notes/.git", home + "/Library", home + "/Library/Messages/Attachments",
                  home + "/Library/Application Support", home + "/etc-link", home + "/notes/../../other", "/", "/etc",
                  "/System/Library", "/Users/someone-else", "/Volumes", "/Volumes/备份盘/.Trashes", scratch.path,
                  "/Volumes/com.apple.TimeMachine.localsnapshots/Backups.backupdb/x", "/Volumes/备份盘/Backups.backupdb/mac"]
        for folder in yes { #expect(Settings.searchable(folder, home: home), "\(folder)") }
        for folder in no { #expect(!Settings.searchable(folder, home: home), "\(folder)") }
        // The home folder has Desktop and Documents in it: its files aren't counted for the card (macOS would ask).
        #expect(SearchService.isProtected(home, home: home))
        #expect(!SearchService.isProtected(home + "/notes", home: home))
    }

}

extension ReleaseReviewFolderTests {

    @Test("Should-fix 9: walks judge the folders again: one swapped for a link, one written into settings.json by hand")
    func walksJudgeAgain() throws {
        let scratch = try Scratch()
        let home = scratch.path + "/home"
        try scratch.write("home/notes/a.txt", "一")
        try scratch.write("home/Library/Messages/Attachments/b.txt", "二")
        var settings = Settings()
        settings.folders = [home + "/notes", home + "/Library/Messages/Attachments"]
        #expect(settings.searched(restricted: true, home: home) == [home + "/notes"])
        #expect(settings.searched(restricted: false, home: home) == settings.folders)
        // Allowed when it was chosen, a link into ~/Library since.
        try FileManager.default.removeItem(atPath: home + "/notes")
        try FileManager.default.createSymbolicLink(atPath: home + "/notes", withDestinationPath: home + "/Library/Messages")
        #expect(settings.searched(restricted: true, home: home).isEmpty)
    }
}

extension ReadsPictures {
    struct ReleaseReviewListedTests {
        @Test("Should-fix 9: a plan refuses a folder outside them, hidden or not there alike; one made before is stale")
        func plans() throws {
            let agent = try Agent()
            agent.service.restrictFolders = true   // the app as it ships
            let home = agent.library.scratch.path
            try FileManager.default.createDirectory(atPath: home + "/.secret", withIntermediateDirectories: true)
            var answers: [String] = []
            for folder in [home + "/.secret", home + "/.not-there", "/etc", "/没有这个", home + "/Library/Messages"] {
                let answer = agent.call("search_settings", ["change": ["add_folders": [folder]]])
                #expect((answer["structuredContent"] as? [String: Any])?["code"] as? String == "invalid", "\(folder)")
                answers.append(((answer["content"] as? [[String: Any]])?.first?["text"] as? String ?? "")
                    .replacingOccurrences(of: folder, with: "…"))
            }
            // The same answer whether it's there or not: a plan doesn't tell what exists outside.
            #expect(Set(answers.prefix(2)).count == 1 && answers[0].contains("螺壳搜索不搜"))
            #expect(Set(answers.dropFirst(2).prefix(2)).count == 1)
            // A folder in it that isn't there is still said so.
            let missing = agent.call("search_settings", ["change": ["add_folders": [home + "/没有这个"]]])
            #expect(((missing["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("没有") == true)
            // A plan an earlier version made with a hidden folder in it isn't carried out.
            let proposed = agent.call("search_settings", ["change": ["photos": true]])
            let id = try #require((proposed["structuredContent"] as? [String: Any])?["plan_id"] as? String)
            try ToolState.update(agent.directory) { state in
                if let index = state.plans.firstIndex(where: { $0.id == id }) { state.plans[index].addFolders = [home + "/.secret"] }
            }
            let applied = agent.call("search_settings_apply", ["plan_id": id], tapped: "s-\(id)")
            #expect((applied["structuredContent"] as? [String: Any])?["code"] as? String == "stale")
            #expect(!Settings.load(agent.directory).folders.contains(home + "/.secret"))
        }

        @Test("Should-fix 9: development runs and tests take any folder (a checkout under ~/Library, .dev)")
        func developmentTakesAny() throws {
            let agent = try Agent()
            let hidden = agent.library.scratch.path + "/.dev/scale"
            try FileManager.default.createDirectory(atPath: hidden, withIntermediateDirectories: true)
            let answer = agent.call("search_settings", ["change": ["add_folders": [hidden]]])
            #expect((answer["structuredContent"] as? [String: Any])?["plan_id"] != nil)
        }

        @Test("Should-fix 9: the first pass of the app as it ships walks only searchable folders")
        func firstPassWalksOnlySearchable() throws {
            // The folders are in a scratch place, outside this account's home: not searchable when restricted.
            let library = try Library()
            let directory = DataDirectory(url: library.scratch.url.appendingPathComponent("data"))
            var settings = Settings.load(directory)
            settings.folders = [library.root]
            try settings.save(directory)
            var restricted = FirstPass(directory: directory, store: library.store, hub: nil)
            restricted.restrictFolders = true
            #expect(try restricted.run(limit: 0).sync.added == 0)
            let open = FirstPass(directory: directory, store: library.store, hub: nil)
            #expect(try open.run(limit: 0).sync.added > 0)
        }

        @Test("Should-fix 12: a file swapped for a link after it was listed isn't read through the link")
        func swappedForALink() throws {
            let library = try Library()
            try library.scratch.write("outside/secret.txt", "capybara 只在外面的文件里")
            let file = try library.scratch.write("files/notes/换了.txt", "原来的字")
            _ = try library.indexer.sync([library.root])
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: library.scratch.path + "/outside/secret.txt")
            try library.indexer.readPending()
            let item = try #require(try library.store.item(path: file.path))
            #expect(item.state == "failed")
            #expect(try Searcher(store: library.store).search("capybara").hits.isEmpty)
            // The next walk sees a link, not a file: the item goes.
            _ = try library.indexer.sync([library.root])
            #expect(try library.store.item(path: file.path) == nil)
        }

        @Test("Should-fix 12: listed means a regular file with the inode it had")
        func listed() throws {
            let scratch = try Scratch()
            let file = try scratch.write("a.txt", "一")
            var info = stat()
            lstat(file.path, &info)
            let inode = UInt64(info.st_ino)
            #expect(Indexer.isListed(file.path, inode: inode))
            #expect(Indexer.isListed(file.path, inode: 0))
            // Replaced by another file (a new inode), by a link, by a folder.
            try FileManager.default.removeItem(at: file)
            try scratch.write("b.txt", "keep b's inode in use")
            try scratch.write("a.txt", "二")
            #expect(!Indexer.isListed(file.path, inode: inode))
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: scratch.path + "/b.txt")
            #expect(!Indexer.isListed(file.path, inode: 0))
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            #expect(!Indexer.isListed(file.path, inode: 0))
            // A folder above it that's a link (the walk's paths have none): not followed either.
            let real = try scratch.write("real/c.txt", "三")
            try FileManager.default.createSymbolicLink(atPath: scratch.path + "/linked", withDestinationPath: scratch.path + "/real")
            #expect(Indexer.isListed(real.path, inode: 0))
            #expect(!Indexer.isListed(scratch.path + "/linked/c.txt", inode: 0))
        }

        @Test("Should-fix 12: a file put in another's place with the same size and date is read again, not left failed")
        func replacedSameSizeAndDate() throws {
            let library = try Library()
            let file = try library.scratch.write("files/notes/同步.txt", "原来的字 aaaa")
            _ = try library.indexer.sync([library.root])
            let item = try #require(try library.store.item(path: file.path))
            // Another file in its place, as rsync -a or a sync client leaves it: a new inode, the same size and date.
            let date = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
            let other = try library.scratch.write("files/notes/.tmp", "后来的字 bbbb")
            try FileManager.default.setAttributes([.modificationDate: date as Any], ofItemAtPath: other.path)
            _ = try FileManager.default.replaceItemAt(file, withItemAt: other)
            try library.indexer.readPending()
            #expect(try library.store.item(path: file.path)?.state == "failed")   // read as "not the file listed"
            let report = try library.indexer.sync([library.root])
            #expect(report.changed == 1)
            try library.indexer.readPending()
            #expect(try library.store.item(path: file.path)?.state == "done")
            #expect(try library.store.item(path: file.path)?.inode != item.inode)
            #expect(try Searcher(store: library.store).search("后来的字").hits.first?.title == "同步.txt")
        }

        @Test("Should-fix 12: pictures for vectors are made only from the file listed")
        func picturesFromTheFileListed() throws {
            let scratch = try Scratch()
            let shot = try scratch.write("Screenshot 2026-10-23 at 10.00.00.png",
                                         data: try Drawn.png(Drawn.picture(["截屏"], width: 800, height: 400)))
            var info = stat()
            lstat(shot.path, &info)
            let want = MediaInputs.Wanted(segment: 1, kind: .image, loc: nil, locEnd: nil)
            let task = HubTask(status: .available)
            guard case .made? = MediaInputs.Source(path: shot.path, kind: .screenshot, wanted: [want], task: task, photos: nil,
                                                   inode: UInt64(info.st_ino)).next() else {
                Issue.record("not made from the file listed")
                return
            }
            guard case .impossible(_, let why)? = MediaInputs.Source(path: shot.path, kind: .screenshot, wanted: [want],
                                                                     task: task, photos: nil, inode: UInt64(info.st_ino) + 1).next() else {
                Issue.record("made from another file")
                return
            }
            #expect(why == Indexer.notListed)
        }
    }
}
