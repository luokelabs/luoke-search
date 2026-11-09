import Foundation
import Testing
@testable import LuokeSearchKit

// 10-23: a sheet whose columns' names aren't its first row — a title or two above them, empty rows — had its
// password column unmasked (#32's independent review, must-fix 5); and a sheet with no names at all is masked by what
// its cells look like. xlsx, CSV and TSV alike. Made-up sheets only.
struct SheetTitleTests {
    /// A sheet's snippets for `term`, every part of it, as they go out.
    static func snippets(_ sheet: String, _ term: String) -> [String] {
        TextShapes.sheetChunks(sheet).compactMap { Searcher.sheetSnippet($0, terms: [term]) }
    }

    static func rows(_ count: Int) -> [String] {
        (1...count).map { String(format: "site%03d.example\tuser%03d\tRowPw%03d!x", $0, $0, $0) }
    }

    @Test("Names under one title, two titles, a title of two cells: the password column is masked in every part",
          arguments: [["我的密码本 2026"], ["我的密码本", "导出于 2026-10-23"], ["导出时间\t2026-10-23"], []])
    func titlesAboveTheNames(titles: [String]) {
        let sheet = (["账号"] + titles + ["网站\t账号\t密码"] + Self.rows(120)).joined(separator: "\n")
        let parts = TextShapes.sheetChunks(sheet)
        #expect(parts.count > 1)
        for part in parts {
            #expect(part.hasPrefix((["账号"] + titles + ["网站\t账号\t密码"]).joined(separator: "\n")), "\(part.prefix(80))")
        }
        for term in ["user001", "user080", "user120"] {
            let snippet = Self.snippets(sheet, term).first { $0.contains(term) } ?? ""
            #expect(snippet.contains("密码：〔密码〕") && !snippet.contains("RowPw"), "\(snippet)")
            #expect(snippet.hasPrefix("「账号」网站："), "\(snippet)")   // titles aren't rows of the table
        }
    }

