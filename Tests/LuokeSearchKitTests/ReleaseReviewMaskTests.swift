import Foundation
import Testing
@testable import LuokeSearchKit

// The pre-release security review (10-23): credentials that went out unmasked. Must-fix 3 (a card number with
// its expiry, CVV or a phone number beside it), 4 (password lists in sheets and CSV/TSV), 5 (common ways of saying a
// password or code); should-fix 4 (ID and passport numbers written with separators), 5 (keys and tokens), 6 (a long
// private key's later parts). The samples are the review's own (made up); so is everything else here.
struct ReleaseReviewMaskTests {
    /// Each sample, and what of it mustn't go out.
    static let leaked: [(text: String, secret: String)] = [
        // Must-fix 3: cards.
        ("Visa 卡号 4111 1111 1111 1111 12/28 用于订机票", "4111 1111"),
        ("Visa 卡号 4111 1111 1111 1111 12-28 用于订机票", "4111 1111"),
        ("备用卡 4012 8888 8888 1881 123 在抽屉里", "4012 8888"),
        ("电话 138 0013 8000 4012 8888 8888 1881", "4012 8888"),
        ("Visa 卡号 ４１１１ １１１１ １１１１ １１１１ １２/２８", "４１１１ １１１１"),
        ("开会 2026-10-23 4111 1111 1111 1111 报销", "1111 1111"),
        ("visa 4111111111111111 12-28.txt", "4111111111"),
        // Must-fix 5: passwords and codes, said as people say them.
        ("家里的 WiFi密码88886666 记得改", "88886666"),
        ("支付宝 支付密码680417 不要告诉别人", "680417"),
        ("Reminder: my password is Hunter2Xyz for the old router", "Hunter2Xyz"),
        ("Router admin. Password - Tr0ub4dor9x (changed in May)", "Tr0ub4dor9x"),
        ("台北辦公室 密碼是 Abc12345tw 請勿外流", "Abc12345tw"),
        ("邮箱的密码就是 qwe789asd 别忘了", "qwe789asd"),
        ("路由器密码改成 Zz9-home-2026 了", "Zz9-home-2026"),
        ("SMS: Your verification code is 739201. Do not share it.", "739201"),
        ("the code is 551203 for the door", "551203"),
        // Should-fix 4: IDs and passports.
        ("身份证 110101 19900307 0017 复印件", "19900307"),
        ("身份证 110101-1990-0307-0017 复印件", "1990-0307"),
        ("身份证号：1101011985 05120034 办护照用", "1101011985"),
        ("身份证 １１０１０１ １９９００３０７ ００１７", "１９９００３０７"),
        ("Passport #: E98765432 expires 2031", "E98765432"),
        ("My passport number is G12345678, keep it safe", "G12345678"),
        // Should-fix 5: keys and tokens.
        ("aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "bPxRfiCYEXAMPLEKEY"),
        ("client_secret=Ab3+Cd4/Ef5Gh6Ij7Kl8Mn9Op0Qr1St2Uv3Wx4Yz5", "Ef5Gh6Ij7Kl8Mn9"),
        ("api_key: 5f4dcc3b5aa765d61d8327deb882cf99 (prod)", "5f4dcc3b5aa765d6"),
        ("Authorization: Bearer 9c1185a5c5e9fc54612808977ee8f548b2258d31", "9c1185a5c5e9fc54"),
        (#"{"api_key": "0f3c9a7e21d84b6f9e05c4a1b2d3e4f5"}"#, "0f3c9a7e21d84b6f"),
        ("GITHUB_TOKEN=ghx_9c1185a5c5e9fc546128", "9c1185a5c5e9fc54"),
        ("下面是新的 base64 密钥 Q2xhdWRlIGlzIGEgbW9kZWwgYnkgQW50aHJvcGljLg+/Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MA== 收好",
         "Q2xhdWRlIGlzIGEgbW9kZWwg"),
        ("-----BEGIN PGP PRIVATE KEY BLOCK-----\nlQOYBF8xQmQBCADpGx7Lz9pQk2V8mN3rT6yH1uJ4oP0sD5fG2hK7lZ9xC3vB8nM\n-----END PGP PRIVATE KEY BLOCK-----",
         "lQOYBF8xQmQBCADpGx7Lz9pQk2V8"),
        ("钱包助记词：abandon ability able about above absent absorb abstract absurd abuse access accident", "absorb abstract"),
        ("GitHub recovery codes: 3f9a1-b7c2e 8d4e0-a1f6b 5c2b9-e8d7a", "3f9a1-b7c2e"),
        // The independent review of this change: what it had broken, and phrasings it found.
        ("https://maps.googleapis.com/maps/api/js?key=AIzaSyD4fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zAb&callback=init", "AIzaSyD4fG7hJ9kL1mN3"),
        ("AccountKey=Ab3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zQ8rT6", "Ab3dE5fG7hJ9kL1mN3"),
        ("卡 8171 2345 6789 0125 2028", "8171 2345"),
        ("工行卡 9558 8012 3456 7890 128 12/28", "9558 8012"),
        ("Your verification code is: 739201", "739201"),
        ("Your Apple ID Code is: 482913", "482913"),
        ("739201 is your OTP for login", "739201"),
        ("G-482913 is your Google verification code", "482913"),
        ("新路由器的密码设为 Abc12345 了", "Abc12345"),
        ("几个账号密码都是 abc123456", "abc123456"),
        ("pw: Hunter2Xyz", "Hunter2Xyz"),
        ("SECRET_KEY = 'k#3m!x9@q$2w&e7r(t)y-u_i=o+p$z8v^c5b*n1m'", "k#3m!x9@q$2w"),
        ("DB_SECRET=P@ssw0rd!2026xyzABC", "P@ssw0rd!2026"),
        ("钱包私钥：4c0883a69102937d6231471b5dbb6204fe512961708279f", "4c0883a6910293"),
        ("接口密钥：5f4dcc3b5aa765d61d8327deb882cf99", "5f4dcc3b5aa765d6"),
        ("Passport: NO1234567", "NO1234567"),
    ]

    @Test("Each sample the review found going out is masked", arguments: leaked)
    func masked(sample: (text: String, secret: String)) {
        let out = Secrets.mask(sample.text)
        #expect(!out.contains(sample.secret), "\(out)")
        #expect(out.contains("〔"), "\(out)")
    }

    @Test("A card keeps its last 4, and only the card is taken: its expiry, CVV and the phone beside it stay")
    func cardsWithNeighbours() {
        #expect(Secrets.mask("卡号 4111 1111 1111 1111 12/28") == "卡号 〔卡号 ****1111〕 12/28")
        #expect(Secrets.mask("4012 8888 8888 1881 123") == "〔卡号 ****1881〕 123")
        #expect(Secrets.mask("电话 138 0013 8000 4012 8888 8888 1881") == "电话 138 0013 8000 〔卡号 ****1881〕")
        #expect(Secrets.mask("2026-10-23 4111 1111 1111 1111") == "2026-10-23 〔卡号 ****1111〕")
        // A run that passes Luhn whole is taken whole, as before: here the expiry with it.
        #expect(Secrets.mask("Amex 3782 822463 10005 0927") == "Amex 〔卡号 ****0927〕")
        #expect(Secrets.mask("Amex 3782 822463 10005 12/27") == "Amex 〔卡号 ****0005〕 12/27")
        #expect(Secrets.mask("银联 6222 7104 6563 4148 399") == "银联 〔卡号 ****8399〕")
        #expect(Secrets.mask("visa 4111111111111111 12-28.txt") == "visa 〔卡号 ****1111〕 12-28.txt")
        // Still as before: a whole run that is a card, a wrapped one.
        #expect(Secrets.mask("6222 0212 3456 7894") == "〔卡号 ****7894〕")
        #expect(Secrets.mask("4111-1111-1111-1111") == "〔卡号 ****1111〕")
    }

    /// Text that has the words, or looks like a key, and isn't one.
    static let plain = [
        "密码学是一门课", "密码锁坏了要换", "密码提示：小时候的狗", "code review 在周三", "the code is simple",
        "passwordless login is coming", "a password-protected file", "token 数量 1234",
        "/home/alice/Documents/Project2024/Report2025Final/Draft2026Version.docx",
        "Library/Application Support/Example/scratch-workspaces/a1b2c3d4",
        "电话 138 0013 8000", "会议 2026-10-23 14:00", "版本 v2.3.4 发布", "API key 的说明见文档",
        // From the independent review of this change.
        "会议 2026-10-23 2026-10-24 2026-10-25 2026-10-26", "联系 212 555 0123 646 555 0199", "a basic state-of-the-art approach",
        "Recovery codes should only be used once", "The error code is 50001", "The code was 1234 lines long",
        "the password is incorrect", "password was changed yesterday", "tokenizer.model = sentencepiece_unigram_v2",
        "Token=ETHEREUM_MAINNET_CONTRACT", "忘记密码...", "下载密码App", "密码学课程 2026 春",
        "da39a3ee5e6b4b0d3255bfef95601890afd80709\n2fd4e1c67a2d28fced849ee1bb76e7391b93eb12\nde9f2c7fd25e1b3afad3e85a0bd17d9b100db4b3",
    ]

    @Test("Ordinary text with the words in it isn't masked", arguments: plain)
    func notMasked(text: String) {
        #expect(Secrets.mask(text) == text)
    }

    @Test("A long private key's later lines are masked without its BEGIN line; ordinary long lines aren't")
    func keyWithoutItsHeader() {
        let line = String(repeating: "MIIEpAIBAAKCAQEA3Tz2mr7SZiAMfQyuvBjM+0e/aBcD", count: 2).prefix(64)
        let part = (0..<5).map { _ in String(line) }.joined(separator: "\n") + "\nAbCd==\n-----END RSA PRIVATE KEY-----\n部署完成"
        let out = Secrets.mask(part)
        #expect(!out.contains("MIIEpAIBAAKCAQEA"), "\(out)")
        #expect(out.hasSuffix("-----END RSA PRIVATE KEY-----\n部署完成"))
        // As the snippet has it: lines joined.
        #expect(!Secrets.mask(part.replacingOccurrences(of: "\n", with: " ")).contains("MIIEpAIBAAKCAQEA"))
        let words = "This line of the report is long but it is made of words and spaces as prose is."
        #expect(Secrets.mask([words, words, words].joined(separator: "\n")) == [words, words, words].joined(separator: "\n"))
    }

    @Test("A file name keeps its extension; a key with a \"/\" isn't taken for a path")
    func namesAndPaths() {
        #expect(Secrets.mask("WiFi密码88886666.txt") == "WiFi密码〔密码〕.txt")
        #expect(Secrets.mask("oQJdG4cvEVNuM4GrBTkja/hlxv/vdKILz/ri+eIKCN0=") == "〔密钥〕")
    }

    @Test("Labels: the word ends the cell")
    func labels() {
        for cell in ["密码：", "Password:", "密码（明文）", "Password (plain)", "密码2", "PW", "pass", "PIN", "PIN 1"] {
            #expect(Secrets.label(cell) == "password", "\(cell)")
        }
        #expect(Secrets.label("TOTP") == "code" && Secrets.label("login_totp") == "code")
        #expect(Secrets.label("Pin") == nil && Secrets.label("Bypass") == nil)
        #expect(Secrets.label("WiFi 密码") == "password")
        #expect(Secrets.label("Password") == "password")
        #expect(Secrets.label("PIN") == "password")
        #expect(Secrets.label("支付密碼") == "password")
        #expect(Secrets.label("API Key") == "key")
        #expect(Secrets.label("短信验证码") == "code")
        for cell in ["密码学", "密码提示", "spin", "shopping", "网站", "", String(repeating: "很长的说明", count: 6) + "密码"] {
            #expect(Secrets.label(cell) == nil, "\(cell)")
        }
    }
}

// Must-fix 4: password lists in sheets and CSV/TSV.
struct ReleaseReviewSheetTests {
    /// The review's long sheet: 网站 / 账号 / 密码, 120 rows, a "!" in every password.
    static let rows = [["网站", "账号", "密码"]] + (1...120).map { n in
        [String(format: "site%03d.example", n), n == 80 ? "kiwirow80" : String(format: "user%03d", n), String(format: "RowPw%03d!x", n)]
    }
    static var text: String { (["账号"] + rows.map { $0.joined(separator: "\t") }).joined(separator: "\n") }

    @Test("A long sheet is cut where rows end, every part with the sheet's name and its columns' names")
    func sheetParts() {
        let parts = TextShapes.sheetChunks(Self.text, size: 600)
        #expect(parts.count > 3)
        for part in parts {
            let lines = part.split(separator: "\n")
            #expect(lines[0] == "账号")
            #expect(lines[1] == "网站\t账号\t密码")
            #expect(lines.dropFirst(2).allSatisfy { $0.hasPrefix("site") && $0.split(separator: "\t").count == 3 }, "\(part)")
        }
        let rows = parts.flatMap { $0.split(separator: "\n").dropFirst(2) }
        #expect(rows.count == 120)   // every row once
        // A short sheet is one part, as it was.
        #expect(TextShapes.sheetChunks("十月\n项目\t金额\n房租\t6500") == ["十月\n项目\t金额\n房租\t6500"])
        #expect(TextShapes.sheetChunks("空的") == ["空的"])
    }

    @Test("Each part's snippet has the password masked under its column")
    func snippets() throws {
        for part in TextShapes.sheetChunks(Self.text) {
            let snippet = try #require(Searcher.sheetSnippet(part, terms: ["kiwirow80", "user100"]))
            #expect(!snippet.contains("RowPw"), "\(snippet)")
        }
        let part = try #require(TextShapes.sheetChunks(Self.text).first { $0.contains("kiwirow80") })
        #expect(Searcher.sheetSnippet(part, terms: ["kiwirow80"]) == "「账号」网站：site080.example，账号：kiwirow80，密码：〔密码〕")
    }

    @Test("A sheet of labels and values: the value after a password's label is masked, its first pair too")
    func labelsAndValues() {
        let sheet = "杂项\n项目\t内容\nWiFi 密码\t88887777kv\n门禁\t楼下"
        #expect(Searcher.sheetSnippet(sheet, terms: ["WiFi"]) == "「杂项」项目：WiFi 密码，内容：〔密码〕")
        let noHeader = "杂项\nWiFi 密码\t88887777kv\n门禁\t楼下\n密码提示\t小狗"
        let snippet = Searcher.sheetSnippet(noHeader, terms: ["门禁"]) ?? ""
        #expect(!snippet.contains("88887777kv"), "\(snippet)")
        #expect(snippet.contains("楼下"))
        #expect(Searcher.sheetSnippet(noHeader, terms: ["密码提示"])?.contains("小狗") == true)
        // A header with a password's column among others: the next column's name stays.
        #expect(Searcher.sheetSnippet("表\n账号\t密码\t备注\nalice\tPw!2026x\t生日", terms: ["alice"])
                == "「表」账号：alice，密码：〔密码〕，备注：生日")
        #expect(Searcher.sheetSnippet("表\n密码\t备注\nPw!2026x\t生日", terms: ["生日"]) == "「表」密码：〔密码〕，备注：生日")
    }

    @Test("Labels with a colon, a first row of several pairs, an empty cell between: their values are masked")
    func moreLabels() {
        let cases = [("杂项\n门禁\t楼下\nWiFi 密码：\tPw!2026xq", "WiFi"), ("杂项\n密码：\tPw!2026xq\n门禁\t楼下", "门禁"),
                     ("杂项\nWiFi 密码\t88887777kv\t门禁\t楼下\n电话\t123\t地址\t某路", "电话"),
                     ("杂项\n项目\t\t内容\nWiFi 密码\t\tPw!2026xq", "WiFi")]
        for (sheet, term) in cases {
            let snippet = Searcher.sheetSnippet(sheet, terms: [term]) ?? ""
            #expect(!snippet.contains("Pw!2026xq") && !snippet.contains("88887777kv"), "\(snippet)")
        }
    }

    @Test("What the words name and isn't a credential stays: a pinout, a description, a coin's name")
    func notCredentials() {
        #expect(Searcher.sheetSnippet("引脚\nPin\tFunction\n1\tVCC\n2\tGND", terms: ["VCC"]) == "「引脚」Pin：1，Function：VCC")
        #expect(Searcher.sheetSnippet("需求\n功能\t说明\n找回密码\t用户通过短信找回", terms: ["找回"])
                == "「需求」功能：找回密码，说明：用户通过短信找回")
        #expect(Searcher.sheetSnippet("持仓\nToken\t数量\nETH\t2", terms: ["ETH"]) == "「持仓」Token：ETH，数量：2")
    }

