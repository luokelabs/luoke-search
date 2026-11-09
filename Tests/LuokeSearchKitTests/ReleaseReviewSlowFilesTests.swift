import Foundation
import Testing
@testable import LuokeSearchKit

// The pre-release security review (10-23), should-fix 1–3: files made to keep the reader busy. A title or a
// cell in hundreds of thousands of pieces (XMLParser hands text over in a piece at each `&amp;`), copied or counted
// whole for each piece; a long document parsed again for each step of 40 chunks, every step with 15 minutes of its
// own; a presentation or workbook naming one part over and over, or millions of empty shared strings. The review's
// samples, made here (smaller where the point is the same).
struct ReleaseReviewSlowFilesTests {
    static func seconds(_ work: () throws -> Void) rethrows -> Double {
        let took = try ContinuousClock().measure(work)
        return Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
    }

    /// Text XMLParser hands over in `count` pieces, two characters each.
    static func pieces(_ count: Int) -> String { String(repeating: "标&amp;", count: count) }

    static func slide(_ text: String) -> String {
        "<p:sld xmlns:p=\"p\" xmlns:a=\"a\"><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p:sld>"
    }

    @Test("Should-fix 1: a title in 400 000 pieces is cut at 2000 characters, read in a moment (docx, odt)")
    func titlesInPieces() throws {
        let title = Self.pieces(400_000)
        var docx: (title: String?, text: String)?, odt: (title: String?, text: String)?
        let took = try Self.seconds {
            docx = try Office.docx(ZipArchive(data: ZipWriter.docx(paragraphs: ["正文"], title: title)))
            odt = try Office.odt(ZipArchive(data: ZipWriter.make([
                ("content.xml", "<office:document-content xmlns:office=\"o\" xmlns:text=\"t\"><office:body><office:text>"
                    + "<text:p>正文</text:p></office:text></office:body></office:document-content>"),
                ("meta.xml", "<office:document-meta xmlns:office=\"o\" xmlns:dc=\"d\"><office:meta><dc:title>\(title)"
                    + "</dc:title></office:meta></office:document-meta>"),
            ])))
        }
        #expect(took < 5, "\(took) s")
        for read in [docx, odt] {
            #expect(read?.title?.count == Office.maxTitle)
            #expect(read?.title?.hasPrefix("标&标&") == true)
            #expect(read?.text.contains("正文") == true)
        }
        // A title as titles are: whole, as before.
        let plain = try Office.docx(ZipArchive(data: ZipWriter.docx(paragraphs: ["正文"], title: " 年度 &amp; 总结 ")))
        #expect(plain.title == "年度 & 总结")
        #expect(try Office.docx(ZipArchive(data: ZipWriter.docx(paragraphs: ["正文"]))).title == nil)
    }

    @Test("Should-fix 1: a shared string and a cell in 400 000 pieces are cut at Excel's limit, read in a moment")
    func cellsInPieces() throws {
        let cell = Self.pieces(400_000)
        var sheets: [(sheet: String, text: String)] = []
        let took = try Self.seconds {
            sheets = try Office.xlsx(ZipArchive(data: ZipWriter.xlsx(sheet: "表", shared: [cell], rows: [["s:0"], [cell]])))
        }
        #expect(took < 5, "\(took) s")
        let lines = try #require(sheets.first?.text).split(separator: "\n")
        #expect(lines.map(\.count) == [1, Office.maxCell, Office.maxCell])
        #expect(lines.dropFirst().allSatisfy { $0.hasPrefix("标&标&") })
    }

    @Test("Should-fix 2: a long document's rest is read in one step: parsed twice, not once for each 40 chunks")
    func documentRestAtOnce() throws {
        let scratch = try Scratch()
        let file = try scratch.write("files/长笔记.txt", Drawn.longText() + Drawn.longText(special: "壁虎"))
        let first = Reader.read(file, kind: .doc)
        let chunks = Int(first.info["chunks"] ?? "") ?? 0
        #expect(chunks > 2 * Reader.docStep)
        #expect(first.pieces.count == Reader.docStep && first.readTo == Reader.docStep)
        let rest = Reader.read(file, kind: .doc, from: Reader.docStep + 1)
        #expect(rest.pieces.compactMap(\.loc) == (Reader.docStep + 1...chunks).map { Double($0) })
        #expect(rest.readTo == nil)
        // Indexed: one step for the rest, two reads of the file in all.
        let store = try scratch.store()
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        _ = try indexer.sync([scratch.path + "/files"])
        var reads = 0
        let real = indexer.read
        indexer.read = { item, photos, from in
            reads += 1
            return real(item, photos, from)
        }
        try indexer.readPending()
        #expect(try indexer.readRest() == 1)
        #expect(reads == 2)
        #expect(try store.item(path: file.path)?.state == "done")
        #expect(try Searcher(store: store).search("蝾螈").hits.first?.title == "长笔记.txt")
    }

