import Foundation
import Testing
@testable import LuokeSearchKit

// Why what waits doesn't go on (11-02): `search_status` says so, from the rule the resident service itself goes by
// (`Resident.backlogHeld`, `vectorsHeld`): luoke-core's background state while it answers, else the Mac's own. The
// Mac's own is made up here (`machine`): the tests never depend on whether this Mac is plugged in.

/// The service on `texts`' index, asking `hub`, with one more file found and not read yet (`toRead`). The Mac holds
/// reading for `mac`, "battery" only while the settings don't let it read on battery (as `Power.held` does).
fileprivate func service(_ texts: Texts, hub: Hub?, toRead: Bool = true, mac: [String] = [],
                         photos: PhotoSource? = nil) throws -> SearchService {
    if toRead {
        try texts.scratch.write("files/new.md", "# 新笔记\n还没读。")
        _ = try Indexer(store: texts.store, crawler: Crawler(home: texts.scratch.path)).sync([texts.scratch.path + "/files"])
    }
    let service = try SearchService(directory: DataDirectory(url: texts.scratch.url.appendingPathComponent("data")),
                                    hub: hub, opener: Opened().opener, photos: photos, home: texts.scratch.path)
    service.machine = { onBattery in onBattery ? mac.filter { $0 != "battery" } : mac }
    return service
}

/// A socket nobody listens on: luoke-core isn't running.
fileprivate func nobodysHub() -> Hub {
    Hub(socket: "/tmp/lsph-nobody-\(UUID().uuidString.prefix(6)).sock", environment: [:])
}

struct PauseReasonTests {
    @Test("the resident's rule: luoke-core's reasons while it answers, else the Mac's; heat and Low Power Mode always")
    func heldAsTheResidentGoesBy() {
        let none: (Bool) -> [String] = { _ in [] }
        #expect(Resident.backlogHeld(("running", []), onBattery: false, held: none).isEmpty)
        #expect(Resident.backlogHeld(("paused", ["battery", "memory"]), onBattery: true, held: none) == ["battery", "memory"])
        // Paused with no reason given, or a state this version doesn't know: held all the same.
        #expect(Resident.backlogHeld(("paused", []), onBattery: false, held: none) == ["paused"])
        #expect(Resident.backlogHeld(("resting", []), onBattery: false, held: none) == ["resting"])
        // The Mac's own on top, once each; while luoke-core answers, battery is its to say.
        let hot: (Bool) -> [String] = { onBattery in onBattery ? ["thermal"] : ["battery", "thermal"] }
        #expect(Resident.backlogHeld(("running", []), onBattery: false, held: hot) == ["thermal"])
        #expect(Resident.backlogHeld(("paused", ["thermal"]), onBattery: false, held: hot) == ["thermal"])
        // No luoke-core: the Mac's, with the user's "on battery too".
        #expect(Resident.backlogHeld(nil, onBattery: false, held: hot) == ["battery", "thermal"])
        #expect(Resident.backlogHeld(nil, onBattery: true, held: hot) == ["thermal"])
        // Vectors: only luoke-core's pause.
        #expect(Resident.vectorsHeld(("paused", [])))
        #expect(!Resident.vectorsHeld(("running", [])))
        #expect(!Resident.vectorsHeld(nil))
    }