    @Test("A long row keeps its cells under their names, its long notes in parts of their own; a wide header is cut")
    func longRowsAndWideHeaders() throws {
        let notes = String(repeating: "备注很长。", count: 400)
        let sheet = TextShapes.sheet(delimited: "site,user,password,notes\na.example,alice,Pw!2026xq," + notes, name: "导出", tabs: false)
        let parts = TextShapes.sheetChunks(sheet)
        for part in parts {
            let snippet = Searcher.sheetSnippet(part, terms: ["alice"]) ?? Searcher.snippet(part, terms: ["alice"]) ?? ""
            #expect(!snippet.contains("Pw!2026xq"), "\(snippet)")
        }
        #expect(parts.first?.hasPrefix("导出\nsite\tuser\tpassword\tnotes\na.example\talice\tPw!2026xq\t备注很长") == true)
        #expect(parts.dropFirst().joined().contains(notes.suffix(100)))   // all of it still searchable
        #expect(!parts.dropFirst().contains { $0.contains("Pw!2026xq") })
        // A password under its column longer than a cell's room isn't put whole in a part of its own.
        let long = String(repeating: "Pw!", count: 900)
        let secret = TextShapes.sheetChunks(TextShapes.sheet(delimited: "user,password\nbob," + long, name: "s", tabs: false))
        #expect(!secret.contains { $0.contains(long) })
        #expect(Searcher.sheetSnippet(try #require(secret.first), terms: ["bob"]) == "「s」user：bob，password：〔密码〕")
        // A 30 KB header: cut, and not repeated if still wide.
        let wide = (0..<3000).map { "列\($0)" }.joined(separator: ",")
        let body = (0..<2000).map { "\($0),x" }.joined(separator: "\n")
        let wideParts = TextShapes.sheetChunks(TextShapes.sheet(delimited: wide + "\n" + body, name: "宽", tabs: false))
        #expect(wideParts.allSatisfy { $0.unicodeScalars.count <= 1800 })
    }

