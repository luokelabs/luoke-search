import Foundation
import Testing
@testable import LuokeSearchKit

/// A small synthetic library, indexed and searched end to end.
final class Library {
    let scratch: Scratch
    let store: IndexStore
    let indexer: Indexer
    var root: String { scratch.path + "/files" }

    init() throws {
        scratch = try Scratch()
        store = try scratch.store()
        indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        try scratch.write("files/合同/租赁合同摘要.md", "# 租赁合同\n房屋位于静安区。押金为两个月租金，于签约时一次付清。")
        try scratch.write("files/notes/running.txt", "Notes on running a marathon: keep the pace slow and steady.")
        try scratch.write("files/notes/疫苗.txt", "麻腮风疫苗第一针定在九月十四日上午。", encoding: TextDecoding.gb18030)
        try scratch.write("files/notes/行程.html", "<html><head><title>成都</title></head><body><p>宽窄巷子喝茶</p></body></html>")
        try scratch.write("files/work/发布会.pptx", data: ZipWriter.pptx(slides: [
            ("输入法发布会", nil), ("价格：团队版每人每月 18 元", "按年付打八折"),
        ]))
        try scratch.write("files/密码.txt", "银行卡密码 123456")
        try scratch.write("files/notes/aws-credentials.csv", "key,secret")
        try scratch.write("files/.hidden/秘密.md", "隐藏文件夹里的东西")
        try scratch.write("files/app/node_modules/pkg/readme.md", "dependency docs")
        try scratch.write("files/app/package.json", "{}")
        try scratch.write("files/app/notes.md", "项目里的笔记")
        try scratch.write("files/app/Screenshot 2026-10-01 at 10.00.00.png",
                          data: Drawn.png(Drawn.picture(["构建失败：找不到模块"])))
        try scratch.write("files/data.json", "{\"不是\": \"文档\"}")
    }

    func index() throws -> Indexer.SyncReport {
        let report = try indexer.sync([root])
        try indexer.readPending()
        return report
    }

    func search(_ text: String, _ options: SearchOptions = SearchOptions()) throws -> SearchAnswer {
        try Searcher(store: store).search(text, options: options)
    }

    func titles(_ text: String, _ options: SearchOptions = SearchOptions()) throws -> [String] {
        try search(text, options).hits.map(\.title)
    }
}

extension ReadsPictures {
    struct IndexTests {
        @Test func whatGetsIndexedAndWhatDoesnt() throws {
            let library = try Library()
            let report = try library.index()
            #expect(report.added == 6)   // 4 documents, the pptx, the project's screenshot
            #expect(report.skipped["credential file"] == 2)
            #expect(report.skipped["developer folder"] == 1)
            #expect(report.skipped["in a code project"] == 1)
            let counts = try library.store.counts()
            #expect(counts.items["doc"] == 5)
            #expect(counts.items["screenshot"] == 1)
            #expect(counts.waitingToRead == 0)
            #expect(counts.waitingForVectors == 6)   // four documents' one chunk each, and two slides
            #expect(try library.titles("密码").isEmpty)
            #expect(try library.titles("银行卡").isEmpty)
            #expect(try library.titles("秘密").isEmpty)
            #expect(try library.titles("项目里的笔记").isEmpty)
        }

        @Test func chineseWordsOfTwoAndMoreCharacters() throws {
            let library = try Library()
            _ = try library.index()
            #expect(try library.titles("押金").first == "租赁合同摘要.md")              // two characters: LIKE
            #expect(try library.titles("静安区").first == "租赁合同摘要.md")            // three: trigram
            #expect(try library.titles("合同里写押金的那页").first == "租赁合同摘要.md")  // a sentence, split into words
            #expect(try library.titles("疫苗").first == "疫苗.txt")                     // read from GBK
            #expect(try library.titles("宽窄巷子").first == "行程.html")
        }

        @Test func pointsAtThePlaceInside() throws {
            let library = try Library()
            _ = try library.index()
            let hit = try #require(try library.search("团队版怎么收费").hits.first)
            #expect(hit.title == "发布会.pptx")
            #expect(hit.where == Location(page: 2))
            #expect(hit.id.hasSuffix("#s2"))
            #expect(hit.why == "第 2 页幻灯片的文字对得上")
            #expect(hit.snippet?.contains("团队版") == true)
            let notes = try #require(try library.search("年付 八折").hits.first)
            #expect(notes.title == "发布会.pptx")   // speaker notes are searched with their slide
            #expect(try library.search("年付八折").hits.first?.title == "发布会.pptx")   // run together: tried in pairs
        }