    @Test("Should-fix 2: a file's steps add up to the total (an hour); each step still has its own limit")
    func stepsAddUp() throws {
        #expect(ReadWatchdog.defaultTotalTimeLimit == 3600 && ReadWatchdog.describe(3600) == "60 minutes")
        let scratch = try Scratch()
        let watchdog = ReadWatchdog(directory: DataDirectory(url: scratch.url), memoryLimit: 1 << 40, timeLimit: 60,
                                    totalLimit: 100)
        var awake: UInt64 = 0
        watchdog.awake = { awake }
        // Its steps before took 70 s (`Indexer` keeps that between them).
        watchdog.begin("/x/书.pdf", before: 70)
        awake = 29_000_000_000
        #expect(watchdog.check() == nil)
        awake = 31_000_000_000
        #expect(watchdog.check()?.why == "reading it took more than 100 seconds in all")
        // Within one begin (filling in vectors): each step's time goes to the total.
        awake = 100_000_000_000
        watchdog.begin("/x/扫描件.pdf", stage: ReadWatchdog.media)
        for _ in 0..<3 {
            awake += 25_000_000_000
            #expect(watchdog.check() == nil)
            watchdog.newStep()
        }
        awake += 26_000_000_000   // 75 s before, 26 s now
        #expect(watchdog.check()?.why == "making its pictures and sound for vectors took more than 100 seconds in all")
        // A file of many pages has more: 5 s a page, up to the 2000 pages read of a PDF (review of this change: a
        // long scanned PDF on a slower Mac).
        #expect(ReadWatchdog.total(3600, pages: 10) == 3600 && ReadWatchdog.total(3600, pages: 1000) == 5000)
        #expect(ReadWatchdog.total(3600, pages: 2000) == 10_000 && ReadWatchdog.total(3600, pages: 99_999) == 10_000)
        watchdog.begin("/x/长扫描件.pdf", before: 60, pages: 22)   // 110 s in all
        awake += 45_000_000_000
        #expect(watchdog.check() == nil)
        awake += 10_000_000_000
        #expect(watchdog.check()?.why == "reading it took more than 110 seconds in all")
        // A step past its own limit, as before.
        watchdog.begin("/x/书.pdf", before: 0)
        awake += 61_000_000_000
        #expect(watchdog.check()?.why == "reading it took more than 60 seconds")
    }

    /// Writes an item's `info` field as given.
    static func setInfo(_ store: IndexStore, _ id: Int64, _ fields: [String: String]) throws {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
        try store.db.query("UPDATE items SET info = ? WHERE id = ?", [.text(text), .int(id)])
    }

