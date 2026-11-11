import CoreGraphics
import Foundation
import Testing
@testable import LuokeSearchKit

/// What the window's grouped results need from a hit: tables as their own kind with a picture of their first rows, a
/// PDF's thumbnail of the page that matched, and names kept percent-encoded shown decoded.
extension ReadsPictures {
    struct WindowHitFieldsTests {
        typealias G = GlobalSearchTests

        @Test func namesKeptPercentEncodedAreShownDecoded() {
            #expect(Names.display("%E3%80%90%E5%8F%91%E7%A5%A8%E3%80%91.pdf") == "【发票】.pdf")
            #expect(Names.display("report%202026.pdf") == "report 2026.pdf")
            // As it is: nothing encoded, not valid UTF-8, a broken escape, a slash or a control character inside.
            for name in ["发票.pdf", "100%.txt", "%E3%80.pdf", "%ZZ.pdf", "a%2Fb.pdf", "a%0Ab.pdf", "a%00b.pdf"] {
                #expect(Names.display(name) == name, "\(name)")
            }
        }

        @Test func aDecodedTitleKeepsTheRawPathToOpen() throws {
            let agent = try Agent()
            let raw = "%E5%B7%AE%E6%97%85%E6%8A%A5%E9%94%80.txt"   // 差旅报销.txt
            try agent.library.scratch.write("files/下载/" + raw, "住宿费发票一张，合计四百元。")
            _ = try agent.library.index()
            let hit = try #require(try G.hits(agent.call("search_query", ["query": "住宿费"])).first)
            #expect(hit["title"] as? String == "差旅报销.txt")
            #expect((hit["path"] as? String)?.hasSuffix("/下载/" + raw) == true)
            // Opening goes by the id, to the file as it's named.
            _ = agent.call("search_open", ["id": hit["id"] as? String ?? ""], tapped: "luoke-search/search")
            #expect(agent.opened.log.last?.hasPrefix("open \(raw) ") == true)
        }

        @Test func tablesAreTheirOwnKindWithAPictureOfTheirRows() throws {
            let agent = try Agent()
            let scratch = agent.library.scratch
            try scratch.write("files/报销/十月开支.xlsx", data: ZipWriter.xlsx(
                sheet: "十月", shared: ["日期", "项目", "金额", "发票号"],
                rows: [["s:0", "s:1", "s:2", "s:3"], ["1005", "1201", "420", "88001"], ["1006", "1202", "65", "88002"]]))
            try scratch.write("files/报销/住宿.csv", "日期,项目,金额\n10-05,住宿费发票,420\n10-06,打车,65\n")
            _ = try agent.library.index()

            let csv = try #require(try G.hits(agent.call("search_query", ["query": "住宿费发票"]))
                .first { $0["title"] as? String == "住宿.csv" })
            #expect(csv["kind"] as? String == "sheet" && csv["kind_label"] as? String == "表格")
            let item = try G.item(agent, "报销/住宿.csv")
            #expect(csv["thumb"] as? String == "thumb/\(item)")
            let picture = try #require(G.thumb(agent, "thumb/\(item)"))
            #expect(picture.width == Thumbs.pixels && picture.height == Thumbs.pixels * 3 / 4)
            #expect(picture.data.count <= Thumbs.maxBytes)

            let xlsx = try #require(try G.hits(agent.call("search_query", ["query": "十月开支"]))
                .first { $0["title"] as? String == "十月开支.xlsx" })
            #expect(xlsx["kind"] as? String == "sheet" && xlsx["kind_label"] as? String == "表格")
            let book = try G.item(agent, "报销/十月开支.xlsx")
            let uri = try #require(xlsx["thumb"] as? String)
            #expect(uri == "thumb/\(book)" || uri == "thumb/\(book)-w1")
            #expect(G.thumb(agent, "thumb/\(book)-w1") != nil)
            // A worksheet it doesn't have, a page of a table, a worksheet of a PDF: none.
            #expect(G.thumb(agent, "thumb/\(book)-w2") == nil)
            #expect(G.thumb(agent, "thumb/\(book)-p1") == nil)
            #expect(G.thumb(agent, "thumb/\(item)-w2") == nil)