        @Test func englishStemsAndNames() throws {
            let library = try Library()
            _ = try library.index()
            #expect(try library.titles("marathon run").first == "running.txt")
            #expect(try library.titles("租赁合同").first == "租赁合同摘要.md")
            let byFolder = try #require(try library.search("合同").hits.first { $0.title == "租赁合同摘要.md" })
            #expect(byFolder.path?.hasSuffix("/files/合同/租赁合同摘要.md") == true)
        }

        @Test func kindWordsAndFilters() throws {
            let library = try Library()
            _ = try library.index()
            #expect(try library.titles("截图") == ["Screenshot 2026-10-01 at 10.00.00.png"])
            #expect(try library.titles("押金", SearchOptions(kinds: [.pdf])).isEmpty)
            let future = Date().timeIntervalSince1970 + 86_400
            #expect(try library.titles("押金", SearchOptions(since: future)).isEmpty)
            #expect(try library.titles("押金", SearchOptions(until: future)) == ["租赁合同摘要.md"])
        }

        @Test func renamedFileKeepsWhatWasRead() throws {
            let library = try Library()
            _ = try library.index()
            let before = try #require(try library.store.item(path: library.root + "/notes/running.txt"))
            try FileManager.default.moveItem(atPath: library.root + "/notes/running.txt",
                                             toPath: library.root + "/notes/marathon-plan.txt")
            let report = try library.indexer.sync([library.root])
            #expect(report.moved == 1)
            #expect(report.added == 0 && report.removed == 0)
            let after = try #require(try library.store.item(path: library.root + "/notes/marathon-plan.txt"))
            #expect(after.id == before.id)
            #expect(after.state == "done")
            #expect(try library.titles("marathon plan").first == "marathon-plan.txt")
            #expect(try library.titles("running").first == "marathon-plan.txt")   // the text is still there
        }

        @Test func changedAndDeletedFiles() throws {
            let library = try Library()
            _ = try library.index()
            let file = library.root + "/notes/running.txt"
            try "Swimming drills for the winter.".write(toFile: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file)
            try FileManager.default.removeItem(atPath: library.root + "/notes/行程.html")
            let report = try library.index()
            #expect(report.changed == 1)
            #expect(report.removed == 1)
            #expect(try library.titles("swimming") == ["running.txt"])
            #expect(try library.titles("marathon").isEmpty)
            #expect(try library.titles("宽窄巷子").isEmpty)
            let rows = try library.store.db.scalarInt("SELECT COUNT(*) FROM fts") - library.store.db.scalarInt(
                "SELECT COUNT(*) FROM segments")
            #expect(rows == 0)   // no keyword rows left behind
        }

        @Test func unreachableRootKeepsItsItems() throws {
            let library = try Library()
            _ = try library.index()
            let moved = library.scratch.path + "/unplugged"
            try FileManager.default.moveItem(atPath: library.root, toPath: moved)
            let report = try library.indexer.sync([library.root])
            #expect(report.unreachable == [library.root])
            #expect(report.removed == 0)
            #expect(try library.store.counts().items["doc"] == 5)
        }

        @Test func pruneDropsFoldersNoLongerSearched() throws {
            let library = try Library()
            _ = try library.index()
            #expect(try library.indexer.prune(keeping: [library.root + "/notes"]) == 3)
            #expect(try library.titles("押金").isEmpty)
            #expect(try library.titles("疫苗") == ["疫苗.txt"])
        }

        @Test func newerReaderRequeues() throws {
            let library = try Library()
            _ = try library.index()
            var versions = Reader.versions
            versions[.doc] = (versions[.doc] ?? 0) + 1
            #expect(try library.store.requeueOlderReaders(versions) == 5)
            #expect(try library.store.counts().waitingToRead == 5)
        }

        @Test func dataDirectoryIsPrivateAndNotBackedUp() throws {
            let library = try Library()
            let data = library.scratch.url.appendingPathComponent("data")
            #expect(DataDirectory.isExcludedFromBackup(data))
            let mode = try FileManager.default.attributesOfItem(atPath: data.path)[.posixPermissions] as? Int
            #expect(mode == 0o700)
            let fileMode = try FileManager.default.attributesOfItem(atPath: library.store.file.path)[.posixPermissions] as? Int
            #expect(fileMode == 0o600)
            #expect(library.store.file.path.hasSuffix("/index.noindex/index.sqlite"))
        }
    }
}

struct QueryTests {
    @Test func chineseSentenceBecomesWords() {
        let query = Query("帮我找一下合同里写押金的那页")
        #expect(query.terms.map(\.text).contains("押金"))
        #expect(query.terms.map(\.text).contains("合同"))
        #expect(!query.terms.map(\.text).contains("的"))
        #expect(query.terms.allSatisfy { $0.unspaced })
    }

