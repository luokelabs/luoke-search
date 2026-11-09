import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import LuokeSearchKit

// The pre-release security review (10-23), must-fix 6 and 7: small files that took gigabytes. An ODT of 23 KB
// whose runs of spaces (`<text:s text:c="1000"/>`) were made in full: 800 MB. A PDF of 7.7 KB with one page 595 ×
// 40 000 pt, drawn 1400 px wide for OCR: 1.6 GB at once. The review's samples, made here.
struct ReleaseReviewFilesTests {
    /// The built command line indexing `folder` (no hub, no vectors), timed by /usr/bin/time: its exit code and its
    /// peak memory (bytes): the process's own, not this one's.
    static func indexed(_ folder: String, in scratch: Scratch) throws -> (status: Int32, peak: Int) {
        let executable = try #require(BuiltCommand.url, "luoke-search isn't next to the test bundle")
        let err = scratch.url.appendingPathComponent("time-\(UUID().uuidString.prefix(8)).err")
        FileManager.default.createFile(atPath: err.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/time")
        process.arguments = ["-l", executable.path, "index", folder, "--index", scratch.path + "/data-" + UUID().uuidString,
                             "--no-vectors"]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": scratch.path, "TMPDIR": NSTemporaryDirectory()]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: err)
        try process.run()
        process.waitUntilExit()
        let report = (try? String(contentsOf: err, encoding: .utf8)) ?? ""
        let line = report.split(separator: "\n").first { $0.contains("maximum resident set size") } ?? ""
        let peak = Int(line.split(separator: " ").first ?? "") ?? -1
        return (process.terminationStatus, peak)
    }

    static let reasonable = 300 << 20

    @Test("Must-fix 6: an ODT's runs of spaces are one space each, not hundreds of millions")
    func odtSpaces() throws {
        let scratch = try Scratch()
        let runs = String(repeating: "<text:s text:c=\"1000\"/>", count: 400_000)
        let url = try scratch.write("files/空格.odt", data: ZipWriter.odt(paragraphs: ["前" + runs + "后", "第二段"]))
        let reading = Reader.read(url, kind: .doc)
        #expect(reading.outcome == .done)
        #expect(reading.pieces.map(\.text).joined() == "前 后\n第二段")
        let run = try Self.indexed(scratch.path + "/files", in: scratch)
        #expect(run.status == 0)
        #expect(run.peak > 0 && run.peak < Self.reasonable, "peak \(run.peak >> 20) MB")
    }

    @Test("Must-fix 6: a document's text stops being made once it's past what's kept, and the rest isn't parsed")
    func documentsStopAtTheLimit() throws {
        let paragraph = String(repeating: "长", count: 1000)
        let count = Reader.maxText / 1000 + 200
        let docx = try Office.docx(ZipArchive(data: ZipWriter.docx(paragraphs: Array(repeating: paragraph, count: count) + ["尾巴"])))
        #expect(docx.text.unicodeScalars.count > Reader.maxText)
        #expect(docx.text.unicodeScalars.count < Reader.maxText + 2000)
        #expect(!docx.text.contains("尾巴"))
        let odt = try Office.odt(ZipArchive(data: ZipWriter.odt(paragraphs: Array(repeating: paragraph, count: count) + ["尾巴"])))
        #expect(odt.text.unicodeScalars.count > Reader.maxText && odt.text.unicodeScalars.count < Reader.maxText + 2000)
        #expect(!odt.text.contains("尾巴"))
        // What's read of it is cut where it always was, and says so.
        let scratch = try Scratch()
        let url = try scratch.write("长.docx", data: ZipWriter.docx(paragraphs: Array(repeating: paragraph, count: count)))
        #expect(Reader.read(url, kind: .doc).info["cut"] == "1")
    }

    /// A PDF of empty pages (nothing to read: each is drawn for OCR) of these sizes, in points.
    static func pdf(_ sizes: [CGSize]) -> Data {
        let data = NSMutableData()
        var first = CGRect(origin: .zero, size: sizes[0])
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &first, nil)!
        for size in sizes {
            var box = CGRect(origin: .zero, size: size)
            context.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 20, y: 20, width: 40, height: 40))
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    @Test("Must-fix 7: a page is drawn within 4000 px on its long side; one 20 times longer than wide isn't drawn")
    func pageSizes() throws {
        let document = try #require(PDFDocument(data: Self.pdf([
            CGSize(width: 595, height: 842), CGSize(width: 595, height: 5950), CGSize(width: 595, height: 40_000),
            CGSize(width: 40_000, height: 595), CGSize(width: 1, height: 842),
        ])))
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        try #require(pages.count == 5)
        let a4 = try #require(PDFReading.render(pages[0], pixels: 1400))
        #expect(a4.width == 1400 && a4.height == 1981)   // as before
        let tall = try #require(PDFReading.render(pages[1], pixels: 1400))
        #expect(tall.height == 4000 && tall.width == 400)
        for index in 2...4 {
            let page = pages[index]
            #expect(!PDFReading.drawable(page), "page \(index + 1)")
            #expect(PDFReading.render(page, pixels: 1400) == nil, "page \(index + 1)")
        }
    }

    @Test("Must-fix 7: the review's PDF is read without drawing its page, and says so; memory stays small")
    func tallPDF() throws {
        let scratch = try Scratch()
        let url = try scratch.write("files/长页.pdf", data: Self.pdf([CGSize(width: 595, height: 40_000)]))
        _ = try scratch.write("files/细长但能画.pdf", data: Self.pdf([CGSize(width: 595, height: 11_000)]))
        let reading = Reader.read(url, kind: .pdf)
        #expect(reading.outcome == .done)
        #expect(reading.pieces.count == 1)
        #expect(reading.pieces.first?.vector == nil)   // no picture for luoke-core either
        #expect(reading.info["pages_too_long_to_draw"] == "1")
        #expect(reading.info["scanned_pages"] == nil)
        let run = try Self.indexed(scratch.path + "/files", in: scratch)
        #expect(run.status == 0)
        #expect(run.peak > 0 && run.peak < Self.reasonable, "peak \(run.peak >> 20) MB")
    }

    @Test("Pages too long to draw add up over a long file's steps, as scanned pages do")
    func tooLongAddsUp() throws {
        let half = try ReadsPictures.RobustnessReviewTests.HalfRead()
        let (store, file) = (half.store, half.file)
        let item = try #require(try store.item(path: file.path))
        var first = Reading()
        first.info = ["pages_too_long_to_draw": "1"]
        first.readTo = 45
        #expect(try store.storeMore(first, for: item, from: 41))
        var last = Reading()
        last.info = ["pages_too_long_to_draw": "2"]
        #expect(try store.storeMore(last, for: item, from: 46))
        #expect(try store.info(of: item.id)["pages_too_long_to_draw"] == "3")
    }
}