    @Test("Should-fix 2: what a long file's steps took is kept between them and goes to the watchdog; past the total, the rest isn't read")
    func stepTimeKept() throws {
        // Kept, added up.
        let half = try ReadsPictures.RobustnessReviewTests.HalfRead()
        let item = try #require(try half.store.item(path: half.file.path))
        let first = try #require(Int(try half.store.info(of: item.id)[Indexer.readTime] ?? ""))
        var awake: UInt64 = 0
        half.indexer.awake = { awake }
        let real = half.indexer.read
        half.indexer.read = { item, photos, from in
            awake += 2_500_000_000
            return real(item, photos, from)
        }
        #expect(try half.indexer.readRest() == 1)
        #expect(try half.store.info(of: item.id)[Indexer.readTime] == String(first + 2500))
        // Handed to the watchdog: 35 s before, 66 s of this step is past a total of 100 s.
        let watched = try ReadsPictures.RobustnessReviewTests.HalfRead()
        let other = try #require(try watched.store.item(path: watched.file.path))
        var fields = try watched.store.info(of: other.id)
        fields[Indexer.readTime] = "35000"
        try Self.setInfo(watched.store, other.id, fields)
        let watchdog = ReadWatchdog(directory: DataDirectory(url: watched.scratch.url.appendingPathComponent("wd")),
                                    memoryLimit: 1 << 40, timeLimit: 90, totalLimit: 100)
        var clock: UInt64 = 0
        watchdog.awake = { clock }
        watched.indexer.watchdog = watchdog
        var stopped: ReadWatchdog.Stopped?
        let realRead = watched.indexer.read
        watched.indexer.read = { item, photos, from in
            clock += 66_000_000_000
            stopped = watchdog.check()
            return realRead(item, photos, from)
        }
        _ = try watched.indexer.readRest()
        #expect(stopped?.why == "reading it took more than 100 seconds in all")
        // All but less than a minute of the total gone (review of this change: the watchdog would end the process a
        // moment into the step), or past it already (read with no watchdog on): given up on without reading; what
        // was read stays. A PDF of 2000 pages isn't: it has 2 hours 47 minutes.
        let past = try ReadsPictures.RobustnessReviewTests.HalfRead()
        let third = try #require(try past.store.item(path: past.file.path))
        var more = try past.store.info(of: third.id)
        more[Indexer.readTime] = "3540001"
        more["pages"] = "2000"
        try Self.setInfo(past.store, third.id, more)
        var longReads = 0
        past.indexer.read = { _, _, _ in
            longReads += 1
            return Reading(outcome: .failed("stop here"))
        }
        _ = try past.indexer.readRest()
        #expect(longReads == 1)
        more["pages"] = nil
        try Self.setInfo(past.store, third.id, more)
        try past.store.db.query("UPDATE items SET state = 'partial', detail = NULL WHERE id = ?", [.int(third.id)])
        var reads = 0
        past.indexer.read = { _, _, _ in
            reads += 1
            return Reading()
        }
        #expect(try past.indexer.readRest() == 0)
        #expect(reads == 0)
        #expect(try past.store.item(path: past.file.path)?.state == "done")
        var detail: String?
        try past.store.db.query("SELECT detail FROM items WHERE id = ?", [.int(third.id)]) { detail = $0.text(0) }
        #expect(detail == "the rest couldn't be read: reading it took more than 59 minutes in all")
        var kept = 0
        try past.store.db.query("SELECT COUNT(*) FROM segments WHERE item = ? AND kind = 'text'", [.int(third.id)]) {
            kept = Int($0.int(0))
        }
        #expect(kept == Reader.docStep)
    }

    @Test("Should-fix 3: a presentation naming one slide 100 000 times reads it once; slides stop at 5000")
    func slidesOnce() throws {
        let ids = String(repeating: "<p:sldId id=\"256\" r:id=\"rId1\"/>", count: 100_000) + "<p:sldId id=\"257\" r:id=\"rId2\"/>"
        let data = ZipWriter.make([
            ("ppt/presentation.xml", "<p:presentation xmlns:p=\"p\" xmlns:r=\"r\"><p:sldIdLst>\(ids)</p:sldIdLst></p:presentation>"),
            ("ppt/_rels/presentation.xml.rels", "<Relationships><Relationship Id=\"rId1\" Target=\"slides/slide1.xml\"/>"
                + "<Relationship Id=\"rId2\" Target=\"slides/slide2.xml\"/></Relationships>"),
            ("ppt/slides/slide1.xml", Self.slide("第一页")),
            ("ppt/slides/slide2.xml", Self.slide("第二页")),
        ])
        let zip = try ZipArchive(data: data)
        let slides = try Office.pptx(zip)
        #expect(slides.map(\.slide) == [1, 2] && slides.map(\.text) == ["第一页", "第二页"])
        #expect(zip.inflated.bytes < 4 << 20)   // each slide inflated once
        // 6000 slides without a word: 5000 of them.
        var entries: [(String, String)] = [], list = "", rels = ""
        for index in 1...6000 {
            list += "<p:sldId id=\"\(255 + index)\" r:id=\"rId\(index)\"/>"
            rels += "<Relationship Id=\"rId\(index)\" Target=\"slides/slide\(index).xml\"/>"
            entries.append(("ppt/slides/slide\(index).xml", Self.slide("")))
        }
        entries.append(("ppt/presentation.xml", "<p:presentation xmlns:p=\"p\" xmlns:r=\"r\"><p:sldIdLst>\(list)</p:sldIdLst></p:presentation>"))
        entries.append(("ppt/_rels/presentation.xml.rels", "<Relationships>\(rels)</Relationships>"))
        let many = try ZipArchive(data: ZipWriter.make(entries))
        #expect(try Office.slideOrder(many).count == Office.maxParts)
        #expect(try Office.pptx(many).count == Office.maxParts)
        // Numbered by their files when there's no list: 5000 too.
        let unlisted = try ZipArchive(data: ZipWriter.make(Array(entries.prefix(6000))))
        #expect(try Office.slideOrder(unlisted).count == Office.maxParts)
    }

