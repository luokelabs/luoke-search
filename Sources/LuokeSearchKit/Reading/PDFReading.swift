import CoreGraphics
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// PDFs, page by page. A page with enough text is searched by its text (and gets a text vector); a page with little
/// or none — a scan, a slide — is drawn and read with OCR: its words go to keyword search, and the page picture is
/// what gets a vector (when luoke-core takes pictures), as a screenshot does.
enum PDFReading {
    /// Below this much text a page counts as a picture. Measured in English-letter equivalents: a Chinese or Japanese
    /// character counts 2.75 (digup: a Chinese contract was taken for a scan when characters counted one each).
    static let minimumPageText = 200.0
    static let renderPixels = 1400
    static let maxPages = 2000

    /// From page `from` (1 is the start): a PDF over `Reader.longPDF` pages is read `Reader.pdfStep` pages at a time.
    static func read(_ url: URL, from: Int = 1) -> Reading {
        guard let document = PDFDocument(url: url) else { return Reading(outcome: .failed("can't open this PDF")) }
        if document.isLocked { return Reading(outcome: .failed("password-protected")) }
        var reading = Reading()
        reading.title = cleanTitle(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
        let count = min(document.pageCount, maxPages)
        let start = max(from - 1, 0)
        let end = from == 1 && count <= Reader.longPDF ? count : min(start + Reader.pdfStep, count)
        if end < count { reading.readTo = end }
        var scanned = 0, tooLong = 0
        for index in start..<max(start, end) {
            autoreleasepool {
                guard let page = document.page(at: index) else { return }
                let text = TextShapes.tidy(page.string ?? "")
                if weightedLength(text) >= minimumPageText, !garbled(text) {
                    reading.pieces.append(Piece(kind: .page, loc: Double(index + 1), text: text,
                                                vector: TextShapes.hasWords(text) ? .text : nil))
                    return
                }
                // Too long and narrow to draw: what text it has, no picture to read or to give a vector.
                guard drawable(page) else {
                    reading.pieces.append(Piece(kind: .page, loc: Double(index + 1), text: text, vector: nil))
                    tooLong += 1
                    return
                }
                // A picture of a page: what's printed on it, read with OCR, and the page's look.
                var words = text
                if let image = render(page, pixels: renderPixels), let read = try? OCR.text(in: image) {
                    words = TextShapes.tidy([text, read].filter { !$0.isEmpty }.joined(separator: "\n"))
                }
                reading.pieces.append(Piece(kind: .page, loc: Double(index + 1), text: words, vector: .media))
                scanned += 1
            }
        }
        reading.info["pages"] = String(document.pageCount)
        if scanned > 0 { reading.info["scanned_pages"] = String(scanned) }
        if tooLong > 0 { reading.info["pages_too_long_to_draw"] = String(tooLong) }
        if document.pageCount > maxPages { reading.info["pages_read"] = String(maxPages) }
        if reading.pieces.isEmpty { reading.outcome = .skipped("no pages") }
        return reading
    }

    /// Text a PDF gives without a way to map its font back to characters: private-use characters, U+FFFD, controls.
    /// Over 30% of them, the page is read as a picture (review A-17).
    static func garbled(_ text: String) -> Bool {
        var visible = 0, bad = 0
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            visible += 1
            let value = scalar.value
            if (0xE000...0xF8FF).contains(value) || value == 0xFFFD || value < 0x20 || (0x7F...0x9F).contains(value) {
                bad += 1
            }
        }
        return visible > 0 && bad * 10 > visible * 3
    }

    /// Characters that aren't spaces, Chinese and Japanese ones counting 2.75 each.
    static func weightedLength(_ text: String) -> Double {
        var length = 0.0
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            length += Script.isUnspaced(scalar) ? 2.75 : 1
        }
        return length
    }

    /// A PDF's own title (only its vectors' document prompt uses it), unless it's a leftover file name ("_tmp.html",
    /// "Microsoft Word - 合同.docx") or a placeholder: then nil, and the prompt says `title: none`, not the file's name
    /// (`IndexStore.textTodos`).
    static func cleanTitle(_ title: String?) -> String? {
        guard var title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        for prefix in ["Microsoft Word - ", "Microsoft PowerPoint - ", "Microsoft Excel - "] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count))
        }
        let ext = (title as NSString).pathExtension.lowercased()
        if ["html", "htm", "doc", "docx", "pdf", "ppt", "pptx", "xls", "xlsx", "txt", "md", "pages", "key", "tmp"]
            .contains(ext) || title.hasPrefix("_") { return nil }
        if ["untitled", "无标题", "未命名", "document"].contains(title.lowercased()) { return nil }
        return title
    }

    /// A page is drawn no larger than this on its long side: drawn 1400 px wide, a page 595 × 40 000 pt (7.7 KB of PDF)
    /// asked for a 1400 × 94 000 bitmap, 1.6 GB, at once (pre-release review, must-fix 7).
    static let maxSide = 4000
    /// A page more than this many times as long as it is wide isn't drawn at all: drawn whole within `maxSide` it'd be
    /// too narrow to read.
    static let maxRatio: CGFloat = 20

    /// Whether a page's shape lets it be drawn (`maxRatio`).
    static func drawable(_ page: PDFPage) -> Bool {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return false }
        return max(box.width, box.height) / min(box.width, box.height) <= maxRatio
    }

    /// The page drawn on white, `pixels` wide, or narrower to keep its long side within `maxSide`; nil if it isn't
    /// `drawable`.
    static func render(_ page: PDFPage, pixels: Int) -> CGImage? {
        guard drawable(page) else { return nil }
        let box = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let (width, height) = rotated ? (box.height, box.width) : (box.width, box.height)
        let scale = min(CGFloat(pixels) / width, CGFloat(maxSide) / max(width, height))
        let size = (max(1, Int(width * scale)), max(1, Int(height * scale)))
        guard let context = CGContext(data: nil, width: size.0, height: size.1, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.0, height: size.1))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// The page as luoke-core gets it (when it takes pictures): a PNG, `renderPixels` wide, budget 280.
    static func pagePicture(_ url: URL, page number: Int) throws -> Data {
        guard let document = PDFDocument(url: url), let page = document.page(at: number - 1),
              let image = render(page, pixels: renderPixels) else { throw Pictures.Failure(description: "no such page") }
        return try Pictures.encode(image, as: .png)
    }
}
