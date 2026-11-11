import Foundation
import Testing
@testable import LuokeSearchKit

/// `Opener.finderReveal`: `open -R` with the path as one argument, from any thread, and an honest answer
/// (luoke-search#99: from the resident's socket thread, `activateFileViewerSelecting` did nothing and said nothing).
struct FinderRevealTests {
    /// A stand-in for `/usr/bin/open` that writes its arguments, each ended by a NUL, then exits with `status`.
    private func standIn(status: Int32, sleep: Bool = false) throws -> (program: String, log: URL, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reveal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("args")
        let program = folder.appendingPathComponent("open")
        let script = "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\0' \"$a\"; done > '\(log.path)'\n"
            + (sleep ? "sleep 5\n" : "") + "exit \(status)\n"
        try script.write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
        return (program.path, log, folder)
    }

    @Test func revealsWithOpenDashRAndThePathWhole() throws {
        let (program, log, folder) = try standIn(status: 0)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = "/tmp/带 空格 的 文件夹/-合同\n草稿（第二版）.txt"
        // On a thread of its own, as the resident's socket calls it.
        var shown = false
        let thread = Thread { shown = Opener.finderReveal(path, executable: program) }
        let done = DispatchSemaphore(value: 0)
        let watcher = Thread { while !thread.isFinished { Thread.sleep(forTimeInterval: 0.01) }; done.signal() }
        thread.start()
        watcher.start()
        done.wait()
        #expect(shown)
        #expect(try Data(contentsOf: log) == Data("-R\0\(path)\0".utf8))
    }

    @Test func notShownIsFalse() throws {
        let (program, _, folder) = try standIn(status: 1)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!Opener.finderReveal("/tmp/x", executable: program))
        // A program that can't be started.
        #expect(!Opener.finderReveal("/tmp/x", executable: "/nonexistent/open"))
        // The real one, on a file that isn't there: `open` exits 1 and shows nothing. A reveal that answers true
        // whatever happened (as `activateFileViewerSelecting` did) fails here.
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("gone-\(UUID().uuidString).txt")
        #expect(!Opener.mac.reveal(missing.path))
    }

    @Test func stuckIsFalseWithinTheWait() throws {
        let (program, _, folder) = try standIn(status: 0, sleep: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let started = Date()
        #expect(!Opener.finderReveal("/tmp/x", executable: program, wait: 0.5))
        #expect(Date().timeIntervalSince(started) < 3)
    }
}