    @Test func kindWordsBecomeHints() {
        let query = Query("上个月拍的白板照片")
        #expect(query.kindHints == [.image, .photo])   // pictures in folders and in Photos
        #expect(query.terms.map(\.text).contains("白板"))
        #expect(!query.terms.map(\.text).contains("照片"))
        #expect(Query("那段说到膝盖疼的录音").kindHints == [.audio])
        #expect(Query("Q3 invoice screenshot").kindHints == [.screenshot])
        #expect(Query("截图").terms.isEmpty)
    }

    @Test func englishStopwordsAndLookups() {
        #expect(Query("find the file about the Tokyo trip").terms.map(\.text) == ["tokyo", "trip"])
        #expect(Query("K7Q2LM").isLookup)
        #expect(!Query("tokyo trip").isLookup)
        #expect(Query("ＰＤＦ").kindHints == [.pdf])   // full-width letters are plain ones
    }

    @Test func oneCharacterQueryIsKept() {
        #expect(Query("猫").terms.map(\.text) == ["猫"])
    }

    @Test func charactersTheTokenizerLeavesAloneJoin() {
        // NLTokenizer splits words it doesn't know ("年付") into single characters; neighbours join again, but not
        // across a space and not through function words.
        let query = Query("年付 八折")
        #expect(query.terms.map(\.text) == ["年付", "八折"])
        #expect(query.terms.allSatisfy { $0.optional })
        #expect(query.countedTerms == 2)
        let mixed = Query("上个月拍的白板照片")
        #expect(mixed.terms.filter { !$0.optional }.map(\.text) == ["白板"])
        #expect(mixed.countedTerms == 1)   // a join like "月" + … never counts against an item
    }
}

struct SheetSnippetTests {
    @Test func aSheetHitShowsTheRowUnderItsColumns() throws {
        let scratch = try Scratch()
        try scratch.write("files/开支.xlsx", data: ZipWriter.xlsx(
            sheet: "十月", shared: ["项目", "金额", "房租", "物业费", "宽带"],
            rows: [["s:0", "s:1"], ["s:2", "6500"], ["s:3", "320"], ["s:4", "100"]]))
        let store = try scratch.store()
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        _ = try indexer.sync([scratch.path + "/files"])
        try indexer.readPending()
        let hit = try #require(try Searcher(store: store).search("物业费").hits.first)
        #expect(hit.snippet == "「十月」项目：物业费，金额：320")
    }

    @Test func rowsWithoutAHeaderOrWithoutTheWords() {
        // Found by its name only: the first two rows.
        #expect(Searcher.sheetSnippet("十月\n项目\t金额\n房租\t6500\n物业费\t320\n宽带\t100", terms: ["开支"])
                == "「十月」项目：房租，金额：6500；项目：物业费，金额：320")
        // A later part of a long sheet: no name, no header; empty cells left out.
        #expect(Searcher.sheetSnippet("物业费\t\t320\n宽带\t\t100", terms: ["宽带"]) == "宽带，100")
        // Long rows are cut.
        let long = Searcher.sheetSnippet("备注\t" + String(repeating: "很长", count: 200), terms: [])
        #expect(long?.count == 160 && long?.hasSuffix("…") == true)
    }
}

struct RefusalTests {
    @Test func questionsWithAndWithoutAnAnswer() throws {
        let library = try Library()
        _ = try library.index()
        let set = try JSONDecoder().decode(EvalSet.self, from: Data("""
            {"base": "\(library.root)", "queries": [
             {"q": "押金", "expect": ["合同/租赁合同摘要.md"], "tag": "doc"},
             {"q": "火星基地的氧气从哪来", "expect": [], "tag": "none-far"}]}
            """.utf8))
        let searcher = Searcher(store: library.store)
        let report = try Evaluation.refusal([set], testbed: nil) { try searcher.search($0) }
        #expect(report.records.map(\.answerable) == [true, false])
        #expect(report.records[0].rank == 1)
        #expect(report.records[0].share == 1)
        #expect(report.records[0].z == nil)   // no vectors here
        #expect(report.records[0].strong == 0)   // the word only in the text, and no vectors: not sure
        #expect(report.records[1].hits == 0 && report.records[1].top == nil)
        let first = try #require(report.rules.first)
        #expect(first.rule == "score ≥ 1.0")
        #expect(first.refusedWithoutAnswer == 1)   // nothing found counts as held back
        #expect(first.wronglyRefused == 0)
    }
}