    @Test("luoke-core paused on battery: search_status says reading and vectors wait, and only luoke-core's why")
    func luokeCorePaused() throws {
        let texts = try Texts(1)
        texts.fake.background = ("paused", ["battery"])
        let service = try service(texts, hub: texts.hub, mac: ["thermal"])   // not luoke-core's to say: not said
        let before = texts.fake.tasksRequests
        let status = try service.status()
        #expect(texts.fake.tasksRequests == before + 1)   // the task's state and the background from one answer
        let paused = try #require(status["paused"] as? [String: Any])
        #expect(paused["reasons"] as? [String] == ["battery"])
        #expect(paused["by"] as? String == "luoke")
        #expect(paused["reading"] as? Bool == true)
        #expect(paused["vectors"] as? Bool == true)
        #expect(service.statusSentence(status) == "已索引 1 个，还有 1 个在等着读，1 段在等螺壳算向量。"
            + "因为螺壳的后台已暂停（在用电池），等着的文件先不读（新存的文件照样读，先只能按字词搜），向量先不算。")
        // As the agent gets it: the same, through the tool.
        let reply = AgentTools.server(service).handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
            "name": "search_status", "arguments": [String: Any](),
            "_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"],
        ] as [String: Any]])
        let result = try #require(reply?["result"] as? [String: Any])
        let said = try #require((result["structuredContent"] as? [String: Any])?["paused"] as? [String: Any])
        #expect(said["reasons"] as? [String] == ["battery"])
        #expect((result["content"] as? [[String: Any]])?.first?["text"] as? String == service.statusSentence(status))
    }

    @Test("nothing to read, vectors held: only they wait; every reason said, none it doesn't know, none made up")
    func onlyVectorsHeld() throws {
        let cases: [(reasons: [String], why: String)] = [
            (["memory"], "螺壳的后台已暂停（内存不够）"),
            (["battery", "thermal"], "螺壳的后台已暂停（在用电池、Mac 太热）"),
            (["low_power", "later"], "螺壳的后台已暂停（开着低电量模式）"),
            (["later"], "螺壳的后台已暂停"),
            ([], "螺壳的后台已暂停"),
        ]
        for (reasons, why) in cases {
            let texts = try Texts(1)
            texts.fake.background = ("paused", reasons)
            let service = try service(texts, hub: texts.hub, toRead: false)
            let status = try service.status()
            let paused = try #require(status["paused"] as? [String: Any])
            #expect(paused["reasons"] as? [String] == reasons)   // luoke-core's own: no state name in their place
            #expect(paused["reading"] as? Bool == false)
            #expect(paused["vectors"] as? Bool == true)
            #expect(service.statusSentence(status) == "已索引 1 个，1 段在等螺壳算向量。因为\(why)，向量先不算。", "\(reasons)")
        }
    }

    @Test("no luoke-core: the Mac's own reasons hold reading; on battery too in the settings, battery doesn't")
    func macsOwn() throws {
        let texts = try Texts(1)
        let service = try service(texts, hub: nil, mac: ["battery"])
        var status = try service.status()
        let paused = try #require(status["paused"] as? [String: Any])
        #expect(paused["reasons"] as? [String] == ["battery"])
        #expect(paused["by"] as? String == "mac")
        #expect(paused["reading"] as? Bool == true)
        #expect(paused["vectors"] as? Bool == false)   // with no luoke-core, none are filled anyway: the note says why
        // The cause a sentence of its own, after luoke-core's note: not read as why vectors wait.
        #expect(service.statusSentence(status) == "已索引 1 个，还有 1 个在等着读，1 段在等螺壳算向量，没有连螺壳。"
            + "因为在用电池，等着的文件先不读（新存的文件照样读）。")
        var settings = Settings.load(service.directory)
        settings.onBattery = true
        try settings.save(service.directory)
        status = try service.status()
        #expect(status["paused"] is NSNull)
        #expect(service.statusSentence(status) == "已索引 1 个，还有 1 个在等着读，1 段在等螺壳算向量，没有连螺壳。")
    }

    @Test("luoke-core not running, refusing /tasks, or too old to say: the Mac's own rule, as the resident falls back")
    func noAnswerFromLuokeCore() throws {
        let texts = try Texts(1)
        let away = try service(texts, hub: nobodysHub(), mac: ["battery"])
        let status = try away.status()
        #expect((status["paused"] as? [String: Any])?["by"] as? String == "mac")
        #expect(away.statusSentence(status) == "已索引 1 个，还有 1 个在等着读，1 段在等螺壳算向量，螺壳没有在运行。"
            + "因为在用电池，等着的文件先不读（新存的文件照样读）。")
        // An answer without `background` (a luoke-core from before it): the same rule; the task itself is ready.
        let old = try Texts(1)
        let older = try service(old, hub: old.hub, mac: ["battery"])
        let said = try older.status()
        #expect((said["paused"] as? [String: Any])?["reasons"] as? [String] == ["battery"])
        #expect((said["paused"] as? [String: Any])?["vectors"] as? Bool == false)
        // /tasks turned away (503): no background either.
        old.fake.refuseTasks(503, ["code": "busy", "message": "busy", "retry_after": 5])
        #expect((try older.status()["paused"] as? [String: Any])?["by"] as? String == "mac")
    }

    @Test("luoke-core running: Low Power Mode and heat still hold reading, not vectors")
    func runningButHot() throws {
        let texts = try Texts(1)
        texts.fake.background = ("running", [])
        let service = try service(texts, hub: texts.hub, mac: ["low_power", "thermal"])
        let status = try service.status()
        let paused = try #require(status["paused"] as? [String: Any])
        #expect(paused["by"] as? String == "mac")
        #expect(paused["vectors"] as? Bool == false)
        #expect(service.statusSentence(status) == "已索引 1 个，还有 1 个在等着读，1 段在等螺壳算向量。"
            + "因为开着低电量模式、Mac 太热，等着的文件先不读（新存的文件照样读）。")
    }

    @Test("vectors luoke-core wouldn't make now aren't held by its pause: a tier for text only, no such task")
    func vectorsItWouldNotMake() throws {
        let texts = try Texts(1)
        try texts.store.db.execute("UPDATE segments SET vec = zeroblob(4), todo = NULL")   // every text vector in
        var counts = IndexStore.Counts()
        counts.waitingForMedia = 1   // a screenshot's picture
        let paused: Hub.Background = ("paused", ["battery"])
        func said(_ task: HubTask?) -> Resident.Paused? {
            Resident.paused(texts.store, counts: counts, photos: false, task: task, background: paused,
                            onBattery: false, held: { _ in [] })
        }
        #expect(said(HubTask(status: .available)) == nil)   // text only: it waits for another tier, not the pause
        var pictures = HubTask(status: .available)
        pictures.imageBatch = 8
        #expect(said(pictures)?.vectors == true)
        counts.waitingForVectors = 1
        #expect(said(HubTask(status: .available))?.vectors == true)
        #expect(said(HubTask(status: .unsupported)) == nil)   // never made here at all
        #expect(said(nil) == nil)   // luoke-core lists no such task
    }

    @Test("only the rest of long files waiting: said, and held as the first pass is")
    func restOfLongFiles() throws {
        let texts = try Texts(1)
        var counts = IndexStore.Counts()
        counts.waitingForRest = 2
        let paused = try #require(Resident.paused(texts.store, counts: counts, photos: false, task: nil,
                                                  background: nil, onBattery: false, held: { _ in ["battery"] }))
        #expect(paused.reading)
        let service = try service(texts, hub: nil, toRead: false)
        #expect(service.statusSentence(["items": ["doc": 1], "waiting": ["rest_of_long_files": 2], "paused": [
            "reasons": ["battery"], "by": "mac", "reading": true, "vectors": false] as [String: Any]])
            == "已索引 1 个，2 个长文件还没读完。因为在用电池，等着的文件先不读（新存的文件照样读）。")
    }

    @Test("photos waiting while the library can't be read here: not held by any of this, so nothing said")
    func photosNotAtHand() throws {
        let texts = try Texts(1)
        let library = FakePhotos([.photo("p1", "IMG_0001.HEIC")])
        _ = try PhotoIndexing.sync(library, store: texts.store)
        var settings = Settings()
        settings.photos = true
        try settings.save(DataDirectory(url: texts.scratch.url.appendingPathComponent("data")))
        library.access = .denied
        let denied = try service(texts, hub: nil, toRead: false, mac: ["battery"], photos: library)
        var status = try denied.status()
        #expect((status["waiting"] as? [String: Int])?["read"] == 1)   // (counted, as before)
        #expect(status["paused"] is NSNull)
        // Allowed: they'd be read but for the battery.
        library.access = .allowed
        status = try denied.status()
        #expect((status["paused"] as? [String: Any])?["reading"] as? Bool == true)
    }

    @Test("the status command (built) says what's held and why, as search_status does; --json has it too")
    func commandLineSays() throws {
        let texts = try Texts(1)
        texts.fake.background = ("paused", ["memory"])
        _ = try service(texts, hub: texts.hub)   // one more file waiting to be read
        let data = texts.scratch.url.appendingPathComponent("data").path
        let status = try CommandRun(["status", "--index", data], in: texts.scratch, hub: texts.fake)
        defer { status.stop() }
        #expect(status.wait() == 0)
        #expect(status.stdout.contains("\n因为螺壳的后台已暂停（内存不够），等着的文件先不读（新存的文件照样读，先只能按字词搜），向量先不算。\n"))
        let json = try CommandRun(["status", "--index", data, "--json"], in: texts.scratch, hub: texts.fake)
        defer { json.stop() }
        #expect(json.wait() == 0)
        let output = try #require(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        let paused = try #require(output["paused"] as? [String: Any])
        #expect(paused["reasons"] as? [String] == ["memory"])
        #expect(paused["by"] as? String == "luoke")
        #expect(paused["reading"] as? Bool == true)
        #expect(paused["vectors"] as? Bool == true)
        #expect(texts.fake.tasksRequests == 2)   // one `GET /tasks` a run
    }

    @Test("nothing waiting held: nothing said, and luoke-core asked once")
    func nothingHeld() throws {
        let texts = try Texts(1)
        texts.fake.background = ("running", [])
        let busy = try service(texts, hub: texts.hub)
        #expect(try busy.status()["paused"] is NSNull)   // things wait, nothing holds them
        let done = try Texts(1)
        done.fake.background = ("paused", ["battery"])
        #expect(done.filler().run(wait: false).embedded == 1)   // every vector in (the fake fills them, paused or not)
        let service = try service(done, hub: done.hub, toRead: false, mac: ["battery"])
        let before = done.fake.tasksRequests
        let status = try service.status()
        #expect(status["paused"] is NSNull)
        #expect(done.fake.tasksRequests == before + 1)
        #expect(service.statusSentence(status) == "已索引 1 个。")
    }

    @Test("the resident service does as search_status says: held while luoke-core pauses, goes on once it runs")
    func residentDoesAsSaid() throws {
        let texts = try Texts(1)   // one note read, its vector waiting
        texts.fake.background = ("paused", ["battery"])
        for index in 0..<3 { try texts.scratch.write("files/later\(index).md", "# 后来的 \(index)\n还没读。") }
        let data = DataDirectory(url: texts.scratch.url.appendingPathComponent("data"))
        var settings = Settings()
        settings.folders = [texts.scratch.path + "/files"]
        try settings.save(data)
        let resident = try Resident(directory: data, hub: texts.hub)
        resident.machine = { _ in [] }
        resident.newFilesPerChange = 0   // none read as new: only the first pass would read them
        resident.backlogEvery = 0.2
        resident.vectorsEvery = 0.2
        resident.start()
        defer { resident.stop() }
        let service = try SearchService(directory: data, hub: texts.hub, opener: Opened().opener, home: texts.scratch.path)
        service.machine = { _ in [] }
        #expect(try eventually { try texts.store.counts().waitingToRead == 3 })   // walked at start
        let paused = try #require(try service.status()["paused"] as? [String: Any])
        #expect(paused["reading"] as? Bool == true)
        #expect(paused["vectors"] as? Bool == true)
        // A few ticks of both (each asks luoke-core), not a fixed wait a busy machine could sleep through.
        let asked = texts.fake.tasksRequests
        #expect(eventually { texts.fake.tasksRequests >= asked + 4 })
        #expect(try texts.store.counts().waitingToRead == 3)
        #expect(texts.fake.embedRequests.isEmpty)
        // Running: read and filled in, and nothing said any more.
        texts.fake.background = ("running", [])
        #expect(try eventually {
            let counts = try texts.store.counts()
            return counts.waitingToRead == 0 && counts.waitingForVectors == 0
        })
        #expect(!texts.fake.embedRequests.isEmpty)
        #expect(try service.status()["paused"] is NSNull)
    }
}
