import Foundation
import SQLite3
import Testing
@testable import LuokeSearchKit

// The index file itself (coverage, 10-22): which versions open and how, and two connections writing it at once, as
// the resident loop, a job and the command line do. Temporary files only.
struct IndexVersionTests {
    @Test("An index made by a newer luoke-search isn't opened")
    func newer() throws {
        let scratch = try Scratch()
        let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        _ = try IndexStore(directory: data, home: scratch.path)
        try Database(path: data.indexFile.path).execute("PRAGMA user_version = \(IndexStore.schemaVersion + 1)")
        #expect {
            try IndexStore(directory: data, home: scratch.path)
        } throws: { error in
            "\(error)".contains("newer luoke-search") && "\(error)".contains("schema \(IndexStore.schemaVersion + 1)")
        }
    }

    @Test("A schema 1 index (development builds only) is dropped and made again")
    func schemaOne() throws {
        let scratch = try Scratch()
        let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        try data.prepare()
        let old = try Database(path: data.indexFile.path)
        try old.execute("""
            CREATE TABLE items(id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE);
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO items(path) VALUES('/x/old.md');
            PRAGMA user_version = 1;
            """)
        let store = try IndexStore(directory: data, home: scratch.path)
        #expect(try store.db.scalarInt("PRAGMA user_version") == IndexStore.schemaVersion)
        #expect(try store.db.scalarInt("SELECT count(*) FROM items") == 0)   // what was there is gone
        #expect(try store.counts().items.isEmpty)                             // and the tables are this version's
        withExtendedLifetime(old) {}
    }

    @Test("An index at this version is opened as it is")
    func current() throws {
        let scratch = try Scratch()
        try scratch.write("files/a.md", "# 甲\n内容。")
        let data = DataDirectory(url: scratch.url.appendingPathComponent("data"))
        let first = try IndexStore(directory: data, home: scratch.path)
        _ = try Indexer(store: first, crawler: Crawler(home: scratch.path)).sync([scratch.path + "/files"])
        let again = try IndexStore(directory: data, home: scratch.path)
        #expect(try again.db.scalarInt("PRAGMA user_version") == IndexStore.schemaVersion)
        #expect(try again.item(path: scratch.path + "/files/a.md") != nil)
    }
}

/// Something handed to another thread in a test: used from one thread at a time.
final class Handed<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

struct TwoWritersTests {
    @Test("A write waits while another connection holds the write lock, then goes in")
    func waitsForTheLock() throws {
        let scratch = try Scratch()
        let path = scratch.path + "/two.sqlite"
        let first = Handed(try Database(path: path)), second = try Database(path: path)
        try first.value.execute("CREATE TABLE t(v INTEGER)")
        let holding = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? first.value.transaction {
                try first.value.execute("INSERT INTO t VALUES(1)")
                holding.signal()
                Thread.sleep(forTimeInterval: 0.3)   // the other one's write waits meanwhile
            }
            holding.signal()                         // in case it never got that far: the test doesn't hang
            done.signal()
        }
        #expect(holding.wait(timeout: .now() + 10) == .success)
        // It got the lock only once the other committed: the other's row is already there inside it.
        var before: Int64 = -1
        try second.transaction {
            before = try second.scalarInt("SELECT count(*) FROM t")
            try second.execute("INSERT INTO t VALUES(2)")
        }
        #expect(before == 1)
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(try second.scalarInt("SELECT count(*) FROM t") == 2)
    }

    @Test("A transaction that fails leaves nothing behind")
    func rollsBack() throws {
        let scratch = try Scratch()
        let db = try Database(path: scratch.path + "/roll.sqlite")
        try db.execute("CREATE TABLE t(v INTEGER)")
        struct Stop: Error {}
        #expect(throws: Stop.self) {
            try db.transaction {
                try db.execute("INSERT INTO t VALUES(1)")
                throw Stop()
            }
        }
        #expect(try db.scalarInt("SELECT count(*) FROM t") == 0)
        try db.transaction { try db.execute("INSERT INTO t VALUES(2)") }   // and the next one works
        #expect(try db.scalarInt("SELECT count(*) FROM t") == 1)
    }

    @Test("Opening a file another connection holds locked waits (SQLite's busy wait) until it can switch it to WAL")
    func opensWhileLocked() throws {
        let scratch = try Scratch()
        let path = scratch.path + "/locked.sqlite"
        // Another connection (as SQLite's locks go, as if another process's), before WAL: an exclusive lock.
        var handle: OpaquePointer?
        try #require(sqlite3_open(path, &handle) == SQLITE_OK)
        let other = Handed(handle)
        let committed = DispatchSemaphore(value: 0)
        defer {
            _ = committed.wait(timeout: .now() + 10)   // never closed while the commit below may still run
            sqlite3_close(other.value)
        }
        try #require(sqlite3_exec(other.value, "CREATE TABLE t(v INTEGER); BEGIN EXCLUSIVE; INSERT INTO t VALUES(1);",
                                  nil, nil, nil) == SQLITE_OK)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            sqlite3_exec(other.value, "COMMIT", nil, nil, nil)
            committed.signal()
        }
        let started = Date()
        let db = try Database(path: path)
        #expect(Date().timeIntervalSince(started) >= 0.2)
        var mode = ""
        try db.query("PRAGMA journal_mode") { mode = $0.text(0) ?? "" }
        #expect(mode == "wal")
        #expect(try db.scalarInt("SELECT count(*) FROM t") == 1)
    }
}
