import Darwin
import Foundation
import Testing
@testable import LuokeSearchKit

// The built command line itself, run as luoke-core would run it (10-22: coverage gap 4): `luoke-search index
// --job` in a process of its own, with a data directory in a scratch folder and no hub but the test's fake one.
// Synthetic files only. The watchdog stopping a run (exit code 75) can't be made to happen from here: its limits in
// the command line are the defaults (15 minutes, 4–8 GB), with no way to set them from outside. What a stopped run
// leaves for the next one is tested instead.

/// The `luoke-search` built with this test bundle, next to it (.build/out/Products/Debug with this toolchain,
/// .build/<triple>/debug with the older one): `swift test` and `swift build --build-tests` build every target, the
/// command line included. Only there: one found anywhere else could be older than the code under test.
enum BuiltCommand {
    static var url: URL? {
        let file = Bundle(for: Scratch.self).bundleURL.deletingLastPathComponent().appendingPathComponent("luoke-search")
        return FileManager.default.isExecutableFile(atPath: file.path) ? file : nil
    }
}

/// One run of the built `luoke-search`. Its environment is made here, not passed on: HOME is the scratch folder, and
/// nothing points at a real data directory, a real hub or the Photos library (`LUOKE_HUB_SOCKET` only for a fake hub).
/// What it writes goes to files in the scratch folder (a pipe left unread could fill and stall it).
final class CommandRun {
    let process = Process()
    private let out: URL
    private let err: URL

