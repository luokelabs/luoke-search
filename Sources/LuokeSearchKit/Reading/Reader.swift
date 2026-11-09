import AppKit
import Foundation

/// What a segment is: where in its item it sits, and so how a result pointing at it is described.
public enum SegmentKind: String, Codable, Sendable {
    /// The item's name and folders. Every item has one; found by keyword only.
    case name
    /// A chunk of a document's text (`loc`: its number, from 1).
    case text
    /// A slide of a presentation (`loc`: slide number), with its speaker notes.
    case slide
    /// A worksheet (`loc`: its number, from 1), or a part of a long one.
    case sheet
    /// A page of a PDF (`loc`: page number).
    case page
    /// Text recognized in a picture (a screenshot, a scanned page).
    case ocr
    /// A picture's look (its vector); a video frame (`loc`: second).
    case image, frame
    /// A stretch of sound (`loc`…`locEnd`: seconds).
    case audio
}

/// What a segment is waiting for from luoke-core.
public enum Pending: String, Sendable {
    /// A text vector: made from the segment's text and the item's title.
    case text
    /// A picture or sound vector: the file is read again when luoke-core takes pictures and sound.
    case media
}

/// One segment as reading makes it.
public struct Piece: Sendable {
    public var kind: SegmentKind
    public var loc: Double?
    public var locEnd: Double?
    /// The words keyword search sees (may be empty for a picture or a sound).
    public var text: String
    /// What vector it should get, or nil for none.
    public var vector: Pending?

    public init(kind: SegmentKind, loc: Double? = nil, locEnd: Double? = nil, text: String, vector: Pending? = nil) {
        self.kind = kind
        self.loc = loc
        self.locEnd = locEnd
        self.text = text
        self.vector = vector
    }
}

/// What reading one item gave.
public struct Reading: Sendable {
    public enum Outcome: Sendable, Equatable {
        case done
        case failed(String)
        case skipped(String)
    }

    public var outcome: Outcome = .done
    public var title: String?
    public var pieces: [Piece] = []
    /// A long file read only up to here (a page, or a chunk of a document): the rest is read later, a step at a time,
    /// once every file has been read through once (`Indexer.readRest`). Nil: read whole.
    public var readTo: Int?
    /// When it was made, if the file says (a photo's capture time); else the item's time is its modification date.
    public var taken: Double?
    public var info: [String: String] = [:]
}

/// Reads files into pieces. Reading never needs luoke-core: it only marks which pieces want vectors.
public enum Reader {
    /// The reading code's version for each kind. Items read by an older version are read again (`IndexStore`), so a
    /// better reader reaches existing indexes without a rebuild. 0: only the name is indexed so far. Documents 2:
    /// worksheets cut at rows, CSV and TSV read as tables (pre-release review, must-fix 4); 3: a sheet's titles above
    /// its columns' names (10-23).
    public static let versions: [ItemKind: Int] = [
        .doc: 3, .pdf: 1, .screenshot: 1, .image: 1, .video: 1, .audio: 1, .photo: 1,
    ]

    public static let maxTextBytes = 32 << 20
    public static let maxChunks = 2000
    /// A file's text is cut here (characters): no more than `maxChunks` chunks of it are kept anyway (review A-08).
    public static let maxText = 4_000_000
    /// Pictures smaller than this on their long side are icons and decorations, not something anyone looks for.
    public static let smallestPicture = 256
    /// Screenshots are read with OCR at their own size, up to this.
    static let ocrPixels = 3000

    /// A PDF of more than 50 pages is read 30 pages at a time; a document of more than 40 chunks, its first 40, then
    /// the rest at once: the first step with the first pass, the rest after it (`from`: the page or chunk to go on
    /// from). A document is parsed whole for any of its chunks, so 40 a step parsed the longest 50 times (pre-release
    /// review, should-fix 2).
    public static let longPDF = 50
    public static let pdfStep = 30
    public static let docStep = 40

    public static func read(_ url: URL, kind: ItemKind, from: Int = 1) -> Reading {
        switch kind {
        case .doc:
            do { return try document(url, from: from) } catch { return Reading(outcome: .failed(describe(error))) }
        case .pdf:
            return PDFReading.read(url, from: from)
        case .screenshot, .image:
            return picture(url, screenshot: kind == .screenshot)
        case .audio:
            return MediaReading.audio(url)
        case .video:
            return MediaReading.video(url)
        case .photo:
            // The Photos library comes in a later block (PhotoKit).
            return Reading()
        }
    }

    static func describe(_ error: Error) -> String {
        if let failure = error as? ZipArchive.Failure { return failure.description }
        if let failure = error as? Pictures.Failure { return failure.description }
        return (error as NSError).localizedDescription
    }

    // MARK: Pictures

