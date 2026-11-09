import Darwin
import Foundation
import Testing
@testable import LuokeSearchKit

// luoke-search as the program inside 螺壳.app (Contents/Helpers, scripts/build_helper.sh), started by 螺壳 as a child.
// The built command line in a process of its own, on a data directory in a scratch folder: no real data, no hub.
struct HelperTests {
    /// Stands in for 螺壳: a process to end while the service watches it.
    private func standIn() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["600"]
        try process.run()
        return process
    }

    /// A socket's path has to be short: the scratch folder's is too long for one.
    private func shortSocket() -> String { "/tmp/ls-\(UUID().uuidString.prefix(8)).sock" }

    private func serve(_ scratch: Scratch, socket: String, parent: pid_t? = nil) throws -> CommandRun {
        var arguments = ["serve", "--index", scratch.url.appendingPathComponent("data").path, "--socket", socket, "--no-watch"]
        if let parent { arguments += ["--parent-pid", String(parent)] }
        return try CommandRun(arguments, in: scratch)
    }

    @Test("What's linked into the program has no bundle id: Bundle.main would name it and `holder` would say 螺壳搜索")
    func linkedPlistHasNoBundleID() throws {
        let script = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../scripts/build_helper.sh"), encoding: .utf8)
        let plist = try #require(script.range(of: "<<PLIST")?.upperBound)
        let end = try #require(script.range(of: "\nPLIST\n")?.lowerBound)
        #expect(script[plist..<end].contains("CFBundleShortVersionString"))
        #expect(!script[plist..<end].contains("CFBundleIdentifier"))
        #expect(LuokeSearch.holder(bundle: nil, signing: LuokeSearch.bundleID) == "螺壳")
    }

    @Test("build_helper.sh stops without one version in Hub.swift: an empty one, or two, would pass its own check",
          arguments: ["", "public static let version = \"0.1.0\"\n// public static let version = \"0.2.0\"\n"])
    func buildStopsWithoutAVersion(version: String) throws {
        let scratch = try Scratch()
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../scripts/build_helper.sh")
        try scratch.write("scripts/build_helper.sh", data: Data(contentsOf: script))
        try scratch.write("Sources/LuokeSearchKit/Hub/Hub.swift", "public static let bundleID = \"ai.luoke.search\"\n" + version)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scratch.path + "/scripts/build_helper.sh"]
        process.environment = ["LUOKE_OUT": scratch.path + "/out", "PATH": "/usr/bin:/bin"]
        let said = Pipe()
        process.standardError = said
        try process.run()
        let text = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 1)
        #expect(text.contains("no bundle id or version in Hub.swift"))
    }

    @Test("serve --parent-pid: that process killed, the service quits as on SIGTERM and its socket is gone")
    func endsWithItsParent() throws {
        let scratch = try Scratch()
        let parent = try standIn()
        defer { if parent.isRunning { parent.terminate() } }
        let socket = shortSocket()
        let run = try serve(scratch, socket: socket, parent: parent.processIdentifier)
        #expect(eventually(30) { FileManager.default.fileExists(atPath: socket) })
        kill(parent.processIdentifier, SIGKILL)
        #expect(run.wait(30) == 0)
        #expect(!FileManager.default.fileExists(atPath: socket))
    }

    @Test("serve --parent-pid: a process already gone ends it as soon as it starts")
    func parentAlreadyGone() throws {
        let scratch = try Scratch()
        let parent = try standIn()
        kill(parent.processIdentifier, SIGKILL)
        parent.waitUntilExit()
        let socket = shortSocket()
        let run = try serve(scratch, socket: socket, parent: parent.processIdentifier)
        #expect(run.wait(30) == 0)
        #expect(!FileManager.default.fileExists(atPath: socket))
    }

    @Test("serve --parent-pid: a quit held up by the item in hand ends within 15 s, whichever way it was asked for")
    func quitHasALimit() throws {
        let scratch = try Scratch()
        let hub = try FakeHub()
        defer { hub.stop() }
        hub.delay = 60   // the item in hand: a request for vectors the hub takes longer than that over
        let folder = scratch.url.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "一份合成的笔记".write(to: folder.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let data = scratch.url.appendingPathComponent("data").path
        let chosen = try CommandRun(["settings", "--index", data, "--add-folder", folder.path, "--on-battery", "on"], in: scratch)
        #expect(chosen.wait(30) == 0)
        let parent = try standIn()
        defer { if parent.isRunning { parent.terminate() } }
        let run = try CommandRun(["serve", "--index", data, "--socket", shortSocket(),
                                  "--parent-pid", String(parent.processIdentifier)], in: scratch, hub: hub)
        #expect(eventually(60) { !hub.embedRequests.isEmpty })
        // By SIGTERM, with the parent still there: it may go next, and news of that comes in on the queue this quit holds.
        run.signal(SIGTERM)
        #expect(run.wait(30) == 0)
    }

    @Test("A second serve on the same socket exits 3, not 1: 螺壳 tells that from a failure; the first keeps serving")
    func secondOneExitsThree() throws {
        let scratch = try Scratch()
        let socket = shortSocket()
        let first = try serve(scratch, socket: socket)
        #expect(eventually(30) { FileManager.default.fileExists(atPath: socket) })
        let second = try serve(scratch, socket: socket)
        #expect(second.wait(30) == AgentSocket.alreadyServingExitCode)
        #expect(second.stderr.contains("already serving"))
        #expect(first.process.isRunning)
        first.signal(SIGTERM)
        #expect(first.wait(30) == 0)
    }

    @Test("--parent-pid takes a process number, and the app as it ships takes it too")
    func parentOption() throws {
        func parsed(_ arguments: [String]) throws -> CommandArguments { try CommandArguments(ArraySlice(arguments)) }
        #expect(try parsed(["--parent-pid", "4242"]).parentPID() == 4242)
        #expect(try parsed([]).parentPID() == nil)
        for bad in ["x", "1", "0", "-3"] {
            #expect(throws: CommandArguments.Failure.self) { try parsed(["--parent-pid=\(bad)"]).parentPID() }
        }
        #expect(try parsed(["--resident", "--parent-pid", "4242"]).shippedRefusal(command: "serve", environment: [:]) == nil)
    }

    @Test("Who holds the permissions: 螺壳 for the program inside it, the app's own name for 螺壳搜索.app and a development run")
    func holderName() {
        let id = LuokeSearch.bundleID
        #expect(LuokeSearch.holder(bundle: nil, signing: id) == "螺壳")
        #expect(LuokeSearch.holder(bundle: id, signing: id) == "螺壳搜索")
        #expect(LuokeSearch.holder(bundle: nil, signing: "luoke-search-1a2b") == "螺壳搜索")
        #expect(LuokeSearch.holder(bundle: nil, signing: nil) == "螺壳搜索")
    }
}