    @Test("A quote never closed ends at its line; Excel's sep= line says the separator")
    func unclosedQuotesAndSep() {
        let tsv = "网站\t账号\t密码\na.com\talice\t\"Pw1abc\n" + (0..<50).map { "s\($0).com\tuser\($0)\tSecret\($0)Pw!x" }.joined(separator: "\n")
        let parts = TextShapes.sheetChunks(TextShapes.sheet(delimited: tsv, name: "t", tabs: true))
        let snippet = parts.compactMap { Searcher.sheetSnippet($0, terms: ["user7"]) }.first { $0.contains("user7") } ?? ""
        #expect(snippet.contains("密码：〔密码〕") && !snippet.contains("Secret7"), "\(snippet)")
        #expect(TextShapes.sheet(delimited: "sep=;\na;b\n1;2", name: "e", tabs: false) == "e\na\tb\n1\t2")
    }

    @Test("Excel's cells: an empty one with only a style isn't padded for; a line break inside one doesn't split its row")
    func excelCells() throws {
        let rows = (1...300).map { n in
            "<row r=\"\(n)\"><c r=\"A\(n)\" t=\"inlineStr\"><is><t>a\(n)</t></is></c><c r=\"XFD\(n)\" s=\"1\"/></row>"
        }.joined()
        let second = "<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>备注</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>密码</t></is></c></row>"
            + "<row r=\"2\"><c r=\"A2\" t=\"inlineStr\"><is><t>两行\n的备注</t></is></c><c r=\"B2\" t=\"inlineStr\"><is><t>Pw!2026q</t></is></c></row>"
            + "<row r=\"3\"><c r=\"A3\" t=\"inlineStr\"><is><t>x</t></is></c></row>"
        let data = ZipWriter.make([
            ("xl/workbook.xml", "<workbook xmlns:r=\"r\"><sheets><sheet name=\"一\" r:id=\"rId1\"/><sheet name=\"二\" r:id=\"rId2\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Target=\"worksheets/sheet2.xml\"/></Relationships>"),
            ("xl/worksheets/sheet1.xml", "<worksheet><sheetData>\(rows)</sheetData></worksheet>"),
            ("xl/worksheets/sheet2.xml", "<worksheet><sheetData>\(second)</sheetData></worksheet>"),
        ])
        let sheets = try Office.xlsx(ZipArchive(data: data))
        #expect(sheets.count == 2)
        #expect(sheets.first?.text.split(separator: "\n").count == 301)
        #expect(sheets.last?.text == "二\n备注\t密码\n两行 的备注\tPw!2026q\nx")
        #expect(Searcher.sheetSnippet(try #require(sheets.last?.text), terms: ["两行"]) == "「二」备注：两行 的备注，密码：〔密码〕")
    }

