import CoreGraphics
import CoreText
import Foundation

/// A table's thumbnail (`thumb/<item>-w<sheet>`): the first rows of one worksheet of an .xlsx, or of a CSV or TSV,
/// drawn as a grid, the columns' names on top when it has them. Credentials are masked as in a snippet
/// (`Searcher.sheetRows`, then `Secrets.mask`): a password's column whole, a cell after a label, a card number.
enum SheetPicture {
    /// At most this many of a CSV's bytes are read: its first rows are well inside.
    static let csvBytes = 256 << 10
    static let maxColumns = 6
    static let rowHeight = 26.0
    static let padding = 7.0

    /// The picture, `pixels` wide and three quarters of that high; nil when the file can't be read, has no such
    /// worksheet, or has no rows.
    static func draw(_ url: URL, sheet: Int, pixels: Int) -> CGImage? {
        guard let text = try? worksheet(url, sheet: sheet), let table = rows(text) else { return nil }
        return picture(table, width: pixels, height: pixels * 3 / 4)
    }

    /// One worksheet's text as `Office.xlsx` gives it: its name, then rows of tab-separated cells.
    static func worksheet(_ url: URL, sheet: Int) throws -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "xlsx" {
            let sheets = try Office.xlsx(ZipArchive(url: url))
            return sheet >= 1 && sheet <= sheets.count ? sheets[sheet - 1].text : nil
        }
        guard sheet == 1, ext == "csv" || ext == "tsv" else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: csvBytes) ?? Data()
        var text = TextDecoding.decode(data, cut: data.count == csvBytes).text
        // Cut short: its last line may be half a row.
        if data.count == csvBytes, let end = text.lastIndex(of: "\n") { text = String(text[..<end]) }
        return TextShapes.sheet(delimited: text, name: url.deletingPathExtension().lastPathComponent,
                                tabs: ext == "tsv")
    }

    /// The columns' names (if any) and the first rows, as they're shown: masked, at most `maxColumns` across.
    static func rows(_ text: String, count: Int = 10) -> (header: [String]?, rows: [[String]])? {
        guard let sheet = Searcher.sheetRows(text) else { return nil }
        let rows = sheet.shown.prefix(count).map(masked).filter { $0.contains { !$0.isEmpty } }
        guard !rows.isEmpty else { return nil }
        let width = min(maxColumns, max(sheet.header?.count ?? 0, rows.map(\.count).max() ?? 0))
        func fit(_ row: [String]) -> [String] {
            Array((row + Array(repeating: "", count: max(0, width - row.count))).prefix(width))
        }
        return (sheet.header.map { fit(masked($0)) }, rows.map(fit))
    }

    /// A row with what `Secrets.mask` finds masked: over the whole row, so a number split over cells is found too,
    /// cell by cell if a credential spans a cell's edge.
    static func masked(_ row: [String]) -> [String] {
        let whole = Secrets.mask(row.joined(separator: "\t")).components(separatedBy: "\t")
        return whole.count == row.count ? whole : row.map(Secrets.mask)
    }

    static func picture(_ table: (header: [String]?, rows: [[String]]), width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let W = Double(width), H = Double(height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let plain = CTFontCreateUIFontForLanguage(.system, 14, nil)!
        let bold = CTFontCreateUIFontForLanguage(.emphasizedSystem, 14, nil)!
        let lines = (table.header.map { [$0] } ?? []) + table.rows
        let shown = Array(lines.prefix(Int(H / rowHeight) + 1))
        let columns = shown.map(\.count).max() ?? 0
        guard columns > 0 else { return nil }

        // Each column as wide as its widest cell here, within limits; what's left goes to the last.
        var widths = (0..<columns).map { column in
            shown.map { column < $0.count ? measure($0[column], font: plain) : 0 }.max() ?? 0
        }.map { min(max($0 + 2 * padding, 44), 170) }
        let used = widths.reduce(0, +)
        if used < W { widths[columns - 1] += W - used }

        if table.header != nil {
            context.setFillColor(CGColor(srgbRed: 0.95, green: 0.94, blue: 0.92, alpha: 1))
            context.fill(CGRect(x: 0, y: H - rowHeight, width: W, height: rowHeight))
        }
        context.setStrokeColor(CGColor(srgbRed: 0.86, green: 0.84, blue: 0.81, alpha: 1))
        context.setLineWidth(1)
        // The grid goes on below the rows, as a spreadsheet's does.
        for row in stride(from: 1, through: Int(H / rowHeight), by: 1) {
            let y = H - Double(row) * rowHeight
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: W, y: y))
        }
        var x = 0.0
        for width in widths.dropLast() {
            x += width
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: H))
        }
        context.strokePath()

        let ink = CGColor(srgbRed: 0.2, green: 0.16, blue: 0.13, alpha: 1)
        for (index, row) in shown.enumerated() {
            let font = index == 0 && table.header != nil ? bold : plain
            let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
            let baseline = H - Double(index + 1) * rowHeight + (rowHeight - ascent - descent) / 2 + descent
            var x = 0.0
            for (column, cell) in row.enumerated() where column < widths.count {
                defer { x += widths[column] }
                guard !cell.isEmpty else { continue }
                let line = truncated(cell, font: font, color: ink, width: widths[column] - 2 * padding)
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: x + padding, y: baseline)
                CTLineDraw(line, context)
            }
        }
        return context.makeImage()
    }

    static func measure(_ text: String, font: CTFont) -> Double {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: oneLine(text),
                                                                       attributes: [.init(kCTFontAttributeName as String): font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    static func truncated(_ text: String, font: CTFont, color: CGColor, width: Double) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font,
                                                         .init(kCTForegroundColorAttributeName as String): color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: oneLine(text), attributes: attributes))
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        return CTLineCreateTruncatedLine(line, max(1, width), .end, ellipsis) ?? ellipsis
    }

    static func oneLine(_ text: String) -> String {
        String(text.prefix(200)).replacingOccurrences(of: "\n", with: " ")
    }
}
