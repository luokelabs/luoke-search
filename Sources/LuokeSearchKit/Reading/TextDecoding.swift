import Foundation

/// Turns a plain-text file's bytes into text without knowing its encoding up front.
///
/// Order: a byte-order mark; UTF-8; UTF-16 without a mark (lots of zero bytes); GB 18030 (the superset of GBK and
/// GB 2312: Chinese Windows and older Chinese editors save txt, md and csv in it); Big5 (Traditional Chinese); and
/// last Windows-1252, which never fails. A legacy Chinese encoding only wins when what it decodes is mostly Chinese:
/// any byte string decodes as *something* in GB 18030, so Latin-1 text must not come out as nonsense ideographs.
public enum TextDecoding {
    public static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    public static let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)))

    /// `cut`: the file was read only up to a limit, so its last character may be cut in half: each encoding is also
    /// tried without the last one to three bytes (review A-13). NUL characters are dropped (review A-15: SQLite would
    /// end the text there).
    public static func decode(_ data: Data, cut: Bool = false) -> (text: String, encoding: String.Encoding) {
        let (text, encoding) = decoded(data, cut: cut)
        return (text.contains("\0") ? text.replacingOccurrences(of: "\0", with: "") : text, encoding)
    }

    static func decoded(_ data: Data, cut: Bool) -> (text: String, encoding: String.Encoding) {
        func string(_ data: Data, _ encoding: String.Encoding) -> String? {
            for trim in 0...(cut ? 3 : 0) where data.count > trim {
                if let text = String(data: data.dropLast(trim), encoding: encoding) { return text }
            }
            return nil
        }
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]), let text = string(data.dropFirst(3), .utf8) {
            return (text, .utf8)
        }
        if bytes.starts(with: [0xFF, 0xFE]), let text = string(data.dropFirst(2), .utf16LittleEndian) {
            return (text, .utf16LittleEndian)
        }
        if bytes.starts(with: [0xFE, 0xFF]), let text = string(data.dropFirst(2), .utf16BigEndian) {
            return (text, .utf16BigEndian)
        }
        // Before UTF-8: ASCII in UTF-16 is valid UTF-8 too (with a NUL every other byte, review A-15).
        if let utf16 = unmarkedUTF16(data) { return utf16 }
        if let text = string(data, .utf8) { return (text, .utf8) }
        for encoding in [gb18030, big5] {
            if let text = string(data, encoding), mostlyChinese(text) { return (text, encoding) }
        }
        let text = String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        return (text, .windowsCP1252)
    }

    /// UTF-16 without a byte-order mark: ASCII text in it has a zero in every other byte.
    static func unmarkedUTF16(_ data: Data) -> (String, String.Encoding)? {
        let sample = [UInt8](data.prefix(400))
        guard sample.count >= 8 else { return nil }
        let even = data.count % 2 == 0 ? data : data.dropLast()   // a file cut at a limit may end mid-character
        let evenZeros = stride(from: 0, to: sample.count - 1, by: 2).filter { sample[$0] == 0 }.count
        let oddZeros = stride(from: 1, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
        let half = sample.count / 2
        if oddZeros * 10 >= half * 3, evenZeros * 10 < half, let text = String(data: even, encoding: .utf16LittleEndian) {
            return (text, .utf16LittleEndian)
        }
        if evenZeros * 10 >= half * 3, oddZeros * 10 < half, let text = String(data: even, encoding: .utf16BigEndian) {
            return (text, .utf16BigEndian)
        }
        return nil
    }

    /// Of the characters outside ASCII, at least 70% are CJK ideographs or CJK punctuation, and none is a control
    /// character or in the private use area.
    /// General punctuation (“”‘’…—, U+2010–U+206F) and the middle dot are written with Chinese as much as with
    /// anything: they count neither way (review A-14). At least two ideographs are needed.
    static func mostlyChinese(_ text: String) -> Bool {
        var outside = 0, chinese = 0, han = 0
        for scalar in text.unicodeScalars where !scalar.isASCII {
            let value = scalar.value
            if (0x2010...0x206F).contains(value) || value == 0xB7 { continue }
            outside += 1
            if (0xE000...0xF8FF).contains(value) || (0x80...0x9F).contains(value) { return false }
            if Script.isHan(scalar) { han += 1 }
            if Script.isHan(scalar) || (0x3000...0x303F).contains(value) || (0xFF00...0xFFEF).contains(value) {
                chinese += 1
            }
        }
        return han >= 2 && chinese * 10 >= outside * 7
    }
}

