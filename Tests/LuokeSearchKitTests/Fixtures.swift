import Foundation
import Testing
@testable import LuokeSearchKit

/// A throwaway folder for one test, deleted when it goes away. Everything tests read and write is made here, from
/// synthetic content: tests never touch the real home folder or ~/.luoke-search.
final class Scratch {
    let url: URL

    init() throws {
        let made = FileManager.default.temporaryDirectory
            .appendingPathComponent("luoke-search-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        url = URL(fileURLWithPath: Crawler.canonical(made.path))   // spelled as the walk spells it
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var path: String { url.path }

    @discardableResult
    func write(_ relative: String, _ text: String, encoding: String.Encoding = .utf8) throws -> URL {
        try write(relative, data: text.data(using: encoding)!)
    }

    @discardableResult
    func write(_ relative: String, data: Data) throws -> URL {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    /// An index in its own data directory inside the scratch folder.
    func store() throws -> IndexStore {
        try IndexStore(directory: DataDirectory(url: url.appendingPathComponent("data")), home: path)
    }
}

/// The package's folder (this file is in `Tests/LuokeSearchKitTests/`).
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

/// luoke-agent's reference code (`scripts/agent/`), for checking cards and calls as the agent makes them. Left out of
/// the public tree while luoke-agent's own repo isn't public (`scripts/public/export.sh`): nil there, and what needs
/// it is skipped.
let agentScripts: String? = {
    let path = packageRoot.appendingPathComponent("scripts/agent").path
    return FileManager.default.fileExists(atPath: path + "/a2ui.py") ? path : nil
}()

/// Writes zip files with stored (uncompressed) entries, enough to make office documents for tests. The CRC is left
/// zero: the reader doesn't check it.
enum ZipWriter {
    static func make(_ entries: [(String, String)]) -> Data {
        var out = Data(), directory = Data()
        for (name, text) in entries {
            let nameBytes = Data(name.utf8), body = Data(text.utf8)
            let offset = UInt32(out.count)
            out.append(le32(0x0403_4B50)); out.append(le16(20)); out.append(le16(0)); out.append(le16(0))
            out.append(le16(0)); out.append(le16(0)); out.append(le32(0))
            out.append(le32(UInt32(body.count))); out.append(le32(UInt32(body.count)))
            out.append(le16(UInt16(nameBytes.count))); out.append(le16(0))
            out.append(nameBytes); out.append(body)
            directory.append(le32(0x0201_4B50)); directory.append(le16(20)); directory.append(le16(20))
            directory.append(le16(0)); directory.append(le16(0)); directory.append(le16(0)); directory.append(le16(0))
            directory.append(le32(0)); directory.append(le32(UInt32(body.count))); directory.append(le32(UInt32(body.count)))
            directory.append(le16(UInt16(nameBytes.count))); directory.append(le16(0)); directory.append(le16(0))
            directory.append(le16(0)); directory.append(le16(0)); directory.append(le32(0)); directory.append(le32(offset))
            directory.append(nameBytes)
        }
        let start = UInt32(out.count)
        out.append(directory)
        out.append(le32(0x0605_4B50)); out.append(le16(0)); out.append(le16(0))
        out.append(le16(UInt16(entries.count))); out.append(le16(UInt16(entries.count)))
        out.append(le32(UInt32(directory.count))); out.append(le32(start)); out.append(le16(0))
        return out
    }

    static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    static func le32(_ value: UInt32) -> Data { le16(UInt16(value & 0xFFFF)) + le16(UInt16(value >> 16)) }

    static func docx(paragraphs: [String], title: String? = nil) -> Data {
        let body = paragraphs.map { "<w:p><w:r><w:t>\($0)</w:t></w:r></w:p>" }.joined()
        var entries = [("word/document.xml",
                        "<?xml version=\"1.0\"?><w:document xmlns:w=\"w\"><w:body>\(body)</w:body></w:document>")]
        if let title {
            entries.append(("docProps/core.xml",
                            "<cp:coreProperties xmlns:cp=\"c\" xmlns:dc=\"d\"><dc:title>\(title)</dc:title></cp:coreProperties>"))
        }
        return make(entries)
    }

    /// Slides in the order given, though the files are numbered the other way round (the presentation's list wins).
    static func pptx(slides: [(text: String, notes: String?)]) -> Data {
        var entries: [(String, String)] = []
        var ids = "", rels = ""
        for (index, slide) in slides.enumerated() {
            let file = slides.count - index
            ids += "<p:sldId id=\"\(256 + index)\" r:id=\"rId\(index + 1)\"/>"
            rels += "<Relationship Id=\"rId\(index + 1)\" Target=\"slides/slide\(file).xml\"/>"
            entries.append(("ppt/slides/slide\(file).xml",
                            "<p:sld xmlns:p=\"p\" xmlns:a=\"a\"><a:p><a:r><a:t>\(slide.text)</a:t></a:r></a:p></p:sld>"))
            if let notes = slide.notes {
                entries.append(("ppt/slides/_rels/slide\(file).xml.rels",
                                "<Relationships><Relationship Id=\"rId9\" Target=\"../notesSlides/notesSlide\(file).xml\"/></Relationships>"))
                entries.append(("ppt/notesSlides/notesSlide\(file).xml",
                                "<p:notes xmlns:p=\"p\" xmlns:a=\"a\"><a:p><a:r><a:t>\(notes)</a:t></a:r></a:p><a:p><a:r><a:t>\(file)</a:t></a:r></a:p></p:notes>"))
            }
        }
        entries.append(("ppt/presentation.xml",
                        "<p:presentation xmlns:p=\"p\" xmlns:r=\"r\"><p:sldIdLst>\(ids)</p:sldIdLst></p:presentation>"))
        entries.append(("ppt/_rels/presentation.xml.rels", "<Relationships>\(rels)</Relationships>"))
        return make(entries)
    }

    static func xlsx(sheet: String, shared: [String], rows: [[String]]) -> Data {
        let strings = shared.map { "<si><t>\($0)</t></si>" }.joined()
        let rowsXML = rows.map { cells in
            "<row>" + cells.map { cell in
                if cell.hasPrefix("s:") { return "<c t=\"s\"><v>\(cell.dropFirst(2))</v></c>" }
                return "<c><v>\(cell)</v></c>"
            }.joined() + "</row>"
        }.joined()
        return make([
            ("xl/workbook.xml", "<workbook xmlns:r=\"r\"><sheets><sheet name=\"\(sheet)\" r:id=\"rId1\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/></Relationships>"),
            ("xl/sharedStrings.xml", "<sst>\(strings)</sst>"),
            ("xl/worksheets/sheet1.xml", "<worksheet><sheetData>\(rowsXML)</sheetData></worksheet>"),
        ])
    }

    static func odt(paragraphs: [String]) -> Data {
        let body = paragraphs.map { "<text:p>\($0)</text:p>" }.joined()
        return make([("content.xml",
                      "<office:document-content xmlns:office=\"o\" xmlns:text=\"t\"><office:body><office:text>\(body)</office:text></office:body></office:document-content>")])
    }
}

/// Suites that index pictures run one test at a time. Reading is synchronous (OCR with Vision): twenty tests reading
/// at once took every thread of Swift concurrency's pool, and Vision's text recognizer, which waits for work of its
/// own on that pool, never finished. The app and the command line read on threads of their own, never on the pool.
@Suite(.serialized) enum ReadsPictures {}
