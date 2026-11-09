import Foundation

/// Text out of the zip-of-XML office formats: Word (docx), Excel (xlsx), PowerPoint (pptx) and OpenDocument text
/// (odt). Each returns pieces that keep their place: a slide number, a sheet's name.
enum Office {
    // MARK: docx

    static func docx(_ zip: ZipArchive) throws -> (title: String?, text: String) {
        guard let xml = try zip.read("word/document.xml") else { throw ZipArchive.Failure(description: "no document") }
        var text = ""
        var inText = false
        var length = 0   // Unicode scalars so far
        XMLWalker.walk(xml,
                       start: { name, _ in
                           switch name {
                           case "w:t": inText = true
                           case "w:tab": text += "\t"; length += 1
                           case "w:br", "w:cr": text += "\n"; length += 1
                           default: break
                           }
                       },
                       end: { name in
                           if name == "w:t" { inText = false }
                           if name == "w:p" { text += "\n"; length += 1 }
                       },
                       characters: { if inText { text += $0; length += $0.unicodeScalars.count } },
                       until: { length > Reader.maxText })   // past what's kept (pre-release review, must-fix 6)
        return (try coreTitle(zip), text)
    }

    // MARK: odt

    static func odt(_ zip: ZipArchive) throws -> (title: String?, text: String) {
        guard let xml = try zip.read("content.xml") else { throw ZipArchive.Failure(description: "no content") }
        var text = ""
        var length = 0  // Unicode scalars so far
        var depth = 0   // inside office:text
        XMLWalker.walk(xml,
                       start: { name, attributes in
                           if name == "office:text" { depth += 1 }
                           guard depth > 0 else { return }
                           switch name {
                           case "text:tab": text += "\t"; length += 1
                           case "text:line-break": text += "\n"; length += 1
                           case "text:s":
                               // A run of spaces, however many the file says (`text:c`; none if it says none or
                               // less): one stands for it, as the text's runs of spaces are folded into one anyway
                               // (`TextShapes.tidy`). Made as many as it said, a 23 KB file made 400 million and
                               // 800 MB (pre-release review, must-fix 6).
                               if (Int(attributes["text:c"] ?? "1") ?? 1) > 0 {
                                   text += " "
                                   length += 1
                               }
                           default: break
                           }
                       },
                       end: { name in
                           if name == "office:text" { depth -= 1 }
                           if depth > 0, name == "text:p" || name == "text:h" { text += "\n"; length += 1 }
                       },
                       characters: { if depth > 0 { text += $0; length += $0.unicodeScalars.count } },
                       until: { length > Reader.maxText })   // past what's kept (pre-release review, must-fix 6)
        return (try zip.read("meta.xml").flatMap { title($0, element: "dc:title") }, text)
    }

    // MARK: pptx

    /// One piece per slide, in the presentation's order: the slide's text, then its speaker notes.
    static func pptx(_ zip: ZipArchive) throws -> [(slide: Int, text: String)] {
        let order = try slideOrder(zip)
        var slides: [(Int, String)] = []
        var total = 0
        for (index, path) in order.enumerated() {
            // Past what's kept, or what may be inflated from one file: the rest isn't read.
            guard total < Reader.maxText, zip.fits(path) else { break }
            guard let xml = try zip.read(path) else { continue }
            var text = paragraphs(xml, textElement: "a:t", paragraph: "a:p")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let notes = try notesPath(for: path, in: zip), zip.fits(notes), let notesXML = try zip.read(notes) {
                // Notes pages carry the slide's number as a line of their own: not something anyone said.
                let said = paragraphs(notesXML, textElement: "a:t", paragraph: "a:p")
                    .split(separator: "\n").filter { Int($0.trimmingCharacters(in: .whitespaces)) == nil }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !said.isEmpty { text += text.isEmpty ? said : "\n" + said }
            }
            total += max(text.count, 1)   // an empty slide counts too
            slides.append((index + 1, text))
        }
        return slides
    }

    /// At most this many slides or worksheets are read, each once (pre-release review, should-fix 3: a list naming the
    /// same slide over and over had it inflated and parsed each time, and slides without words didn't count).
    static let maxParts = 5000

    /// Slide files in the order the presentation shows them (presentation.xml's list), falling back to their numbers.
    /// Each once, at most `maxParts`.
    static func slideOrder(_ zip: ZipArchive) throws -> [String] {
        let relations = try relationships(zip, "ppt/_rels/presentation.xml.rels", base: "ppt/")
        var ordered: [String] = [], seen = Set<String>()
        if let xml = try zip.read("ppt/presentation.xml") {
            XMLWalker.walk(xml, start: { name, attributes in
                if name == "p:sldId", let id = attributes["r:id"], let path = relations[id], zip.entries[path] != nil,
                   seen.insert(path).inserted {
                    ordered.append(path)
                }
            }, until: { ordered.count >= maxParts })
        }
        if !ordered.isEmpty { return ordered }
        return Array(zip.names.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { number(in: $0) < number(in: $1) }.prefix(maxParts))
    }

