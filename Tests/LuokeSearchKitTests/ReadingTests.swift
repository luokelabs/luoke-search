import Foundation
import Testing
@testable import LuokeSearchKit

struct TextDecodingTests {
    @Test func gbkText() {
        let text = "宝宝疫苗安排：麻腮风疫苗第一针定在九月十四日上午。"
        let gbk = text.data(using: TextDecoding.gb18030)!
        #expect(String(data: gbk, encoding: .utf8) == nil)
        let decoded = TextDecoding.decode(gbk)
        #expect(decoded.text == text)
        #expect(decoded.encoding == TextDecoding.gb18030)
    }

    @Test func big5Text() {
        let text = "會議紀要：下週二前完成兩款模型的準確率對比。"
        let decoded = TextDecoding.decode(text.data(using: TextDecoding.big5)!)
        #expect(decoded.text.contains("會議紀要"))
    }

    @Test func latin1StaysLatin() {
        let text = "Café crème, déjà vu — naïve façade"
        let decoded = TextDecoding.decode(text.data(using: .windowsCP1252)!)
        #expect(decoded.text == text)
    }

    @Test func utf16WithAndWithoutMark() {
        let text = "Q3 invoice list 发票"
        var marked = Data([0xFF, 0xFE])
        marked.append(text.data(using: .utf16LittleEndian)!)
        #expect(TextDecoding.decode(marked).text == text)
        #expect(TextDecoding.decode(("plain ascii notes " + text).data(using: .utf16LittleEndian)!).text
            == "plain ascii notes " + text)
    }

    @Test func utf8WithMark() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append("装修预算".data(using: .utf8)!)
        #expect(TextDecoding.decode(data).text == "装修预算")
    }
}

struct DocumentTests {
    @Test func gbkMarkdownIsReadAsChinese() throws {
        let scratch = try Scratch()
        let file = try scratch.write("红烧肉.md", "# 红烧肉\n五花肉切块冷水下锅焯水，小火慢炖一个小时。", encoding: TextDecoding.gb18030)
        let reading = Reader.read(file, kind: .doc)
        #expect(reading.outcome == .done)
        #expect(reading.title == "红烧肉")
        #expect(reading.pieces.first?.text.contains("五花肉") == true)
        #expect(reading.pieces.first?.vector == .text)
    }

    @Test func docx() throws {
        let scratch = try Scratch()
        let file = try scratch.write("合同.docx", data: ZipWriter.docx(paragraphs: ["租赁合同", "押金为两个月租金。"],
                                                                     title: "房屋租赁"))
        let reading = Reader.read(file, kind: .doc)
        #expect(reading.title == "房屋租赁")
        #expect(reading.pieces.map(\.text) == ["租赁合同\n押金为两个月租金。"])
    }

    @Test func odt() throws {
        let scratch = try Scratch()
        let file = try scratch.write("notes.odt", data: ZipWriter.odt(paragraphs: ["First line", "第二行"]))
        #expect(Reader.read(file, kind: .doc).pieces.first?.text == "First line\n第二行")
    }

    @Test func pptxSlidesInOrderWithNotes() throws {
        let scratch = try Scratch()
        let file = try scratch.write("发布会.pptx", data: ZipWriter.pptx(slides: [
            ("输入法发布会", nil), ("功能一览", "内测用户最喜欢联想"), ("价格：团队版每人每月 18 元", nil),
        ]))
        let reading = Reader.read(file, kind: .doc)
        #expect(reading.pieces.map(\.kind) == [.slide, .slide, .slide])
        #expect(reading.pieces.map(\.loc) == [1, 2, 3])
        #expect(reading.pieces[1].text == "功能一览\n内测用户最喜欢联想")   // the notes' slide number line is dropped
        #expect(reading.pieces[2].text.contains("团队版"))
        #expect(reading.info["slides"] == "3")
    }

    @Test func xlsxSharedStringsAndNumbers() throws {
        let scratch = try Scratch()
        let file = try scratch.write("开支.xlsx", data: ZipWriter.xlsx(sheet: "十月", shared: ["房租", "物业费"],
                                                                     rows: [["s:0", "6500"], ["s:1", "320"]]))
        let reading = Reader.read(file, kind: .doc)
        #expect(reading.pieces.count == 1)
        #expect(reading.pieces[0].kind == .sheet)
        #expect(reading.pieces[0].text == "十月\n房租\t6500\n物业费\t320")
    }

    @Test func html() {
        let (title, text) = HTMLText.extract("""
            <html><head><title>成都行程 &amp; 美食</title><style>p { color: red }</style></head>
            <body><script>var x = "不要这段";</script><h1>第一天</h1><p>宽窄巷子&nbsp;→ 人民公园喝茶&#x3002;</p>
            <!-- 注释也不要 --><table><tr><td>午饭</td><td>钟水饺</td></tr></table></body></html>
            """)
        #expect(title == "成都行程 & 美食")
        #expect(text.contains("宽窄巷子 → 人民公园喝茶。"))
        #expect(text.contains("午饭"))
        #expect(!text.contains("不要这段"))
        #expect(!text.contains("注释"))
        #expect(!text.contains("color"))
    }

    @Test func rtf() throws {
        let scratch = try Scratch()
        // Written by the system's own RTF writer, as TextEdit would.
        let source = NSAttributedString(string: "Vaccine plan: 疫苗第一针")
        let data = try source.data(from: NSRange(location: 0, length: source.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let file = try scratch.write("疫苗.rtf", data: data)
        let reading = Reader.read(file, kind: .doc)
        #expect(reading.outcome == .done)
        #expect(reading.pieces.first?.text.contains("Vaccine plan") == true)
        #expect(reading.pieces.first?.text.contains("疫苗") == true)
    }

    @Test func brokenZipFails() throws {
        let scratch = try Scratch()
        let file = try scratch.write("broken.docx", "not a zip at all")
        guard case .failed = Reader.read(file, kind: .doc).outcome else {
            Issue.record("a broken docx should fail")
            return
        }
    }

    @Test func zipEntriesInflate() throws {
        // A real deflated entry: what office suites write.
        let text = String(repeating: "螺壳搜索 deflate test. ", count: 200)
        let raw = try (Data(text.utf8) as NSData).compressed(using: .zlib) as Data
        #expect(try ZipArchive.inflate(raw, size: Data(text.utf8).count) == Data(text.utf8))
    }
}

struct ChunkTests {
    @Test func shortTextIsOneChunk() {
        #expect(TextShapes.chunks("  一段话。 ") == ["一段话。"])
        #expect(TextShapes.chunks("   ").isEmpty)
    }

    @Test func chineseIsCutAfterSentences() {
        let sentence = "这是一句用来测试切块的中文句子，没有空格。"
        let text = String(repeating: sentence, count: 200)
        let chunks = TextShapes.chunks(text)
        #expect(chunks.count > 1)
        for chunk in chunks.dropLast() {
            #expect(chunk.count <= 1800)
            #expect(chunk.hasSuffix("。"))
        }
        // Neighbours overlap, so nothing falls between them.
        #expect(chunks[1].hasPrefix("这是"))
    }

    @Test func numbersOnlyGetNoVector() {
        #expect(!TextShapes.hasWords("2026-01 3200 4500\n2026-02 3100 4700"))
        #expect(TextShapes.hasWords("房租 6500 物业费 320"))
    }
}