    @Test("Should-fix 3: a workbook naming one sheet 100 000 times reads it once")
    func sheetsOnce() throws {
        let sheets = String(repeating: "<sheet name=\"表\" r:id=\"rId1\"/>", count: 100_000)
        let zip = try ZipArchive(data: ZipWriter.make([
            ("xl/workbook.xml", "<workbook xmlns:r=\"r\"><sheets>\(sheets)</sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/></Relationships>"),
            ("xl/worksheets/sheet1.xml", "<worksheet><sheetData><row><c><v>42</v></c></row></sheetData></worksheet>"),
        ]))
        let read = try Office.xlsx(zip)
        #expect(read.count == 1 && read.first?.text == "表\n42")
    }

    @Test("Should-fix 3: what's inflated from one file stops at its total (1 GB); what was read before stays")
    func inflatedInAll() throws {
        #expect(ZipArchive.maxTotalBytes == 1 << 30)
        let filler = String(repeating: "字", count: 300)
        let data = ZipWriter.pptx(slides: [("第一页" + filler, nil), ("第二页" + filler, nil), ("第三页" + filler, nil)])
        // The writer numbers the files the other way round: the first slide is slide3.xml.
        let sizes = try ZipArchive(data: data).entries.mapValues(\.size)
        let first = ["ppt/_rels/presentation.xml.rels", "ppt/presentation.xml", "ppt/slides/slide3.xml", "ppt/slides/slide2.xml"]
        let allowed = first.compactMap { sizes[$0] }.reduce(0, +) + 10
        let zip = try ZipArchive(data: data, totalBytes: allowed)
        let slides = try Office.pptx(zip)
        #expect(slides.map { String($0.text.prefix(3)) } == ["第一页", "第二页"])
        #expect(zip.cut)   // `Reader` writes it down (info "cut")
        #expect(!zip.fits("ppt/slides/slide1.xml"))
        #expect(zip.fits("没有这一项"))
        #expect(throws: ZipArchive.Failure.self) { try zip.read("ppt/slides/slide1.xml") }
        // A file within it reads as always.
        let whole = try ZipArchive(data: data)
        #expect(try Office.pptx(whole).count == 3 && !whole.cut)
    }

    @Test("Review of should-fix 3: a stored entry saying it's smaller than it is isn't read; what's counted is the larger size")
    func sizesAsTheyAre() throws {
        let body = String(repeating: "字", count: 10_000)
        var data = ZipWriter.make([("ppt/slides/slide1.xml", Self.slide(body))])
        // The central directory's entry: its size said to be 1 byte.
        let directory = try #require(ZipArchive.endOfCentralDirectory(in: data)).advanced(by: 16)
        let start = Int(data.le32(directory))
        data.replaceSubrange((start + 24)..<(start + 28), with: ZipWriter.le32(1))
        let zip = try ZipArchive(data: data)
        #expect(zip.entries["ppt/slides/slide1.xml"]?.size == 1)
        #expect(throws: ZipArchive.Failure.self) { try zip.read("ppt/slides/slide1.xml") }
        #expect(zip.inflated.bytes == 0)
        // Deflated data said to inflate to little is counted at what it takes to copy out.
        let entry = ZipArchive.Entry(name: "x", method: 8, compressedSize: 200 << 20, size: 1, localOffset: 0)
        #expect(entry.cost == 200 << 20)
    }

    @Test("Should-fix 3: empty shared strings count; past the total they aren't parsed, and cells pointing there are empty")
    func emptySharedStrings() throws {
        let xml = Data(("<sst>" + String(repeating: "<si/>", count: 5000) + "<si><t>后面</t></si></sst>").utf8)
        let cut = Office.sharedStrings(xml, limit: 1000)
        #expect(cut.count == 1000 && cut.allSatisfy(\.isEmpty))
        let whole = Office.sharedStrings(xml)
        #expect(whole.count == 5001 && whole.last == "后面")
        // A cell pointing past the strings (or at none): empty, not its number.
        let sheets = try Office.xlsx(ZipArchive(data: ZipWriter.xlsx(sheet: "表", shared: ["甲"], rows: [["s:0", "s:7", "3"]])))
        #expect(sheets.first?.text == "表\n甲\t\t3")
    }
}