/// Which writing systems characters belong to, as far as search needs to know.
public enum Script {
    public static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0x2A700...0x2EBEF, 0xF900...0xFAFF, 0x30000...0x3134F:
            return true
        default:
            return false
        }
    }

    /// Scripts written without spaces between words: Chinese, Japanese kana, Thai, Lao, Khmer, Myanmar. Their words
    /// are found with the trigram table (and LIKE for two-character words), not by the word tokenizer.
    public static func isUnspaced(_ scalar: Unicode.Scalar) -> Bool {
        if isHan(scalar) { return true }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF,        // Hiragana, Katakana
             0x0E00...0x0E7F, 0x0E80...0x0EFF,        // Thai, Lao
             0x1780...0x17FF, 0x1000...0x109F:        // Khmer, Myanmar
            return true
        default:
            return false
        }
    }

    public static func hasUnspaced(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isUnspaced)
    }

    /// Text as keyword search keeps it and matches it, the index's words and a question's alike, so a word is found
    /// however it was typed or extracted (as luoke's internal DigUp fork does):
    /// - NFKC: full-width letters and digits become plain ones ("ＰＤＦ" is "pdf"), Arabic presentation forms and
    ///   ligatures plain letters, Bengali's two spellings of "ো" one;
    /// - invisible formatting dropped: zero-width joiners (inside Bengali words, and Persian's non-joiner inside
    ///   "کتاب‌ها": one word, found by its start, see `inflects`), direction marks, soft hyphens (PDFs and web pages
    ///   split words with them), BOMs; a zero-width space is a word break, except between characters of scripts
    ///   written without spaces (Thai marks words with it, Chinese copied from a web page can have it);
    /// - Arabic as people type it: no tatweel, no short-vowel marks (harakat), one alef;
    /// - one letter however a keyboard writes it: Persian's yeh (ی) and keheh (ک) as Arabic's yeh (ي) and kaf (ك), the
    ///   alef maksura (ى, a final yeh without its dots) as yeh, so a word typed on a Persian keyboard finds it written
    ///   in Arabic and back (11-03; luoke's internal DigUp fork doesn't).
    /// What's left is composed again (NFC): a mark dropped between a letter and its accent left them apart.
    public static func normalized(_ text: String) -> String {
        let compatible = text.precomposedStringWithCompatibilityMapping
        guard compatible.unicodeScalars.contains(where: normalizedAway) else { return compatible }
        let all = Array(compatible.unicodeScalars)
        var scalars = String.UnicodeScalarView()
        for (index, scalar) in all.enumerated() {
            switch scalar.value {
            case 0x200B:
                if !joins(scalars.last, all[(index + 1)...].first(where: { !isInvisible($0) })) { scalars.append(" ") }
            case 0x0622, 0x0623, 0x0625, 0x0671: scalars.append("\u{0627}")   // alef with madda, hamza or wasla
            case 0x0649, 0x06CC: scalars.append("\u{064A}")                   // alef maksura, Persian yeh
            case 0x06A9: scalars.append("\u{0643}")                           // keheh (Persian kaf)
            default: if !normalizedAway(scalar) { scalars.append(scalar) }
            }
        }
        return String(scalars).precomposedStringWithCanonicalMapping
    }

    /// The characters `normalized` drops or changes after NFKC, as ranges (`IndexStore` finds rows holding them).
    static let changedByNormalizing: [ClosedRange<UInt32>] = [
        0x00AD...0x00AD, 0x061C...0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069,
        0xFEFF...0xFEFF,                                   // soft hyphen, joiners, direction marks, BOM
        0x0640...0x0640, 0x064B...0x065F, 0x0670...0x0670, // tatweel; harakat and the dagger alef
        0x0622...0x0623, 0x0625...0x0625, 0x0671...0x0671, // alef with madda, hamza or wasla
        0x0649...0x0649, 0x06A9...0x06A9, 0x06CC...0x06CC, // alef maksura, keheh, Persian yeh
    ]

    /// One of `changedByNormalizing` (a switch: every character indexed is looked at).
    static func normalizedAway(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0640, 0x064B...0x065F, 0x0670, 0x0622...0x0623, 0x0625, 0x0671, 0x0649, 0x06A9, 0x06CC:
            return true
        default:
            return isInvisible(scalar)
        }
    }

    /// Invisible formatting: a soft hyphen, the Arabic letter mark, zero-width spaces and joiners, direction marks
    /// and embeddings, the word joiner and invisible operators, BOM. Credentials are looked for through them too.
    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// A zero-width space between these two characters joins them (both of scripts written without spaces): it's
    /// dropped. Anywhere else it's a word break, a space.
    static func joins(_ before: Unicode.Scalar?, _ after: Unicode.Scalar?) -> Bool {
        before.map(isUnspaced) == true && after.map(isUnspaced) == true
    }

    /// Words of scripts that attach endings (Bengali, Hindi and the other Indic scripts, Arabic, Persian): keyword
    /// search matches them as the start of longer words, as luoke's internal DigUp fork does, so "কুমির" finds
    /// "কুমিরের", "مدرس" "مدرسة" and "کتاب" "کتاب‌ها" (one word once its non-joiner is dropped).
    static func inflects(_ word: String) -> Bool {
        word.unicodeScalars.contains { (0x0900...0x0DFF).contains($0.value) || (0x0600...0x06FF).contains($0.value) }
    }
}
