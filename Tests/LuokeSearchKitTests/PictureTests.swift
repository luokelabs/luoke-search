import AppKit
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LuokeSearchKit

/// Synthetic pictures and PDFs, drawn here: text set in the system's fonts, so OCR has something real to read.
enum Drawn {
    /// Black text on white, `width` × `height` pixels.
    static func picture(_ lines: [String], width: Int = 1200, height: Int = 600, size: CGFloat = 44) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(lines, in: context, top: CGFloat(height) - 80, size: size)
        return context.makeImage()!
    }

    static func draw(_ lines: [String], in context: CGContext, top: CGFloat, size: CGFloat) {
        let font = CTFontCreateWithName("PingFang SC" as CFString, size, nil)
        for (index, line) in lines.enumerated() {
            let text = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor.black])
            context.textPosition = CGPoint(x: 40, y: top - CGFloat(index) * size * 1.6)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
    }

    static func png(_ image: CGImage) throws -> Data { try Pictures.encode(image, as: .png) }

    /// A JPEG with an EXIF capture time.
    static func photo(taken: String, offset: String) throws -> Data {
        let image = picture(["一张照片"], width: 800, height: 600)
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: taken,
                                     "OffsetTimeOriginal" as CFString: offset]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A PDF: one page of real text, and one that is only a picture of text (a scan). `password` locks it.
    static func pdf(textPage: [String], scannedPage: [String], password: String? = nil) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        var info: [CFString: Any] = [kCGPDFContextTitle: "Microsoft Word - 合同.docx"]
        if let password {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password
        }
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, info as CFDictionary)!
        context.beginPDFPage(nil)
        draw(textPage, in: context, top: 780, size: 14)
        context.endPDFPage()
        context.beginPDFPage(nil)
        context.draw(picture(scannedPage, width: 1190, height: 1684, size: 48), in: box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

extension ReadsPictures {
    struct PictureTests {
        @Test func screenshotTextIsReadButGetsNoTextVector() throws {
            let scratch = try Scratch()
            let file = try scratch.write("Screenshot 2026-10-11 at 15.12.08.png",
                                         data: Drawn.png(Drawn.picture(["付款失败：余额不足", "错误代码 E1024"])))
            let reading = Reader.read(file, kind: .screenshot)
            #expect(reading.outcome == .done)
            let ocr = try #require(reading.pieces.first { $0.kind == .ocr })
            #expect(ocr.text.contains("余额不足"))
            #expect(ocr.text.contains("E1024"))
            #expect(ocr.vector == nil)
            #expect(reading.pieces.last?.kind == .image)
            #expect(reading.pieces.last?.vector == .media)
            #expect(reading.info["width"] == "1200")
        }

        @Test func photoTakenTimeAndSize() throws {
            let scratch = try Scratch()
            let file = try scratch.write("IMG_2001.jpg", data: Drawn.photo(taken: "2026:09:14 10:02:00", offset: "+08:00"))
            let reading = Reader.read(file, kind: .image)
            #expect(reading.taken == 1_789_351_320)   // 2026-09-14 02:02:00 UTC
            #expect(reading.pieces.map(\.kind) == [.image])
            #expect(!reading.pieces.contains { $0.kind == .ocr })   // photos aren't read for text
        }

        @Test func iconsAreSkipped() throws {
            let scratch = try Scratch()
            let file = try scratch.write("icon.png", data: Drawn.png(Drawn.picture(["x"], width: 128, height: 128)))
            #expect(Reader.read(file, kind: .image).outcome == .skipped("small image"))
        }

        @Test func pdfTextPagesAndScannedPages() throws {
            let scratch = try Scratch()
            let lines = (1...12).map { "第\($0)条 租赁合同条款：押金为两个月租金，于签约时一次付清，期满退还。" }
            let file = try scratch.write("合同.pdf", data: Drawn.pdf(textPage: lines,
                                                                    scannedPage: ["山野咖啡", "燕麦拿铁 x1 ¥32.00"]))
            let reading = Reader.read(file, kind: .pdf)
            #expect(reading.outcome == .done)
            #expect(reading.title == nil)   // "Microsoft Word - 合同.docx" is a leftover file name
            #expect(reading.info["pages"] == "2")
            #expect(reading.info["scanned_pages"] == "1")
            #expect(reading.pieces.map(\.kind) == [.page, .page])
            #expect(reading.pieces[0].vector == .text)
            #expect(reading.pieces[0].text.contains("押金为两个月租金"))
            #expect(reading.pieces[1].vector == .media)    // a scan: its look gets the vector
            #expect(reading.pieces[1].text.contains("燕麦拿铁"))   // and its words come from OCR
        }

        @Test func lockedPDFFails() throws {
            let scratch = try Scratch()
            let file = try scratch.write("locked.pdf", data: Drawn.pdf(textPage: ["secret"], scannedPage: ["x"],
                                                                        password: "pw"))
            #expect(Reader.read(file, kind: .pdf).outcome == .failed("password-protected"))
        }

        @Test func pdfTitles() {
            #expect(PDFReading.cleanTitle("_tmp.html") == nil)
            #expect(PDFReading.cleanTitle("Microsoft Word - 年度报告.docx") == nil)
            #expect(PDFReading.cleanTitle("Microsoft Word - 年度报告") == "年度报告")
            #expect(PDFReading.cleanTitle("Untitled") == nil)
            #expect(PDFReading.cleanTitle("  房屋租赁合同 ") == "房屋租赁合同")
            #expect(PDFReading.weightedLength("押金 ab") == 2 * 2.75 + 2)
        }

        @Test func chineseIsReadFirst() {
            #expect(OCR.languages.prefix(2) == ["zh-Hans", "zh-Hant"])
            #expect(OCR.languages.contains("en-US"))
        }

        /// The checked-in synthetic corpus: the scanned receipt and the lease, end to end through the index.
        @Test func corpusScanAndContract() throws {
            let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("testbed/zh/corpus/pdf")
            let scratch = try Scratch()
            let store = try scratch.store()
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([corpus.path])
            try indexer.readPending()
            let searcher = Searcher(store: store)
            let receipt = try #require(try searcher.search("燕麦拿铁").hits.first)
            #expect(receipt.title == "扫描件_20260914.pdf")
            #expect(receipt.where == Location(page: 1))
            let lease = try #require(try searcher.search("静安区").hits.first)
            #expect(lease.title == "租赁合同.pdf")
            #expect(lease.id.hasSuffix("#p1"))
            let pet = try #require(try searcher.search("饲养犬类").hits.first)
            #expect(pet.where == Location(page: 2))
        }

        /// The scanned receipt with Chinese and English on every line (scripts/testbed/make_receipt.swift).
        @Test func mixedReceipt() throws {
            let receipts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("testbed/zh/receipts")
            let scratch = try Scratch()
            let store = try scratch.store()
            let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
            _ = try indexer.sync([receipts.path])
            try indexer.readPending()
            let searcher = Searcher(store: store)
            for query in ["cold brew", "会员折扣", "Butter Croissant", "支付宝"] {
                #expect(try searcher.search(query).hits.first?.where == Location(page: 1), "\(query)")
            }
            // The name holds all three words, the page two: the result still points at the page.
            let named = try #require(try searcher.search("港湾咖啡的小票").hits.first)
            #expect(named.where == Location(page: 1))
            #expect(named.why == "名字和第 1 页的文字都对得上")
            #expect(named.snippet?.contains("HARBOR COFFEE 港湾咖啡") == true)
        }
    }
}