    init(_ arguments: [String], in scratch: Scratch, hub: FakeHub? = nil) throws {
        let executable = try #require(BuiltCommand.url, """
            luoke-search isn't next to the test bundle: build it with the tests (`swift test`, or `swift build \
            --build-tests` before `swift test --skip-build`)
            """)
        let name = UUID().uuidString.prefix(8)
        out = scratch.url.appendingPathComponent("run-\(name).out")
        err = scratch.url.appendingPathComponent("run-\(name).err")
        for file in [out, err] { FileManager.default.createFile(atPath: file.path, contents: nil) }
        var environment = ["PATH": "/usr/bin:/bin", "HOME": scratch.path, "TMPDIR": NSTemporaryDirectory(),
                           "LUOKE_SEARCH_OPENER": "dry"]
        if let hub { environment["LUOKE_HUB_SOCKET"] = hub.path }
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = scratch.url
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try FileHandle(forWritingTo: out)
        process.standardError = try FileHandle(forWritingTo: err)
        try process.run()
    }

    deinit { stop() }

    func signal(_ number: Int32) { kill(process.processIdentifier, number) }

    /// Waits for it to end by itself: its exit code, or nil when it ended on a signal or was still running after
    /// `seconds` (then it's killed).
    func wait(_ seconds: Double = 180) -> Int32? {
        guard eventually(seconds, { !process.isRunning }) else {
            stop()
            return nil
        }
        process.waitUntilExit()
        return process.terminationReason == .exit ? process.terminationStatus : nil
    }

    /// Killed if it's still running, and reaped.
    func stop() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }

    var stdout: String { (try? String(contentsOf: out, encoding: .utf8)) ?? "" }
    var stderr: String { (try? String(contentsOf: err, encoding: .utf8)) ?? "" }
}

/// What `index --job` says on stderr: one line of counts and status words (job() in main.swift). Nil for anything
/// else on stderr: a path, a name, a word from a file, another line. (The line ends in "; luoke-core: …" when the hub
/// turns vectors away; no run here is turned away, so that's anything else too.)
struct JobLine: Equatable {
    var read = 0
    var steps = 0
    var textVectors = 0
    var mediaVectors = 0
    var waitingToRead = 0
    var waitingForRest = 0
    var stopped = false

    init?(_ stderr: String) {
        let pattern = #/luoke-search job: read (\d+) \(and (\d+) steps of long files\), (\d+) text vectors, (\d+) picture and sound vectors; (\d+) waiting to read, (\d+) long files still being read(; stopped when asked)?\n/#
        guard let match = try? pattern.wholeMatch(in: stderr) else { return nil }
        read = Int(match.1)!
        steps = Int(match.2)!
        textVectors = Int(match.3)!
        mediaVectors = Int(match.4)!
        waitingToRead = Int(match.5)!
        waitingForRest = Int(match.6)!
        stopped = match.7 != nil
    }
}

/// A data directory in the scratch folder whose settings search `folder`, and its index as the test reads it (opened
/// before the job: WAL lets the test read while the job writes).
func jobData(_ scratch: Scratch, folder: String) throws -> (DataDirectory, IndexStore) {
    let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
    var settings = Settings()
    settings.folders = [folder]
    try settings.save(data)
    return (data, try IndexStore(directory: data, home: scratch.path))
}

/// Items read so far, whatever came of it.
func readSoFar(_ store: IndexStore) throws -> Int {
    let counts = try store.counts()
    return counts.items.values.reduce(0, +) + counts.failed + counts.skipped
}

/// In the serialized suite, one at a time: the runs read pictures (OCR) in processes of their own, and that load
/// mustn't come while another test times a read (the watchdog tests' limits are fractions of a second).
extension ReadsPictures {
    struct CommandLineTests {
        @Test("index --job: SIGTERM ends it after the file in hand, exit code 0; the next run reads the rest")
        func jobStopsOnSIGTERMAndGoesOn() throws {
            let scratch = try Scratch()
            // Screenshots are read with OCR: enough of them that the job is still reading when the signal comes.
            let total = 40
            for index in 0..<total {
                try scratch.write("files/Screenshot 2026-10-01 at 10.00.\(String(format: "%02d", index)).png",
                                  data: Drawn.png(Drawn.picture(["第 \(index) 张截图", "周三下午三点评审发布方案"])))
            }
            let (data, store) = try jobData(scratch, folder: scratch.path + "/files")
            let first = try CommandRun(["index", "--job", "--index", data.url.path], in: scratch)
            defer { first.stop() }
            // Stopped while reading: once something is stored, with most still waiting.
            try #require(try eventually(120) { try readSoFar(store) > 0 })
            first.signal(SIGTERM)
            #expect(first.wait(60) == 0)
            let counts = try store.counts()
            #expect(counts.waitingToRead > 0)   // it didn't just run to the end
            // The file in hand was finished: none of those still waiting was begun and left.
            #expect(try store.pending(limit: total).allSatisfy { $0.attempts == 0 })
            #expect(ToolState.load(data).firstPassDone == nil)
            let stopped = try #require(JobLine(first.stderr), "stderr: \(first.stderr)")
            #expect(stopped.stopped)
            #expect(stopped.read == counts.items["screenshot"])   // each one it read is stored
            #expect(stopped.waitingToRead == counts.waitingToRead)

            let second = try CommandRun(["index", "--job", "--index", data.url.path], in: scratch)
            defer { second.stop() }
            #expect(second.wait() == 0)
            let rest = try #require(JobLine(second.stderr), "stderr: \(second.stderr)")
            #expect(!rest.stopped)
            #expect(stopped.read + rest.read == total)   // nothing read twice, nothing left
            #expect(rest.waitingToRead == 0)
            #expect(try store.counts().items["screenshot"] == total)
            #expect(try store.counts().waitingToRead == 0)
            #expect(ToolState.load(data).firstPassDone != nil)   // the first pass is done
        }

        @Test("index --job: stderr has counts and status words only, never a path, a name or what's in a file")
        func jobWritesNoPathsOrContent() throws {
            let scratch = try Scratch()
            let hub = try FakeHub()
            defer { hub.stop() }
            hub.takesMedia = true
            // Words found only inside the files: a note, a long text read in steps, a screenshot's OCR.
            let (noteWord, longWord, pictureWord) = ("蓝鳍金枪鱼", "鸭嘴兽", "KESTREL")
            try scratch.write("files/鲸落计划/海獭备忘.md", "# 备忘\n这份备忘提到了\(noteWord)。")
            try scratch.write("files/鲸落计划/长笔记.txt", Drawn.longText(special: longWord))
            try scratch.write("files/Screenshot 2026-10-02 at 09.30.00.png",
                              data: Drawn.png(Drawn.picture(["\(pictureWord) 4471"])))
            let (data, store) = try jobData(scratch, folder: scratch.path + "/files")
            let job = try CommandRun(["index", "--job", "--index", data.url.path], in: scratch, hub: hub)
            defer { job.stop() }
            #expect(job.wait() == 0)
            let stderr = job.stderr
            // The scratch folder by its own name: a path may be spelled /var/… or /private/var/….
            for word in [noteWord, longWord, pictureWord, "鲸落计划", "海獭备忘", "长笔记", "Screenshot",
                         scratch.url.lastPathComponent, hub.path] {
                #expect(!stderr.contains(word), "\(word)")
            }
            #expect(!stderr.contains("/"))
            #expect(job.stdout.isEmpty)
            let line = try #require(JobLine(stderr), "stderr: \(stderr)")
            #expect(line.read == 3 && line.steps > 0 && !line.stopped)
            #expect(line.textVectors > 0 && line.mediaVectors > 0)
            #expect(line.waitingToRead == 0 && line.waitingForRest == 0)
            // They were read: the words are in the index (so their absence above means something).
            let searcher = Searcher(store: store)
            #expect(try searcher.search(noteWord).hits.first?.title == "海獭备忘.md")
            #expect(try searcher.search(longWord).hits.first?.title == "长笔记.txt")
            #expect(try searcher.search(pictureWord).hits.first?.kind == .screenshot)
            #expect(!hub.embedRequests.isEmpty)
        }

        @Test("index --job: the file a stopped run was reading (run/stopped-file.json) is marked unreadable, the note removed")
        func jobNotesTheStoppedFile() throws {
            let scratch = try Scratch()
            let stuck = try scratch.write("files/卡住.md", "# 卡住\n读它会卡住。")
            let fine = try scratch.write("files/好的.md", "# 好的\n这份读得完。")
            let (data, store) = try jobData(scratch, folder: scratch.path + "/files")
            // The run before: walked the folder, began 卡住.md, and its watchdog wrote the file down as it stopped the
            // process (exit code 75). The watchdog's limits can't be set from outside, so this is written here.
            _ = try Indexer(store: store, crawler: Crawler(home: scratch.path)).sync([scratch.path + "/files"])
            let item = try #require(try store.item(path: stuck.path))
            try store.startReading(item.id)
            let why = "reading it took more than 15 minutes"
            let note = ReadWatchdog.location(data)
            try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ReadWatchdog.Stopped(path: item.path, why: why, mtime: item.mtime, size: item.size))
                .write(to: note)

            let job = try CommandRun(["index", "--job", "--index", data.url.path], in: scratch)
            defer { job.stop() }
            #expect(job.wait() == 0)
            #expect(!FileManager.default.fileExists(atPath: note.path))
            #expect(try store.item(path: stuck.path)?.state == "failed")
            var detail: String?
            try store.db.query("SELECT detail FROM items WHERE path = ?", [.text(stuck.path)]) { detail = $0.text(0) }
            #expect(detail == why)
            #expect(try store.item(path: fine.path)?.state == "done")
            let line = try #require(JobLine(job.stderr), "stderr: \(job.stderr)")
            #expect(line.read == 1)   // 好的.md only: the stuck one isn't read again
            #expect(!job.stderr.contains("卡住"))
            // Still marked on the next run, until the file changes.
            let again = try CommandRun(["index", "--job", "--index", data.url.path], in: scratch)
            defer { again.stop() }
            #expect(again.wait() == 0)
            #expect(try store.item(path: stuck.path)?.state == "failed")
            #expect(JobLine(again.stderr)?.read == 0)
        }
    }
}