    static func notesPath(for slide: String, in zip: ZipArchive) throws -> String? {
        let folder = (slide as NSString).deletingLastPathComponent
        let rels = folder + "/_rels/" + (slide as NSString).lastPathComponent + ".rels"
        return try relationships(zip, rels, base: folder + "/").values.first { $0.contains("notesSlides/") }
    }

    // MARK: xlsx

    /// One piece per worksheet: its name, then its rows, cells separated by tabs. Numbers as stored; dates stay serial
    /// numbers (the text is for finding the sheet, not for reading it).
    /// A cell or shared string is cut here (Excel's own limit for a cell); a workbook's text stops at `Reader.maxText`
    /// (review A-08: a small file whose strings are referenced thousands of times can't make gigabytes of text).
    static let maxCell = 32_767

    static func xlsx(_ zip: ZipArchive) throws -> [(sheet: String, text: String)] {
        let shared = try zip.read("xl/sharedStrings.xml").map { sharedStrings($0) } ?? []
        var total = 0
        let relations = try relationships(zip, "xl/_rels/workbook.xml.rels", base: "xl/")
        var sheets: [(name: String, path: String)] = [], seen = Set<String>()
        if let xml = try zip.read("xl/workbook.xml") {
            // Each once, at most `maxParts` (pre-release review, should-fix 3).
            XMLWalker.walk(xml, start: { name, attributes in
                if name == "sheet", let id = attributes["r:id"], let path = relations[id], seen.insert(path).inserted {
                    sheets.append((attributes["name"] ?? "", path))
                }
            }, until: { sheets.count >= maxParts })
        }
        var out: [(String, String)] = []
        for sheet in sheets {
            // Past what's kept, or what may be inflated from one file: the rest isn't read.
            guard total < Reader.maxText, zip.fits(sheet.path) else { break }
            guard let xml = try zip.read(sheet.path) else { continue }
            var lines: [String] = [], cells: [String] = []
            var cellType = "", value = "", valueLength = 0, inValue = false, column: Int?
            XMLWalker.walk(xml,
                           start: { name, attributes in
                               switch name {
                               case "row": cells = []
                               case "c":
                                   cellType = attributes["t"] ?? "n"
                                   value = ""
                                   valueLength = 0
                                   column = attributes["r"].flatMap(Self.column)
                               case "v", "t": inValue = true
                               default: break
                               }
                           },
                           end: { name in
                               switch name {
                               case "v", "t": inValue = false
                               case "c":
                                   guard total < Reader.maxText else { break }
                                   var cell = value
                                   if cellType == "s" {
                                       // One past the strings kept (or not there at all) is empty, not its number.
                                       cell = Int(value).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? ""
                                   } else if cellType == "b" {
                                       cell = value == "1" ? "TRUE" : "FALSE"
                                   }
                                   // A line break or tab inside a cell would split its row or its cells: a space.
                                   let kept = String(cell.prefix(maxCell)).trimmingCharacters(in: .whitespacesAndNewlines)
                                       .components(separatedBy: CharacterSet(charactersIn: "\t\n\r")).joined(separator: " ")
                                   // Under its own column: Excel leaves empty cells out, and a cell moved left
                                   // would be under another column's name (pre-release review, must-fix 4). An
                                   // empty one that's there (only a style) isn't padded for: the next one is.
                                   if column != nil, kept.isEmpty { break }
                                   while let column, cells.count < column, total < Reader.maxText {
                                       cells.append("")
                                       total += 1
                                   }
                                   total += kept.count + 1
                                   cells.append(kept)
                               case "row":
                                   while cells.last?.isEmpty == true { cells.removeLast() }
                                   if !cells.isEmpty { lines.append(cells.joined(separator: "\t")) }
                                   cells = []
                               default: break
                               }
                           },
                           characters: {
                               // Its length kept count of here: counting the cell each time made a cell in 100 000
                               // pieces (one at each `&amp;`) take minutes (pre-release review, should-fix 1).
                               guard inValue, valueLength < maxCell else { return }
                               value += $0
                               valueLength += $0.count
                           })
            out.append((sheet.name, ([sheet.name] + lines).joined(separator: "\n")))
        }
        return out
    }

