import Foundation
import Testing
@testable import LuokeSearchKit

/// A file kept with its name percent-encoded (what some downloaders keep of a URL) is found by its name as results
/// show it, and sure when all the words are in it, as any other name (#113).
struct DecodedNamesTests {
    // 发票清单.txt in a folder 财务.
    static let folder = "%E8%B4%A2%E5%8A%A1"
    static let file = "%E5%8F%91%E7%A5%A8%E6%B8%85%E5%8D%95.txt"

    static func library(_ scratch: Scratch) throws -> (IndexStore, Indexer) {
        try scratch.write("files/\(folder)/\(file)", "第三季度的报销记录：住宿和交通。")
        try scratch.write("files/普通的发票.txt", "另一张发票。")
        let store = try scratch.store()
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        _ = try indexer.sync([scratch.path + "/files"])
        try indexer.readPending()
        return (store, indexer)
    }

    @Test func theNameAsShownIsSearchedAndSure() throws {
        let scratch = try Scratch()
        let (store, _) = try Self.library(scratch)
        let hits = try Searcher(store: store).search("清单").hits
        #expect(hits.map(\.title) == ["发票清单.txt"])
        #expect(hits.first?.strong == true)
        // Its folder, decoded too: found, not sure (a folder's name isn't the file's).
        let inFolder = try Searcher(store: store).search("财务").hits
        #expect(inFolder.map(\.title) == ["发票清单.txt"] && inFolder.first?.strong == false)
        // The name as the file system has it still finds it.
        #expect(try Searcher(store: store).search("E5").hits.map(\.title).contains("发票清单.txt"))
        #expect(IndexStore.nameWords("/a/" + Self.file) == Self.file.dropLast(4) + " 发票清单 txt")
        #expect(IndexStore.nameWords("/a/发票.pdf") == "发票 pdf")
    }

    @Test func anIndexWrittenBeforeIsWrittenAgainOnce() throws {
        let scratch = try Scratch()
        let (store, _) = try Self.library(scratch)
        let path = scratch.path + "/files/\(Self.folder)/\(Self.file)"
        let item = try #require(try store.item(path: path))
        // As an earlier version wrote it: the raw name and folder only, and no note in meta.
        let segment = try store.db.scalarInt("SELECT id FROM segments WHERE item = ? AND kind = 'name'", [.int(item.id)])
        try store.db.execute("DELETE FROM meta WHERE key = '\(IndexStore.namesDecoded)'")
        try store.db.query("UPDATE fts SET name = ?, body = ? WHERE rowid = ?",
                           [.text(Script.normalized(IndexStore.spaced(Self.file.dropLast(4) + " txt"))),
                            .text(Script.normalized("files " + Self.folder)), .int(segment)])
        try store.db.query("DELETE FROM fts_tri WHERE rowid = ?", [.int(segment)])
        #expect(try Searcher(store: store).search("清单").hits.isEmpty)
        // Opened again: written again, and noted.
        let again = try scratch.store()
        #expect(try Searcher(store: again).search("清单").hits.map(\.title) == ["发票清单.txt"])
        #expect(try again.db.scalarInt("SELECT count(*) FROM meta WHERE key = ?", [.text(IndexStore.namesDecoded)]) == 1)
        // Other files' name segments untouched.
        let plain = try #require(try again.item(path: scratch.path + "/files/普通的发票.txt"))
        #expect(try again.db.scalarInt("SELECT count(*) FROM segments WHERE item = ? AND kind = 'name'",
                                       [.int(plain.id)]) == 1)
        #expect(try Searcher(store: again).search("普通").hits.map(\.title) == ["普通的发票.txt"])
    }
}