    @Test("A worksheet's cells stay under their columns when Excel leaves an empty one out")
    func cellsInTheirColumns() throws {
        let sheet = """
            <worksheet><sheetData>
            <row r="1"><c r="A1" t="inlineStr"><is><t>网站</t></is></c><c r="B1" t="inlineStr"><is><t>账号</t></is></c><c r="C1" t="inlineStr"><is><t>密码</t></is></c></row>
            <row r="2"><c r="A2" t="inlineStr"><is><t>a.example</t></is></c><c r="C2" t="inlineStr"><is><t>GapPw!2026</t></is></c></row>
            </sheetData></worksheet>
            """
        let data = ZipWriter.make([
            ("xl/workbook.xml", "<workbook xmlns:r=\"r\"><sheets><sheet name=\"常用\" r:id=\"rId1\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/></Relationships>"),
            ("xl/worksheets/sheet1.xml", sheet),
        ])
        let sheets = try Office.xlsx(ZipArchive(data: data))
        #expect(sheets.first?.text == "常用\n网站\t账号\t密码\na.example\t\tGapPw!2026")
        #expect(Searcher.sheetSnippet(try #require(sheets.first?.text), terms: ["a.example"])
                == "「常用」网站：a.example，密码：〔密码〕")
        #expect(Office.column("A1") == 0 && Office.column("c7") == 2 && Office.column("AB12") == 27)
        #expect(Office.column("12") == nil && Office.column("ABCD1") == nil)
    }

    @Test("CSV and TSV are read as tables: quotes, separators, line breaks in a field")
    func delimited() {
        #expect(TextShapes.sheet(delimited: "site,account,password\r\nexample.org,kiwicsv,CsvPassw0rd!x\r\n", name: "s",
                                 tabs: false) == "s\nsite\taccount\tpassword\nexample.org\tkiwicsv\tCsvPassw0rd!x")
        #expect(TextShapes.sheet(delimited: "a,b\n\"x, y\",\"say \"\"hi\"\"\"\n\"two\nlines\",z\n\n", name: "q", tabs: false)
                == "q\na\tb\nx, y\tsay \"hi\"\ntwo lines\tz")
        #expect(TextShapes.sheet(delimited: "名称;金额\n房租;6500", name: "欧", tabs: false) == "欧\n名称\t金额\n房租\t6500")
        #expect(TextShapes.sheet(delimited: "网站\t账号\t密码\nexample.org\tkiwitsv\tTsvPassw0rd!y", name: "t", tabs: true)
                == "t\n网站\t账号\t密码\nexample.org\tkiwitsv\tTsvPassw0rd!y")
        #expect(TextShapes.sheet(delimited: "", name: "空", tabs: false) == "空")
    }
}