    @Test("CSV and TSV: a title line, blank lines and Excel's sep= before the names")
    func delimited() {
        let csv = "Exported passwords 2026\n\n,,\nsite,user,password\nexample.org,kiwi,CsvPw!x1\nshop.test,bob,ShopPw!2026\n"
        let sheet = TextShapes.sheet(delimited: csv, name: "导出", tabs: false)
        #expect(Self.snippets(sheet, "kiwi") == ["「导出」site：example.org，user：kiwi，password：〔密码〕"])
        let tsv = "网站账号\t\t\n\n网站\t账号\t密码\nexample.org\tkiwitsv\tTsvPw!y2\n"
        #expect(Self.snippets(TextShapes.sheet(delimited: tsv, name: "t", tabs: true), "kiwitsv")
                == ["「t」网站：example.org，账号：kiwitsv，密码：〔密码〕"])
        let sep = "sep=;\n我的账号\nsite;user;password\nexample.org;kiwisep;SepPw!z3"
        #expect(Self.snippets(TextShapes.sheet(delimited: sep, name: "e", tabs: false), "kiwisep")
                == ["「e」site：example.org，user：kiwisep，password：〔密码〕"])
    }

    @Test("Excel: titles, an empty row (only styles in it) and then the names")
    func excel() throws {
        func cell(_ ref: String, _ text: String) -> String { "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(text)</t></is></c>" }
        let rows = "<row r=\"1\">\(cell("A1", "家里的账号"))</row>"
            + "<row r=\"2\"><c r=\"A2\" s=\"3\"/><c r=\"B2\" s=\"3\"/></row>"
            + "<row r=\"3\">\(cell("A3", "网站"))\(cell("B3", "账号"))\(cell("C3", "密码"))</row>"
            + "<row r=\"4\">\(cell("A4", "a.example"))\(cell("B4", "kiwixlsx"))\(cell("C4", "XlsxPw!2026"))</row>"
        let data = ZipWriter.make([
            ("xl/workbook.xml", "<workbook xmlns:r=\"r\"><sheets><sheet name=\"常用\" r:id=\"rId1\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/></Relationships>"),
            ("xl/worksheets/sheet1.xml", "<worksheet><sheetData>\(rows)</sheetData></worksheet>"),
        ])
        let text = try #require(try Office.xlsx(ZipArchive(data: data)).first?.text)
        #expect(text == "常用\n家里的账号\n网站\t账号\t密码\na.example\tkiwixlsx\tXlsxPw!2026")
        #expect(Self.snippets(text, "kiwixlsx") == ["「常用」网站：a.example，账号：kiwixlsx，密码：〔密码〕"])
    }

    @Test("No names at all: a column most of whose cells look like passwords is masked; the others stay")
    func noNames() {
        let sheet = "账号\na.example\talice\tPw!2026xq\nb.example\tbob\tQw#2027zz\nc.example\tcarol\tZx9Lm2qT"
        for term in ["alice", "bob", "carol"] {
            let snippet = Self.snippets(sheet, term).first ?? ""
            #expect(snippet.contains(term) && snippet.contains("example") && snippet.contains("〔密码〕"), "\(snippet)")
            #expect(!["Pw!2026xq", "Qw#2027zz", "Zx9Lm2qT"].contains { snippet.contains($0) }, "\(snippet)")
        }
        // One row alone, as a long sheet's later part may be.
        #expect(Self.snippets("账号\na.example\talice\tPw!2026xq", "alice") == ["「账号」a.example，alice，〔密码〕"])
        // Names that say something else ("Kennwort"): a column of values with signs in them.
        #expect(Self.snippets("账号\nSite\tUser\tKennwort\na.example\talice\tPw!2026xq", "alice")
                == ["「账号」Site：a.example，User：alice，Kennwort：〔密码〕"])
    }

    @Test("Ordinary sheets: names in the first row, labels and values; a first row of values isn't taken for names")
    func ordinarySheets() {
        #expect(Self.snippets("十月\n日期\t项目\t金额\n10-05\t物业费\t420", "物业费") == ["「十月」日期：10-05，项目：物业费，金额：420"])
        #expect(Self.snippets("杂项\n项目\t内容\nWiFi 密码\t88887777kv\n门禁\t楼下", "WiFi") == ["「杂项」项目：WiFi 密码，内容：〔密码〕"])
        #expect(Self.snippets("需求\n功能\t说明\n找回密码\t用户通过短信找回", "找回") == ["「需求」功能：找回密码，说明：用户通过短信找回"])
        #expect(Self.snippets("名单\nuser01\tsite01.example\nuser02\tsite02.example", "user02") == ["「名单」user02，site02.example"])
        #expect(Self.snippets("名单\n姓名\t工号\n张三\tA1001\n李四\tA1002", "张三") == ["「名单」姓名：张三，工号：A1001"])
    }
}

extension ReadsPictures {
    struct SheetTitleSearchTests {
        @Test("Indexed and searched as the agent does: a CSV with a title, a header-less TSV")
        func throughTheAgent() throws {
            let corpus = try ReadsPictures.SecretsOutTests.Corpus([
                "导出.csv": Data("Exported passwords 2026\nsite,user,password\nexample.org,kiwititle,TitlePw!x1\n".utf8),
                "无表头.tsv": Data("a.example\tkiwinohead\tNoHeadPw!2\nb.example\tother\tOtherPw#3x\n".utf8),
            ])
            for (query, secret) in [("kiwititle", "TitlePw"), ("kiwinohead", "NoHeadPw")] {
                let answer = try ReadsPictures.ReleaseReviewMaskedOutTests.withoutPaths(try corpus.agentAnswer(query))
                #expect(!answer.contains(secret), "\(query)")
                #expect(answer.contains("〔密码〕"), "\(query)")
            }
        }
    }
}
