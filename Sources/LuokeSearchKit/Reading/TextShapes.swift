import Foundation

/// Cutting long text into segments, and the little text clean-ups reading needs.
enum TextShapes {
    /// About 1800 characters a chunk, the next one starting 200 characters back, so a sentence cut at the edge is
    /// whole in one of them. Cuts fall after a paragraph, a sentence (。！？.!?) or a space when one is near the
    /// limit, so Chinese without spaces isn't cut mid-sentence. (digup's size: 1800 characters is about 1100 tokens of
    /// Chinese, well inside the embedding model's 2048; smaller chunks didn't do better on its evals.)
    /// Counted in Unicode scalars (4 bytes each), not Swift characters (16): a long file's chunking holds a quarter
    /// of the memory (review A-08).
    static func chunks(_ text: String, size: Int = 1800, overlap: Int = 200) -> [String] {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > size else {
            let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return whole.isEmpty ? [] : [whole]
        }
        var out: [String] = []
        var start = 0
        while start < scalars.count {
            var end = min(start + size, scalars.count)
            if end < scalars.count, let cut = bestCut(scalars, from: start + size / 2, to: end) { end = cut }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[start..<end])
            let piece = String(view).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { out.append(piece) }
            if end >= scalars.count { break }
            var next = max(end - overlap, start + 1)
            // Start the overlap at a sentence's start if there is one in it, else at a word's.
            if let boundary = (next..<end).first(where: { sentenceEnds.contains(scalars[$0 - 1]) || scalars[$0 - 1] == "\n" })
                ?? (next..<end).first(where: { isBoundary(scalars[$0 - 1]) }) {
                next = boundary
            }
            start = next
        }
        return out
    }

    /// A worksheet's text (`Office.xlsx`: its name, then rows of tab-separated cells) in parts of whole rows, cut only
    /// where a row ends ("RowPw046!x" isn't a sentence's end), each starting with the sheet's name and, when its first
    /// row names the columns (more than one cell), that row: every part shows which column a cell is in, a password's
    /// too (pre-release review, must-fix 4). The names are cut to 40 characters each, and left out if they'd still
    /// take a third of a part. A row longer than a part keeps its cells, the long ones cut short (under their columns'
    /// names still), and each long cell's whole text follows in parts of its own, the sheet's name before it — not one
    /// under a password's column, whose text would go out unmasked there.
    static func sheetChunks(_ text: String, size: Int = 1800) -> [String] {
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(lines[0])
        var rows = lines.count > 1 ? lines[1].split(separator: "\n").map(String.init) : []
        var lead = name, columns: [String] = []
        let first = rows.prefix(4).map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        if let at = headerRow(first), rows.count > at + 1 {
            columns = first[at].map { String($0.prefix(40)) }
            let titles = rows[..<at].map { String($0.prefix(80)) }
            let header = columns.joined(separator: "\t")
            rows.removeFirst(at + 1)
            // The titles above the names go with them into every part; a header too wide for that stays a row.
            if (titles + [header]).joined(separator: "\n").unicodeScalars.count <= size / 3 {
                lead += "\n" + (titles + [header]).joined(separator: "\n")
            } else {
                rows.insert(contentsOf: titles + [header], at: 0)
            }
        }
        guard !rows.isEmpty else { return lead.isEmpty ? [] : [lead] }
        let room = max(size - lead.unicodeScalars.count - 1, size / 2)
        var out: [String] = [], part: [String] = [], used = 0
        func close() {
            if !part.isEmpty { out.append(lead + "\n" + part.joined(separator: "\n")) }
            part = []
            used = 0
        }
        func add(_ row: String) {
            let length = row.unicodeScalars.count + 1
            if used + length > room { close() }
            part.append(row)
            used += length
        }
        for row in rows {
            guard row.unicodeScalars.count + 1 > room else {
                add(row)
                continue
            }
            let cells = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let cap = max(20, min(200, room / max(cells.count, 1) - 2))
            let short = cells.map { $0.count > cap ? String($0.prefix(cap)) + "…" : $0 }.joined(separator: "\t")
            if short.unicodeScalars.count + 1 > room {
                // A row of very many cells (a header too wide to repeat): cut as text is, its cells run together.
                close()
                out += chunks(row.replacingOccurrences(of: "\t", with: " "), size: room).map { name + "\n" + $0 }
                continue
            }
            add(short)
            for (index, cell) in cells.enumerated() where cell.count > cap {
                if index < columns.count, Secrets.label(columns[index]) != nil { continue }
                close()
                out += chunks(cell, size: room).map { name + "\n" + $0 }
            }
        }
        close()
        return out
    }

    /// A CSV's or TSV's text as a worksheet's (`Office.xlsx`): `name`, then its rows, cells separated by tabs. A field
    /// in quotes may hold the separator, quotes ("") and line breaks (made spaces), but a quote with no closing one
    /// within the next 4096 characters ends at its line's end: it doesn't take the rest of the file into one cell. A
    /// CSV's separator is Excel's `sep=` first line's, else whichever of "," ";" and tab its first line has most of.
    /// Empty rows are left out.
    static func sheet(delimited text: String, name: String, tabs: Bool) -> String {
        var scalars = Array(text.unicodeScalars)
        var firstLine = scalars.prefix { $0 != "\n" && $0 != "\r" }
        var separator: Unicode.Scalar = tabs ? "\t"
            : [",", ";", "\t"].max { a, b in firstLine.count { $0 == a } < firstLine.count { $0 == b } }!
        if !tabs, firstLine.count == 5, String(String.UnicodeScalarView(firstLine.prefix(4))).lowercased() == "sep=" {
            separator = firstLine.last!
            scalars.removeFirst(min(scalars.count, firstLine.count + 1))
            firstLine = []
        }
        var closing = -1   // where the field in quotes closes, once found: not looked for again
        func closes(after index: Int) -> Bool {   // a closing quote ahead, near enough
            if index < closing { return true }
            var at = index
            while at < min(scalars.count, index + 4096) {
                if scalars[at] == "\"" {
                    if at + 1 < scalars.count, scalars[at + 1] == "\"" { at += 2; continue }
                    guard at + 1 == scalars.count || [separator, "\n", "\r"].contains(scalars[at + 1]) else { return false }
                    closing = at
                    return true
                }
                at += 1
            }
            return false
        }
        var lines = [name], cells: [String] = [], field = String.UnicodeScalarView()
        var quoted = false, index = 0
        func endField() {
            cells.append(String(field).trimmingCharacters(in: .whitespaces))
            field = String.UnicodeScalarView()
        }
        func endRow() {
            endField()
            while cells.last?.isEmpty == true { cells.removeLast() }
            if !cells.isEmpty { lines.append(cells.joined(separator: "\t")) }
            cells = []
        }
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if quoted {
                if scalar == "\"" {
                    if index < scalars.count, scalars[index] == "\"" {   // "" inside quotes: a quote
                        field.append(scalar)
                        index += 1
                    } else {
                        quoted = false
                    }
                    continue
                }
                if scalar == "\n" || scalar == "\r" {
                    if closes(after: index) {
                        field.append(" ")
                        continue
                    }
                    quoted = false   // never closed: the line ends here, as if it had been
                } else {
                    field.append(scalar == "\t" ? " " : scalar)
                    continue
                }
            }
            switch scalar {
            case "\"" where String(field).trimmingCharacters(in: .whitespaces).isEmpty: quoted = true; field = .init()
            case separator: endField()
            case "\r":
                if index < scalars.count, scalars[index] == "\n" { index += 1 }
                endRow()
            case "\n": endRow()
            case "\t": field.append(" ")
            default: field.append(scalar)
            }
        }
        if quoted || !field.isEmpty || !cells.isEmpty { endRow() }
        return lines.joined(separator: "\n")
    }

    /// Which of a sheet's first rows (its cells) names the columns, if one does. The first row of more than one cell,
    /// after at most two of one cell (titles), if it's all names (no digits or signs: "网站 | 账号 | 密码", "项目 |
    /// 内容"); else, among the first four, the first of names that names a credential's column (under a title of two
    /// cells, "导出时间 | 2026-10-23"); else that first row still, unless it looks like a row of the table (a password
    /// in it, or nothing but values: "user01 | site01.example"). Empty rows are gone already (`Office.xlsx`, `sheet(delimited:)`). Titles above the names were taken
    /// for the table's first rows, and its password column went unmasked (10-23).
    static func headerRow(_ rows: [[String]]) -> Int? {
        let filled = rows.prefix(4).map { $0.filter { !$0.isEmpty } }
        let names = { (row: Int) in filled[row].count > 1 && !filled[row].contains(where: Secrets.valueLike) }
        guard let first = filled.indices.first(where: { filled[$0].count > 1 }) else { return nil }
        if first <= 2, names(first) { return first }
        if let named = filled.indices.first(where: { names($0) && filled[$0].contains { Secrets.label($0) != nil } }) {
            return named
        }
        return first <= 2 && !filled[first].contains(where: { Secrets.passwordLike($0) })
            && !filled[first].allSatisfy(Secrets.valueLike) ? first : nil
    }

    static let sentenceEnds = Set("。！？；.!?;".unicodeScalars)
    static let pauses = Set("，、,".unicodeScalars)

    /// The last good place to cut in lo..<hi: after a newline, else after a sentence end, else after a space.
    static func bestCut(_ scalars: [Unicode.Scalar], from lo: Int, to hi: Int) -> Int? {
        for test in [{ (s: Unicode.Scalar) in s == "\n" },
                     { (s: Unicode.Scalar) in sentenceEnds.contains(s) },
                     { (s: Unicode.Scalar) in s.properties.isWhitespace || pauses.contains(s) }] {
            if let index = (lo..<hi).last(where: { test(scalars[$0]) }) { return index + 1 }
        }
        return nil
    }

    static func isBoundary(_ s: Unicode.Scalar) -> Bool {
        s.properties.isWhitespace || sentenceEnds.contains(s) || pauses.contains(s)
    }

    /// Whether a piece of text has words worth a vector: at least a fifth of its non-space characters are letters
    /// (tables of numbers and data exports are only searched by their words).
    static func hasWords(_ text: String) -> Bool {
        var letters = 0, visible = 0
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            visible += 1
            if CharacterSet.letters.contains(scalar) { letters += 1 }
        }
        return visible > 0 && letters * 5 >= visible
    }

    /// Runs of spaces and blank lines folded, ends trimmed.
    static func tidy(_ text: String) -> String {
        var lines: [String] = []
        var blank = false
        for line in text.components(separatedBy: .newlines) {
            let folded = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" })
                .joined(separator: " ")
            if folded.isEmpty {
                if !blank && !lines.isEmpty { lines.append("") }
                blank = true
            } else {
                lines.append(folded)
                blank = false
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Text out of HTML without a web view (WebKit's importer must run on the main thread and loads resources): tags,
/// scripts, styles and comments dropped, block ends turned into newlines, entities decoded.
enum HTMLText {
    static func extract(_ html: String) -> (title: String?, text: String) {
        var title: String?
        if let range = html.range(of: #"(?s)<title[^>]*>(.*?)</title>"#,
                                  options: [.regularExpression, .caseInsensitive]) {
            let inner = html[range].replacingOccurrences(of: #"</?title[^>]*>"#, with: "",
                                                         options: [.regularExpression, .caseInsensitive])
            title = decodeEntities(inner).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        var text = html
        for pattern in [#"(?s)<!--.*?-->"#, #"(?s)<script\b.*?</script\s*>"#, #"(?s)<style\b.*?</style\s*>"#,
                        #"(?s)<head\b.*?</head\s*>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ",
                                             options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(
            of: #"<(br|/p|/div|/li|/tr|/h[1-6]|/table|/section|/article|/blockquote|/pre)\b[^>]*>"#, with: "\n",
            options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</t[dh]\s*>"#, with: "\t", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return (title, TextShapes.tidy(decodeEntities(text)))
    }

    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "mdash": "—", "ndash": "–",
        "hellip": "…", "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’", "middot": "·", "copy": "©",
        "reg": "®", "yen": "¥", "euro": "€", "times": "×",
    ]

    static func decodeEntities(_ text: some StringProtocol) -> String {
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[amp...]
            if let semi = after.prefix(12).firstIndex(of: ";") {
                let name = after[after.index(after: amp)..<semi]
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X"), let value = UInt32(name.dropFirst(2), radix: 16) {
                    replacement = Unicode.Scalar(value).map { String(Character($0)) }
                } else if name.hasPrefix("#"), let value = UInt32(name.dropFirst()) {
                    replacement = Unicode.Scalar(value).map { String(Character($0)) }
                } else {
                    replacement = named[String(name)]
                }
                if let replacement {
                    out += replacement
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = after.dropFirst()
        }
        return out + rest
    }
}
