import Foundation
import Testing
@testable import LuokeSearchKit

// Keyword search finds a word however it was typed or extracted (`Script.normalized`, as luoke's internal DigUp fork
// does; 11-02): a soft hyphen or zero-width joiner inside it, Arabic with or without tatweel and harakat, any alef;
// Persian's yeh and kaf as Arabic's, and the alef maksura as yeh (11-03, which the fork doesn't).
// Synthetic text only; no luoke-core (keyword search alone).

struct NormalizeTests {
    @Test("normalized: NFKC, invisible formatting dropped, Arabic as typed, one yeh and kaf; Bengali signs, Chinese and accents kept")
    func normalized() {
        let cases: [(String, String)] = [
            ("ＰＤＦ", "PDF"),                                   // full-width (NFKC, as before)
            ("\u{FEFB}", "\u{0644}\u{0627}"),                  // the lam-alef ligature: lam, alef
            ("infor\u{00AD}mation", "information"),           // soft hyphen
            ("কুমি\u{200D}র", "কুমির"),                           // zero-width joiner
            ("র\u{200C}্যাব", "র্যাব"),                            // zero-width non-joiner
            ("\u{200F}مرحبا\u{200E}", "مرحبا"),                  // direction marks
            ("\u{202B}نص\u{202C}", "نص"),                        // embedding and its end
            ("\u{2066}x\u{2069}", "x"),                         // an isolate
            ("\u{FEFF}标题", "标题"),                             // BOM
            ("词\u{2060}语", "词语"),                              // word joiner
            ("hello\u{200B}world", "hello world"),            // zero-width space: a word break
            ("会\u{200B}议纪要", "会议纪要"), ("สวัสดี\u{200B}ครับ", "สวัสดีครับ"),   // … but not between Chinese, Thai
            ("中文\u{200B}word", "中文 word"),
            ("کتاب\u{200C}ها", "كتابها"),                        // Persian's non-joiner: one word
            ("a\u{200D}\u{0301}", "\u{00E1}"),                   // composed again once the joiner is gone
            ("كـتـاب", "كتاب"),                                  // tatweel
            ("كِتَابٌ", "كتاب"),                                    // harakat
            ("هٰذا", "هذا"),                                     // the dagger alef
            ("أحمد", "احمد"), ("إسلام", "اسلام"), ("آمن", "امن"), ("ٱلله", "الله"),   // one alef
            ("یک", "يك"), ("خیلی", "خيلي"), ("على", "علي"), ("مستشفى", "مستشفي"),   // one yeh, one kaf
            ("\u{FBFC}", "\u{064A}"), ("\u{FB8E}", "\u{0643}"),   // Persian yeh's and keheh's presentation forms
            ("কুমির", "কুমির"), ("上海市静安区", "上海市静安区"), ("café", "café"), ("naïve", "naïve"),
        ]
        for (text, expected) in cases {   // scalar by scalar: Swift's == counts "a" and an accent equal to "á"
            #expect(Array(Script.normalized(text).unicodeScalars) == Array(expected.unicodeScalars),
                    "\(text.unicodeScalars.map { String($0.value, radix: 16) })")
        }
        #expect(Script.normalized("") == "")
        #expect(Script.inflects("کتاب") && Script.inflects("الكتاب") && Script.inflects("কুমির") && Script.inflects("नमस्ते"))
        #expect(!Script.inflects("book") && !Script.inflects("静安区") && !Script.inflects("שלום"))
        // What the switch drops or changes is what an older index is searched for (`IndexStore.normalizeWords`).
        for value in UInt32(0)...0xFFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let listed = Script.changedByNormalizing.contains { $0.contains(value) }
            if Script.normalizedAway(scalar) != listed { Issue.record("U+\(String(value, radix: 16))"); break }
        }
    }

    /// The files in `files/`, read.
    func indexed(_ files: [String: String]) throws -> (Scratch, IndexStore) {
        let scratch = try Scratch()
        for (name, text) in files { try scratch.write("files/" + name, text) }
        let store = try scratch.store()
        let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
        _ = try indexer.sync([scratch.path + "/files"])
        try indexer.readPending()
        return (scratch, store)
    }

    static let files = [
        "目录.txt": "The infor\u{00AD}mation desk opens at nine; ask there for the visitor badge.",
        "مكتبة.txt": "وُضِعَ الكِتَابُ على الطاولة، وقال أحمد إنه يقرأ قصة طويـــلة عن البحر.",
        "র‍্যাব.txt": "আজ সকালে র\u{200D}্যাবের একটি দল কুমি\u{200D}রের খোঁজে নদীতে গেল।",
        "上海.txt": "公司在上海市静安\u{2060}区南京西路，前台在三楼。",
        "كـشـف.txt": "Quarterly numbers only.",   // found by its name alone
        "کتاب‌ها.txt": "کتاب\u{200C}ها را روی میز گذاشتم.",   // Persian: "the books", the plural ending after a non-joiner
        "fa.txt": "این کتاب خیلی خوب است.",
        "网页.txt": "从网页复制来的会\u{200B}议纪要，讲的是明年的预算。",
        "长.txt": String(repeating: "Some unrelated words about the weather and the sea. ", count: 6)
            + "Then: \u{FECB}\u{FEE0}\u{FEE4}\u{FE8E}\u{0621} the scholars, at the end.",   // presentation forms
    ]

    @Test("a word is found however it's written in the file or the question, and the snippet quotes it as written")
    func searchNormalized() throws {
        let (scratch, store) = try indexed(Self.files)
        defer { withExtendedLifetime(scratch) {} }
        let searcher = Searcher(store: store)
        let questions: [(String, String)] = [
            ("information desk", "目录.txt"),
            ("الكتاب", "مكتبة.txt"), ("الكِتَاب", "مكتبة.txt"), ("احمد", "مكتبة.txt"), ("أحمد", "مكتبة.txt"),
            ("طويلة", "مكتبة.txt"), ("طويـلة", "مكتبة.txt"),
            ("কুমিরের", "র‍্যাব.txt"), ("র্যাবের", "র‍্যাব.txt"),
            ("静安区", "上海.txt"), ("كشف", "كـشـف.txt"),
            ("information\u{200B}desk", "目录.txt"), ("会议纪要", "网页.txt"), ("علماء", "长.txt"),
            // Typed on a Persian keyboard, written in Arabic, and back; the alef maksura as yeh.
            ("الکتاب", "مكتبة.txt"), ("خيلي", "fa.txt"), ("علي الطاولة", "مكتبة.txt"),
        ]
        for (question, file) in questions {
            let hits = try searcher.search(question).hits
            #expect(hits.first?.title == file, "\(question)")
        }
        // The snippet is of the text as written, around the word.
        let desk = try #require(try searcher.search("information desk").hits.first?.snippet)
        #expect(desk.contains("infor\u{00AD}mation desk"))
        let long = try #require(try searcher.search("طويلة").hits.first?.snippet)
        #expect(long.contains("طويـــلة"))
        // A word far into the text: the snippet is around it, as written (presentation forms).
        let far = try #require(try searcher.search("علماء").hits.first?.snippet)
        #expect(far.contains("\u{FECB}\u{FEE0}\u{FEE4}\u{FE8E}\u{0621}"))
        let persian = try #require(try searcher.search("خيلي").hits.first?.snippet)
        #expect(persian.contains("خیلی"))
        // Found by its name: "the name", not the folder's.
        #expect(try searcher.search("كشف").hits.first?.why == "名字对得上")
        // Persian: "کتاب" finds "کتاب‌ها" (one word now) as the start of it, and the other file.
        #expect(Set(try searcher.search("کتاب").hits.map(\.title)).isSuperset(of: ["کتاب‌ها.txt", "fa.txt"]))
        #expect(Set(try searcher.search("كتاب").hits.map(\.title)).isSuperset(of: ["کتاب‌ها.txt", "fa.txt"]))   // typed in Arabic
        // A table: the row with the word is the one shown.
        let rows = "物业费\t320\n宽带\t100\n水费\t80\n停车\tinfor\u{00AD}mation desk"
        #expect(Searcher.sheetSnippet(rows, terms: ["information"])?.contains("infor\u{00AD}mation") == true)
    }

    @Test("find: the word's place in the text as written, through what normalizing changes")
    func find() throws {
        let cases = [("information", "infor\u{00AD}mation"), ("كتاب", "كـتـاب"), ("الكتاب", "الكِتَابُ"),
                     ("কুমিরের", "কুমি\u{200D}রের"), ("会议纪要", "会\u{200B}议纪要"),
                     ("كتاب", "\u{FEDB}\u{FE98}\u{FE8E}\u{FE8F}"), ("الله", "\u{FDF2}"),   // these two: presentation forms
                     ("كتاب", "کتاب"), ("خيلي", "خیلی"), ("علي", "على")]
        for (term, written) in cases {
            let text = "seen: " + written + " here"
            let range = try #require(Searcher.find(term, in: text), "\(term)")
            #expect(String(text[range]) == written, "\(term)")
        }
        let text = "The infor\u{00AD}mation desk"
        #expect(Searcher.find("DESK", in: text).map { String(text[$0]) } == "desk")   // as before: case
        #expect(Searcher.find("cafe", in: "Café au lait").map { String("Café au lait"[$0]) } == "Café")   // accents
        #expect(Searcher.find("library", in: text) == nil)
        #expect(Searcher.find("", in: text) == nil)
    }

    @Test("an index from before (schema 6, NFKC alone) is normalized once: only the rows that change; what's written stays")
    func olderIndex() throws {
        let (scratch, store) = try indexed(Self.files.merging(["普通.txt": "Nothing to change here: plain words."]) { $1 })
        // As schema 6 wrote them: NFKC alone, the text as written only where NFKC changed it.
        // A file's name is in its name row as written (`spaced`): the row has it normalized now.
        var rows: [(Int64, String, String)] = []
        try store.db.query("""
            SELECT f.rowid, f.name, coalesce(f.original, f.body), i.path FROM fts f
            JOIN segments s ON s.id = f.rowid JOIN items i ON i.id = s.item
            """) { row in
            let name = row.text(1) ?? ""
            let written = name.isEmpty ? "" : IndexStore.spaced(URL(fileURLWithPath: row.text(3) ?? "").lastPathComponent)
            rows.append((row.int(0), written, row.text(2) ?? ""))
        }
        #expect(rows.contains { $0.1.contains("كـشـف") })
        let nfkc = { (text: String) in text.precomposedStringWithCompatibilityMapping }
        for (id, name, written) in rows {
            let body = nfkc(written)
            try store.db.query("UPDATE fts SET name = ?, body = ?, original = ? WHERE rowid = ?",
                               [.text(nfkc(name)), .text(body), body == written ? .null : .text(written), .int(id)])
            try store.db.query("UPDATE fts_tri SET name = ?, body = ? WHERE rowid = ?", [.text(nfkc(name)), .text(body), .int(id)])
        }
        let generation = try store.meta("vector_generation")
        try store.db.execute("PRAGMA user_version = 6")
        #expect(try Searcher(store: store).search("information").hits.isEmpty)   // not found as it was
        let joined = "SELECT count(*) FROM fts_tri WHERE body LIKE '%静安区%'"
        #expect(try store.db.scalarInt(joined) == 0)

        let again = try scratch.store()
        #expect(try again.db.scalarInt("PRAGMA user_version") == IndexStore.schemaVersion)
        let searcher = Searcher(store: again)
        #expect(try searcher.search("information").hits.first?.title == "目录.txt")
        #expect(try again.db.scalarInt(joined) == 1)
        #expect(try searcher.search("احمد").hits.first?.title == "مكتبة.txt")
        #expect(try searcher.search("কুমিরের").hits.first?.title == "র‍্যাব.txt")
        #expect(try searcher.search("静安区").hits.first?.title == "上海.txt")   // the trigram table too
        #expect(try searcher.search("كشف").hits.first?.title == "كـشـف.txt")    // a name
        // Every row's words as they're written now, the files' names in each of their rows too; the text as written
        // is what it was (snippets, vectors); the vectors aren't touched.
        for (id, name, written) in rows {
            var now: (String, String)?
            try again.db.query("SELECT name, body FROM fts WHERE rowid = ?", [.int(id)]) { now = ($0.text(0) ?? "", $0.text(1) ?? "") }
            #expect(now.map { [$0.0, $0.1] } == [Script.normalized(name), Script.normalized(written)], "\(name)")
            #expect(try again.text(ofSegment: id) == written)
        }
        #expect(try again.meta("vector_generation") == generation)
        var plain: (String?, String?)
        try again.db.query("SELECT f.body, f.original FROM fts f JOIN segments s ON s.id = f.rowid JOIN items i ON i.id = s.item WHERE i.path LIKE '%普通.txt' AND s.kind != 'name'") {
            plain = ($0.text(0), $0.text(1))
        }
        #expect(plain.0 == "Nothing to change here: plain words." && plain.1 == nil)

        // Only the rows that change are written: as schema 6 again, as many as hold such a character, then none.
        let changing = rows.filter { _, name, written in
            (nfkc(name) + nfkc(written)).unicodeScalars.contains(where: Script.normalizedAway)
        }
        #expect(changing.count > 0 && changing.count < rows.count)
        for (id, name, written) in rows {
            let body = nfkc(written)
            try again.db.query("UPDATE fts SET name = ?, body = ?, original = ? WHERE rowid = ?",
                               [.text(nfkc(name)), .text(body), body == written ? .null : .text(written), .int(id)])
        }
        #expect(try again.normalizeWords() == changing.count)
        #expect(try again.normalizeWords() == 0)
    }

    /// As schema 7 normalized text: the same, but Persian's yeh and keheh and the alef maksura left as they are (they
    /// go through as characters `normalized` keeps, from the private use area, and come back). After NFKC, as 7 did:
    /// their presentation forms are those letters then, and stay (review 11-03).
    static func asSchema7(_ text: String) -> String {
        let kept: [(Character, Character)] = [("\u{06CC}", "\u{E000}"), ("\u{06A9}", "\u{E001}"), ("\u{0649}", "\u{E002}")]
        var hidden = text.precomposedStringWithCompatibilityMapping
        for (letter, stand) in kept { hidden = hidden.replacingOccurrences(of: String(letter), with: String(stand)) }
        var out = Script.normalized(hidden)
        for (letter, stand) in kept { out = out.replacingOccurrences(of: String(stand), with: String(letter)) }
        return out
    }

    @Test("an index from schema 7 gets its letters merged once: only the rows with a Persian yeh, keheh or alef maksura")
    func schema7Index() throws {
        // Also "خیلی" in presentation forms: NFKC makes them Persian's yeh, which 7 kept.
        let forms = "\u{FEA7}\u{FBFF}\u{FEE0}\u{FBFD}"
        #expect(Self.asSchema7(forms) == "خیلی" && Script.normalized(forms) == "خيلي")
        let (scratch, store) = try indexed(Self.files.merging(["شكل.txt": "متن با " + forms + " نوشته شده."]) { $1 })
        var rows: [(Int64, String, String)] = []
        try store.db.query("""
            SELECT f.rowid, f.name, coalesce(f.original, f.body), i.path FROM fts f
            JOIN segments s ON s.id = f.rowid JOIN items i ON i.id = s.item
            """) { row in
            let name = row.text(1) ?? ""
            let written = name.isEmpty ? "" : IndexStore.spaced(URL(fileURLWithPath: row.text(3) ?? "").lastPathComponent)
            rows.append((row.int(0), written, row.text(2) ?? ""))
        }
        let seven = { (id: Int64, name: String, written: String) throws in
            let body = Self.asSchema7(written)
            try store.db.query("UPDATE fts SET name = ?, body = ?, original = ? WHERE rowid = ?",
                               [.text(Self.asSchema7(name)), .text(body), body == written ? .null : .text(written), .int(id)])
            try store.db.query("UPDATE fts_tri SET name = ?, body = ? WHERE rowid = ?",
                               [.text(Self.asSchema7(name)), .text(body), .int(id)])
        }
        for row in rows { try seven(row.0, row.1, row.2) }
        try store.db.execute("PRAGMA user_version = 7")
        #expect(try Searcher(store: store).search("خيلي").hits.isEmpty)   // not found as it was
        #expect(try Searcher(store: store).search("information").hits.first?.title == "目录.txt")   // 7 had that

        let again = try scratch.store()
        #expect(try again.db.scalarInt("PRAGMA user_version") == IndexStore.schemaVersion)
        let searcher = Searcher(store: again)
        #expect(Set(try searcher.search("خيلي").hits.map(\.title)) == ["fa.txt", "شكل.txt"])
        #expect(try searcher.search("الکتاب").hits.first?.title == "مكتبة.txt")
        #expect(try searcher.search("كتابها").hits.first?.title == "کتاب‌ها.txt")
        for (id, name, written) in rows {
            var now: (String, String)?
            try again.db.query("SELECT name, body FROM fts WHERE rowid = ?", [.int(id)]) { now = ($0.text(0) ?? "", $0.text(1) ?? "") }
            #expect(now.map { [$0.0, $0.1] } == [Script.normalized(name), Script.normalized(written)], "\(name)")
            #expect(try again.text(ofSegment: id) == written)
        }

        // Only the rows with one of the three are written again: as 7 again, as many as hold one, then none.
        let changing = rows.filter { _, name, written in
            (Self.asSchema7(name) + Self.asSchema7(written)).unicodeScalars.contains { [0x06CC, 0x06A9, 0x0649].contains($0.value) }
        }
        #expect(changing.count > 0 && changing.count < rows.count)
        for row in rows { try seven(row.0, row.1, row.2) }
        // And a row windows away from the rest (`normalizeWindow` rowids to a transaction).
        let far = IndexStore.normalizeWindow * 3 + 7
        try store.db.query("INSERT INTO fts(rowid, name, body) VALUES(?, '', ?)", [.int(far), .text("یک روز")])
        #expect(try again.normalizeWords() == changing.count + 1)
        #expect(try again.normalizeWords() == 0)
        #expect(try again.db.scalarInt("SELECT count(*) FROM fts WHERE rowid = ? AND body = 'يك روز'", [.int(far)]) == 1)
    }

    @Test("a credential is found through invisible formatting, and masked whole")
    func credentialsThroughInvisible() {
        let label = Secrets.mask("pass\u{00AD}word: Hunter2xyz! and more")
        #expect(!label.contains("Hunter2xyz") && label.contains("〔密码〕"))
        let value = Secrets.mask("password: Hunter2\u{00AD}xyz! and more")
        #expect(!value.contains("Hunter2") && !value.contains("xyz!") && value.hasSuffix(" and more"))
        #expect(Secrets.mask("密\u{200B}码：kiwi8888，记得改").contains("〔密码〕"))
        let card = "卡号 4111\u{00AD}1111 1111 1111 到期"
        #expect(Secrets.mask(card) == "卡号 〔卡号 ****1111〕 到期")
        #expect(Secrets.mask("nothing\u{00AD}here") == "nothing\u{00AD}here")
        // A zero-width space both ways: a break between a card and its expiry; nothing inside a long key.
        #expect(Secrets.mask("卡 4111111111111111\u{200B}12/28 到期") == "卡 〔卡号 ****1111〕\u{200B}12/28 到期")
        let key = "Qz8mN3pL7vX2cR9tB4wK\u{200B}6yH1jF5gD0sA7eU3iO8n"
        #expect(Secrets.mask("key " + key + " end") == "key 〔密钥〕 end")
    }
}