extension ReadsPictures {
    // Indexed and searched as the agent does, the review's files.
    struct ReleaseReviewMaskedOutTests {
        @Test("Sheets, CSV and TSV of passwords, and a card's file name, go out masked")
        func throughTheAgent() throws {
            let long = ReleaseReviewSheetTests.rows.map { $0.joined(separator: "\t") }
            let corpus = try ReadsPictures.SecretsOutTests.Corpus([
                "site-accounts.csv": Data("site,account,password\nexample.org,kiwicsv,CsvPassw0rd!x\nshop.test,bob,ShopPw!2026\n".utf8),
                "site-accounts.tsv": Data("网站\t账号\t密码\nexample.org\tkiwitsv\tTsvPassw0rd!y\n".utf8),
                "网站账号.xlsx": ZipWriter.xlsx(sheet: "账号", shared: long.flatMap { $0.split(separator: "\t").map(String.init) },
                                            rows: Self.sharedRows(long)),
                "visa 4111111111111111 12-28.txt": Data("kiwiname1 卡的照片说明\n".utf8),
                "备忘.txt": Data("家里的 WiFi密码88886666 记得改。Visa 卡号 4111 1111 1111 1111 12/28 用于订机票。\n".utf8),
            ])
            for (query, secrets) in [("kiwicsv", ["CsvPassw0rd"]), ("kiwitsv", ["TsvPassw0rd"]), ("kiwirow80", ["RowPw"]),
                                     ("kiwiname1", ["4111111111111111"]), ("WiFi", ["88886666", "4111 1111"])] {
                let answer = try corpus.agentAnswer(query)
                // The path goes out as it is (10-22); everything else mustn't carry the secret.
                let withoutPaths = try Self.withoutPaths(answer)
                for secret in secrets { #expect(!withoutPaths.contains(secret), "\(query): \(secret)") }
                #expect(withoutPaths.contains("〔"), "\(query)")
            }
            let csv = try #require(try Searcher(store: corpus.store).search("kiwicsv").hits.first)
            #expect(csv.snippet == "「site-accounts」site：example.org，account：kiwicsv，password：〔密码〕")
            #expect(csv.why == "表格里的文字对得上")
            #expect(csv.where == nil)
        }

        /// The rows as shared-string references, in order.
        static func sharedRows(_ lines: [String]) -> [[String]] {
            var index = 0
            return lines.map { line in
                line.split(separator: "\t").map { _ in defer { index += 1 }; return "s:\(index)" }
            }
        }

        /// The answer's JSON text with every `path` taken out.
        static func withoutPaths(_ json: String) throws -> String {
            func strip(_ value: Any) -> Any {
                if let object = value as? [String: Any] {
                    return object.filter { $0.key != "path" }.mapValues(strip)
                }
                if let array = value as? [Any] { return array.map(strip) }
                return value
            }
            let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
            return String(decoding: try JSONSerialization.data(withJSONObject: strip(parsed)), as: UTF8.self)
        }
    }
}