    /// A workbook's shared strings, each cut at `maxCell`, until they come to `limit` characters (an empty one counts
    /// one: 50 million `<si/>` were a gigabyte of empty strings, pre-release review, should-fix 3); the rest isn't
    /// parsed, and cells pointing past them are empty.
    static func sharedStrings(_ xml: Data, limit: Int = Reader.maxText) -> [String] {
        var shared: [String] = []
        var total = 0
        var current = "", length = 0, inItem = false, inText = false
        XMLWalker.walk(xml,
                       start: { name, _ in
                           if name == "si" { inItem = true; current = ""; length = 0 }
                           if name == "t" && inItem { inText = true }
                       },
                       end: { name in
                           if name == "t" { inText = false }
                           if name == "si" {
                               inItem = false
                               shared.append(current)
                               total += max(length, 1)
                           }
                       },
                       characters: {
                           guard inText, length < maxCell else { return }
                           let part = $0.prefix(maxCell - length)
                           current += part
                           length += part.count
                       },
                       until: { total >= limit })
        return shared
    }

    /// A cell reference's column, from 0: "A1" 0, "C7" 2, "AB12" 27. Nil if it doesn't start with letters.
    static func column(_ reference: String) -> Int? {
        var column = 0, letters = 0
        for scalar in reference.uppercased().unicodeScalars {
            guard (65...90).contains(scalar.value) else { break }
            column = column * 26 + Int(scalar.value) - 64
            letters += 1
            if letters > 3 { return nil }   // three letters at most (XFD is Excel's last)
        }
        return letters == 0 ? nil : column - 1
    }

    // MARK: Shared

    /// Paragraph text: `textElement` runs joined, a newline after each `paragraph`.
    static func paragraphs(_ xml: Data, textElement: String, paragraph: String) -> String {
        var text = "", inText = false
        XMLWalker.walk(xml,
                       start: { name, _ in if name == textElement { inText = true } },
                       end: { name in
                           if name == textElement { inText = false }
                           if name == paragraph { text += "\n" }
                       },
                       characters: { if inText { text += $0 } })
        return text
    }

    /// A relationships part: id → the target's path inside the zip (relative targets resolved against `base`).
    static func relationships(_ zip: ZipArchive, _ path: String, base: String) throws -> [String: String] {
        guard zip.fits(path), let xml = try zip.read(path) else { return [:] }
        var out: [String: String] = [:]
        XMLWalker.walk(xml, start: { name, attributes in
            guard name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] else { return }
            out[id] = resolve(target, base: base)
        })
        return out
    }

    static func resolve(_ target: String, base: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = base.split(separator: "/").map(String.init)
        for part in target.split(separator: "/") {
            if part == ".." { _ = parts.popLast() } else if part != "." { parts.append(String(part)) }
        }
        return parts.joined(separator: "/")
    }

    static func coreTitle(_ zip: ZipArchive) throws -> String? {
        guard let xml = try zip.read("docProps/core.xml") else { return nil }
        return title(xml, element: "dc:title")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// A title is cut here (characters): longer isn't a title anyone gave.
    static let maxTitle = 2000

    /// The text of `element` (all of them, joined), nil if none; cut at `maxTitle`, and the rest isn't parsed. Added
    /// to in place: XMLParser hands text over in pieces (one at each `&amp;`), and copying the title for each piece
    /// made a title of 100 000 pieces take half a second, one of a few MB the watchdog's 15 minutes (pre-release
    /// review, should-fix 1).
    static func title(_ xml: Data, element: String) -> String? {
        var title: String?, length = 0, inTitle = false
        XMLWalker.walk(xml, start: { name, _ in inTitle = name == element },
                       end: { _ in inTitle = false },
                       characters: {
                           guard inTitle, length < maxTitle else { return }
                           let part = $0.prefix(maxTitle - length)
                           title = title ?? ""
                           title?.append(contentsOf: part)
                           length += part.count
                       },
                       until: { length >= maxTitle })
        return title
    }

    static func number(in path: String) -> Int {
        Int(path.reversed().drop { !$0.isNumber }.prefix { $0.isNumber }.reversed().map(String.init).joined()) ?? 0
    }
}

/// Streams an XML document to closures: element starts (qualified name, attributes), ends, and text.
/// `until`: asked after each; once it's true the rest of the document isn't parsed.
final class XMLWalker: NSObject, XMLParserDelegate {
    private let start: (String, [String: String]) -> Void
    private let end: (String) -> Void
    private let characters: (String) -> Void
    private let until: () -> Bool

    private init(start: @escaping (String, [String: String]) -> Void, end: @escaping (String) -> Void,
                 characters: @escaping (String) -> Void, until: @escaping () -> Bool) {
        self.start = start
        self.end = end
        self.characters = characters
        self.until = until
    }

    static func walk(_ xml: Data, start: @escaping (String, [String: String]) -> Void = { _, _ in },
                     end: @escaping (String) -> Void = { _ in }, characters: @escaping (String) -> Void = { _ in },
                     until: @escaping () -> Bool = { false }) {
        let walker = XMLWalker(start: start, end: end, characters: characters, until: until)
        let parser = XMLParser(data: xml)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = walker
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        start(name, attributes)
        if until() { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        end(name)
        if until() { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        characters(string)
        if until() { parser.abortParsing() }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