            // Still a document to the index and its filter; other documents keep their kind.
            #expect(SearchService.thumbID(Self.hit("/a/表.xlsx", .doc, sheet: 3)) == "thumb/7-w3")
            #expect(SearchService.thumbID(Self.hit("/a/说明.docx", .doc)) == nil)
            let doc = try #require(try G.hits(agent.call("search_query", ["query": "押金"])).first)
            #expect(doc["kind"] as? String == "doc" && doc["kind_label"] as? String == "文档")
            // A model passing the window's kind back as a filter gets documents, not no filter at all.
            let sheets = try G.hits(agent.call("search_query", ["query": "住宿费发票", "kinds": ["sheet"]]))
            #expect(!sheets.isEmpty && sheets.allSatisfy { ["sheet", "doc"].contains($0["kind"] as? String) })
            #expect(try G.hits(agent.call("search_query", ["query": "住宿费发票", "kinds": ["photo"]])).isEmpty)
        }

        @Test func aTablesPictureMasksItsPasswords() throws {
            let text = "账号\n网站\t用户名\t密码\nexample.com\tuser01\tPw!2026xq\n备用\tuser02\tKx#88zzq1"
            let table = try #require(SheetPicture.rows(text))
            #expect(table.header == ["网站", "用户名", "密码"])
            #expect(table.rows.allSatisfy { !$0[2].contains("2026") && !$0[2].contains("88zz") })
            #expect(table.rows[0][0] == "example.com")
            // A card number in a cell, with no column to say so.
            let card = try #require(SheetPicture.rows("付款\n备注\t金额\n卡 4111 1111 1111 1111\t20"))
            #expect(!card.rows[0][0].contains("4111 1111"))
            #expect(SheetPicture.rows("") == nil)
        }

        @Test func aPDFsThumbnailIsThePageThatMatched() throws {
            let agent = try Agent()
            try agent.library.scratch.write("files/扫描/合同.pdf",
                                            data: Drawn.pdf(textPage: ["租赁合同"], scannedPage: ["签字页"]))
            _ = try agent.library.index()
            let item = try G.item(agent, "扫描/合同.pdf")
            let first = try #require(G.thumb(agent, "thumb/\(item)-p1"))
            let second = try #require(G.thumb(agent, "thumb/\(item)-p2"))
            #expect(first.data != second.data)
            // Without a page, the first; one it doesn't have, none.
            #expect(G.thumb(agent, "thumb/\(item)")?.data == first.data)
            for ref in ["-p3", "-p0", "-p", "-p01", "-x1", "-p1-p2", "-w1", "-"] {
                #expect(G.thumb(agent, "thumb/\(item)\(ref)") == nil, "\(ref)")
            }
            #expect(SearchService.thumbID(Self.hit("/a/合同.pdf", .pdf, page: 3)) == "thumb/7-p3")
            #expect(SearchService.thumbID(Self.hit("/a/合同.pdf", .pdf)) == "thumb/7")
            // A hit on the scanned page points at it.
            let scanned = try #require(try G.hits(agent.call("search_query", ["query": "签字页"]))
                .first { $0["title"] as? String == "合同.pdf" })
            #expect((scanned["id"] as? String)?.hasSuffix("#p2") == true)
            #expect(scanned["thumb"] as? String == "thumb/\(item)-p2")
        }

        static func hit(_ path: String, _ kind: ItemKind, page: Int? = nil, sheet: Int? = nil) -> Hit {
            let place = page != nil || sheet != nil ? Location(page: page, sheet: sheet) : nil
            return Hit(id: "7", kind: kind, title: (path as NSString).lastPathComponent, path: path, where: place,
                       date: "2026-10-01", snippet: nil, why: "", score: 1, strong: false)
        }
    }
}
