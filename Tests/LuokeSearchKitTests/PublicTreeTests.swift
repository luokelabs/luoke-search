import Foundation
import Testing

// What would go out to the public repo names no one, no machine, no private repo, no key: the export's own scan
// (`scripts/public/export.sh --check`) on the working tree. Skipped where the script isn't: it stays private, so a
// tree without it is the public one.

struct PublicTreeTests {
    static let script = packageRoot.appendingPathComponent("scripts/public/export.sh").path

    /// Runs `tool` in `folder` (with `environment` added): its exit status and what it wrote, both streams.
    static func run(_ tool: String, _ arguments: [String], in folder: URL,
                    environment: [String: String] = [:]) throws -> (status: Int32, said: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let said = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, said)
    }

    @Test("nothing that would go public names a person, a machine, a private repo or a key",
          .enabled(if: FileManager.default.fileExists(atPath: script)))
    func nothingToKeepOut() throws {
        let check = try Self.run("/bin/sh", [Self.script, "--check"], in: packageRoot)
        #expect(check.status == 0, "\(check.said)")
    }

    @Test("what the scan can't read as written (a NUL, UTF-16, GBK) goes out only once looked at, and again once changed",
          .enabled(if: FileManager.default.fileExists(atPath: script)))
    func binariesLookedAt() throws {
        let files = FileManager.default
        let repo = files.temporaryDirectory.appendingPathComponent("public-tree-\(UUID().uuidString)")
        defer { try? files.removeItem(at: repo) }
        let scripts = repo.appendingPathComponent("scripts/public")
        try files.createDirectory(at: scripts, withIntermediateDirectories: true)
        for name in ["export.sh", "leaks.txt"] {
            try files.copyItem(at: packageRoot.appendingPathComponent("scripts/public/\(name)"),
                               to: scripts.appendingPathComponent(name))
        }
        #expect(try Self.run("/usr/bin/git", ["init", "-q"], in: repo).status == 0)
        // A word the scan looks for (read from its list, so this file names no one), where its greps can't see it.
        let leaks = try String(contentsOf: scripts.appendingPathComponent("leaks.txt"), encoding: .utf8)
        let word = try #require(leaks.split(separator: "\n").first { $0.allSatisfy { $0.isLetter && $0.isASCII } })
        func write(_ name: String, _ data: Data?) throws {
            try #require(data).write(to: repo.appendingPathComponent(name))
        }
        try write("notes.txt", "notes: \(word)\n".data(using: .utf16LittleEndian))
        try write("log.txt", Data("a\u{0}b \(word)\n".utf8))
        // Read, but not as the words are written: UTF-16 with no NUL in it (a BOM, then only CJK), and GBK.
        try write("wide.txt", Data([0xFF, 0xFE]) + "螺壳搜索".data(using: .utf16LittleEndian)!)
        try write("gbk.csv", Data([0xD6, 0xD0, 0xCE, 0xC4, 0x0A]))   // "中文"
        try write("plain.txt", Data("nothing here: 中文\n".utf8))
        try write("empty.txt", Data())
        func check(_ environment: [String: String] = [:]) throws -> (status: Int32, unseen: [String]) {
            let check = try Self.run("/bin/sh", ["scripts/public/export.sh", "--check"], in: repo,
                                     environment: environment)
            let prefix = "(binary, not looked at) "
            return (check.status, check.said.split(separator: "\n").filter { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)) })
        }

        #expect(try check().status == 2)   // no list: no scan, nothing taken as clean
        try write("scripts/public/binaries.txt", Data())
        let first = try check()
        #expect(first.status == 1)
        #expect(first.unseen.map { $0.split(separator: " ", maxSplits: 1)[1] }
                == ["gbk.csv", "log.txt", "notes.txt", "wide.txt"])

        try write("scripts/public/binaries.txt", Data(first.unseen.map { $0 + "\n" }.joined().utf8))
        let looked = try check()   // looked at: out they go; text and empty files are never listed
        #expect(looked.status == 0)
        #expect(looked.unseen.isEmpty)
        // Whoever runs it with git's colors always on: the file names it reads are plain all the same.
        let colored = try check(["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "color.ui", "GIT_CONFIG_VALUE_0": "always"])
        #expect(colored.status == 0)
        #expect(colored.unseen.isEmpty)

        try write("notes.txt", "notes: \(word), and more\n".data(using: .utf16LittleEndian))
        let changed = try check()
        #expect(changed.status == 1)
        let again = try #require(changed.unseen.first)
        #expect(changed.unseen.count == 1 && again.hasSuffix(" notes.txt"))
        #expect(!first.unseen.contains(again))   // its new blob, not the one looked at
    }

    static let tool = packageRoot.appendingPathComponent("tools/public_tree.py").path

    /// What export.sh keeps out: its `EXCLUDE="…"`, however many lines the quotes take.
    static func excludedBySh(_ text: String) throws -> [String] {
        let match = try #require(text.firstMatch(of: /(?m)^EXCLUDE="([^"]*)"/))
        return match.1.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// What tools/public_tree.py keeps out, as Python reads its `EXCLUDE` (not as a line of it looks).
    static func excludedByPy() throws -> [String] {
        let said = try run("/usr/bin/python3", ["-I", "-c", "import runpy, sys; print(*runpy.run_path(sys.argv[1])['EXCLUDE'], sep='\\n')",
                                                tool], in: packageRoot)
        try #require(said.status == 0, "\(said.said)")
        return said.said.split(separator: "\n").map(String.init)
    }

    @Test("luoke-core's public_sync, through tools/public_tree.py, keeps out what export.sh does and finds nothing here",
          .enabled(if: FileManager.default.fileExists(atPath: tool)))
    func publicSyncsTreeIsTheSame() throws {
        let sh = try Self.excludedBySh(String(contentsOfFile: Self.script, encoding: .utf8))
        let py = try Self.excludedByPy()
        #expect(sh == py)
        #expect(py.contains("tools") && py.contains("STATUS.md"))
        let check = try Self.run("/usr/bin/python3", ["-I", Self.tool, "--check", "--rev", "."], in: packageRoot)
        #expect(check.status == 0, "\(check.said)")
    }

    @Test("tools/public_tree.py finds what export.sh finds: a word, a key, a link, a binary not looked at",
          .enabled(if: FileManager.default.fileExists(atPath: tool)))
    func publicTreeFinds() throws {
        let files = FileManager.default
        let repo = files.temporaryDirectory.appendingPathComponent("public-tree-py-\(UUID().uuidString)")
        defer { try? files.removeItem(at: repo) }
        for folder in ["scripts/public", "tools", "Tests"] {
            try files.createDirectory(at: repo.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for name in ["scripts/public/leaks.txt", "tools/public_tree.py"] {
            try files.copyItem(at: packageRoot.appendingPathComponent(name), to: repo.appendingPathComponent(name))
        }
        #expect(try Self.run("/usr/bin/git", ["init", "-q"], in: repo).status == 0)
        let leaks = try String(contentsOf: repo.appendingPathComponent("scripts/public/leaks.txt"), encoding: .utf8)
        let word = try #require(leaks.split(separator: "\n").first { $0.allSatisfy { $0.isLetter && $0.isASCII } })
        let key = "ghp_" + String(repeating: "a1B2", count: 6)
        func write(_ name: String, _ data: Data?) throws {
            try #require(data).write(to: repo.appendingPathComponent(name))
        }
        try write("said.md", Data("asked \(word) first\n".utf8))
        try write("STATUS.md", Data("\(word) decided\n".utf8))            // kept out: not looked at
        try write("config.sh", Data("TOKEN=\(key)\n".utf8))
        try write("Tests/MaskTests.swift", Data("let made = \"\(key)\"\n".utf8))   // made-up keys in tests are fine
        try write("notes.txt", "notes\n".data(using: .utf16LittleEndian))
        try write("plain.txt", Data("nothing here: 中文\n".utf8))
        try files.createSymbolicLink(atPath: repo.appendingPathComponent("link").path, withDestinationPath: "/etc")
        func check() throws -> (status: Int32, hits: [String]) {
            let check = try Self.run("/usr/bin/python3", ["-I", "tools/public_tree.py", "--check", "--rev", "."], in: repo)
            return (check.status, check.said.split(separator: "\n").map(String.init).filter { $0.contains(":") && !$0.hasPrefix(".:") })
        }

        #expect(try check().status == 2)   // no list of what was looked at: no scan, nothing taken as clean
        try write("scripts/public/binaries.txt", Data())
        let first = try check()
        #expect(first.status == 1)
        #expect(first.hits.map { String($0.prefix { $0 != ":" }) } == ["config.sh", "link", "notes.txt", "said.md"])
        let unseen = try #require(first.hits.first { $0.hasPrefix("notes.txt:0: (binary, not looked at) ") })
        let blob = unseen.dropFirst("notes.txt:0: (binary, not looked at) ".count).prefix(40)
        #expect(try Self.run("/usr/bin/git", ["hash-object", "--no-filters", "notes.txt"], in: repo).said.hasPrefix(blob))
        try write("scripts/public/binaries.txt", Data("\(blob) notes.txt\n".utf8))
        #expect(try check().hits.map { String($0.prefix { $0 != ":" }) } == ["config.sh", "link", "said.md"])
    }

    @Test("loaded the way public_sync loads it (from a commit), tools/public_tree.py reads its lists from that commit",
          .enabled(if: FileManager.default.fileExists(atPath: tool)))
    func publicTreeReadsTheCommit() throws {
        let files = FileManager.default
        let repo = files.temporaryDirectory.appendingPathComponent("public-tree-rev-\(UUID().uuidString)")
        defer { try? files.removeItem(at: repo) }
        for folder in ["scripts/public", "tools"] {
            try files.createDirectory(at: repo.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for name in ["scripts/public/leaks.txt", "tools/public_tree.py"] {
            try files.copyItem(at: packageRoot.appendingPathComponent(name), to: repo.appendingPathComponent(name))
        }
        func write(_ name: String, _ data: Data?) throws {
            try #require(data).write(to: repo.appendingPathComponent(name))
        }
        func git(_ arguments: String...) throws -> String {
            let said = try Self.run("/usr/bin/git", ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
                                                      "-c", "core.hooksPath=/dev/null"] + arguments, in: repo)
            try #require(said.status == 0, "\(said.said)")
            return said.said
        }
        _ = try git("init", "-q")
        try write("notes.txt", "notes\n".data(using: .utf16LittleEndian))
        let blob = try git("hash-object", "--no-filters", "notes.txt").prefix(40)
        try write("scripts/public/binaries.txt", Data("\(blob) notes.txt\n".utf8))
        _ = try git("add", "-A")
        _ = try git("commit", "-q", "-m", "lists")
        // The checkout's list now says nothing was looked at; the commit's still lists notes.txt.
        try write("scripts/public/binaries.txt", Data())
        // As public_sync's repo_public_tree does: the commit's file, compiled under "<rev>:tools/public_tree.py".
        let load = """
            import subprocess, sys, types
            repo, rev, path = sys.argv[1], sys.argv[2], "tools/public_tree.py"
            m = types.ModuleType("public_tree_of_rev")
            m.__file__ = repo + "/" + path
            source = subprocess.run(["git", "-C", repo, "show", f"{rev}:{path}"], capture_output=True, check=True).stdout.decode()
            exec(compile(source, f"{rev}:{path}", "exec"), m.__dict__)
            hits, _ = m.check(m.public(m.tree(rev)))
            print(*[h[0] for h in hits], sep="\\n")
            """
        let fromCommit = try Self.run("/usr/bin/python3", ["-I", "-c", load, repo.path, "HEAD"], in: repo)
        #expect(fromCommit.status == 0, "\(fromCommit.said)")
        #expect(fromCommit.said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(fromCommit.said)")
        // Run on its own, it reads the checkout: notes.txt isn't looked at there.
        let fromCheckout = try Self.run("/usr/bin/python3", ["-I", "tools/public_tree.py", "--check", "--rev", "HEAD"], in: repo)
        #expect(fromCheckout.status == 1)
        #expect(fromCheckout.said.contains("notes.txt:0: (binary, not looked at) \(blob)"))
    }

    @Test("in the private tree the agent's own checker is there: what uses it isn't skipped",
          .enabled(if: FileManager.default.fileExists(atPath: script)))
    func theAgentsCheckerIsHere() {
        #expect(agentScripts != nil)
    }
}