    /// A picture's look is what gets a vector (when luoke-core takes pictures). A screenshot's text is read with OCR
    /// and searched by its words only: given a vector too, screenshots crowded out better results (upstream DigUp
    /// tried it on 2026-10-08 and took it out).
    static func picture(_ url: URL, screenshot: Bool) -> Reading {
        guard let info = Pictures.info(url), info.width > 0, info.height > 0 else {
            return Reading(outcome: .failed("can't open this picture"))
        }
        var reading = Reading()
        reading.info["width"] = String(info.width)
        reading.info["height"] = String(info.height)
        reading.taken = info.taken
        if max(info.width, info.height) < smallestPicture {
            return Reading(outcome: .skipped("small image"), info: reading.info)
        }
        if screenshot {
            do {
                let image = try Pictures.image(url, maxPixels: ocrSize(width: info.width, height: info.height))
                let text = TextShapes.tidy(try OCR.text(in: image))
                if !text.isEmpty { reading.pieces.append(Piece(kind: .ocr, text: text)) }
            } catch {
                reading.info["ocr"] = describe(error)
            }
        }
        reading.pieces.append(Piece(kind: .image, text: "", vector: .media))
        return reading
    }

    /// The long side a screenshot is read with OCR at: its own size up to `ocrPixels`, except that the short side
    /// isn't shrunk below 1000 px (a scrolling screenshot 1440 × 12000 would come out 360 px wide: review A-16), up
    /// to 16 000 px.
    static func ocrSize(width: Int, height: Int) -> Int {
        let long = max(width, height), short = max(min(width, height), 1)
        let size = min(long, ocrPixels)
        guard short * size / long < 1000 else { return size }
        return min(long, 1000 * long / short, 16_000)
    }

    // MARK: Documents

    static func document(_ url: URL, from: Int = 1) throws -> Reading {
        let ext = url.pathExtension.lowercased()
        var reading = Reading()
        switch ext {
        case "xlsx":
            let zip = try ZipArchive(url: url)
            let sheets = try Office.xlsx(zip)
            for (index, sheet) in sheets.enumerated() where reading.pieces.count < maxChunks {
                for part in TextShapes.sheetChunks(sheet.text).prefix(maxChunks - reading.pieces.count) {
                    reading.pieces.append(Piece(kind: .sheet, loc: Double(index + 1), text: part,
                                                vector: TextShapes.hasWords(part) ? .text : nil))
                }
            }
            reading.info["sheets"] = String(sheets.count)
            if zip.cut { reading.info["cut"] = "1" }
        case "pptx":
            let zip = try ZipArchive(url: url)
            let slides = try Office.pptx(zip)
            for slide in slides where reading.pieces.count < maxChunks {
                let text = TextShapes.tidy(slide.text)
                guard !text.isEmpty else { continue }
                for part in TextShapes.chunks(text).prefix(maxChunks - reading.pieces.count) {
                    reading.pieces.append(Piece(kind: .slide, loc: Double(slide.slide), text: part,
                                                vector: TextShapes.hasWords(part) ? .text : nil))
                }
            }
            reading.info["slides"] = String(slides.count)
            if zip.cut { reading.info["cut"] = "1" }
        default:
            let (title, whole) = try documentText(url, ext: ext)
            reading.title = title
            var text = whole
            if text.unicodeScalars.count > maxText {
                text = String(String.UnicodeScalarView(text.unicodeScalars.prefix(maxText)))
                reading.info["cut"] = "1"
            }
            // A CSV or TSV is a table, read as a worksheet is: whole rows, every part under the columns' names
            // (pre-release review, must-fix 4). Its parts have no place to point to (a worksheet's is which sheet).
            let table = ext == "csv" || ext == "tsv"
            let name = url.deletingPathExtension().lastPathComponent
            // Long: the first 40 chunks now, the rest in one step after every file has been read once.
            let chunks = Array((table ? TextShapes.sheetChunks(TextShapes.sheet(delimited: text, name: name, tabs: ext == "tsv"))
                                      : TextShapes.chunks(TextShapes.tidy(text))).prefix(maxChunks))
            let start = max(from - 1, 0)
            let end = from == 1 ? min(docStep, chunks.count) : chunks.count
            for index in start..<max(start, end) {
                reading.pieces.append(Piece(kind: table ? .sheet : .text, loc: table ? nil : Double(index + 1),
                                            text: chunks[index], vector: TextShapes.hasWords(chunks[index]) ? .text : nil))
            }
            if end < chunks.count { reading.readTo = end }
            reading.info["chunks"] = String(chunks.count)
        }
        if reading.pieces.isEmpty { reading.info["empty"] = "1" }
        return reading
    }

    static func documentText(_ url: URL, ext: String) throws -> (title: String?, text: String) {
        switch ext {
        case "docx":
            return try Office.docx(ZipArchive(url: url))
        case "odt":
            return try Office.odt(ZipArchive(url: url))
        case "rtf", "doc":
            let type: NSAttributedString.DocumentType = ext == "rtf" ? .rtf : .docFormat
            let text = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
            return (nil, text)
        case "html", "htm":
            return HTMLText.extract(try plainText(url))
        case "md", "markdown":
            let text = try plainText(url)
            return (markdownTitle(text), text)
        default:   // txt, text, csv, tsv
            return (nil, try plainText(url))
        }
    }

    /// A text file's text in whatever encoding it was saved in (`TextDecoding`), up to `maxTextBytes`.
    static func plainText(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxTextBytes) ?? Data()
        return TextDecoding.decode(data, cut: data.count == maxTextBytes).text
    }

    /// The first level-one heading ("# Title"), if the document starts with one within its first lines.
    static func markdownTitle(_ text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(5) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") { return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }
}
