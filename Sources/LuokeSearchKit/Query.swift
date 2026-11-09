import Foundation
import NaturalLanguage

/// What a query asks for, as keyword search sees it: its words (without the ones that carry no meaning), and the
/// kinds of item it names ("截图", "照片", "录音"), which count for those kinds instead of being looked for as words.
public struct Query: Sendable, Equatable {
    public struct Term: Sendable, Equatable {
        public let text: String
        /// Written without spaces (Chinese, Japanese…): matched with the trigram table, or LIKE when shorter than 3.
        public let unspaced: Bool
        /// Made by joining characters the tokenizer left on their own ("年付": it splits words it doesn't know into
        /// single characters). Such a term adds to an item's share of the query's words when found, but doesn't
        /// count against it when not: it may be a real word or two unrelated characters ("月拍").
        public var optional = false
    }

    public let original: String
    public let terms: [Term]
    public let kindHints: Set<ItemKind>

    /// The terms an item's share of the query's words is counted against.
    public var countedTerms: Int {
        let required = terms.filter { !$0.optional }.count
        return required > 0 ? required : terms.count
    }

    /// Every word holds digits ("K7Q2LM", "4815162342"): an exact lookup, where words count more than meaning.
    public var isLookup: Bool {
        !terms.isEmpty && terms.allSatisfy { term in
            term.text.contains(where: \.isNumber) && (term.text.contains(where: \.isLetter) || term.text.count >= 4)
        }
    }

    /// A question is looked at up to 200 characters, for at most 12 required and 8 optional terms: each is a scan
    /// of the index, and a paragraph pasted as a question would take seconds while the agent waits (review B-17).
    static let maxCharacters = 200
    static let maxRequired = 12
    static let maxOptional = 8

    public init(_ text: String) {
        original = text
        let normalized = Script.normalized(String(text.prefix(Self.maxCharacters))).lowercased()   // as the index keeps text
        var hints = Set<ItemKind>()
        var terms: [Term] = []
        var seen = Set<String>()
        var singles: [String] = []   // characters on their own, kept for a one-character query
        var run = "", runEnd: String.Index?
        func flush() {
            if run.count >= 2, seen.insert(run).inserted {
                terms.append(Term(text: run, unspaced: true, optional: true))
            }
            // A longer run may be two words run together ("年付八折"): its pairs of characters are tried too.
            if run.count >= 3 {
                let characters = Array(run)
                for index in 0..<(characters.count - 1) {
                    let pair = String(characters[index...index + 1])
                    if seen.insert(pair).inserted { terms.append(Term(text: pair, unspaced: true, optional: true)) }
                }
            }
            run = ""
        }
        for (word, range) in Self.words(normalized) {
            let unspaced = Script.hasUnspaced(word)
            if unspaced, word.count == 1 {
                singles.append(word)
                // Neighbouring single characters that aren't function words make a candidate word.
                if Self.singleStops.contains(word) || Self.kindWords[word] != nil || runEnd != range.lowerBound {
                    flush()
                }
                if !Self.singleStops.contains(word) && Self.kindWords[word] == nil { run += word }
                runEnd = range.upperBound
                if let kind = Self.kindWords[word] { hints.insert(kind) }
                continue
            }
            flush()
            runEnd = nil
            if let kind = Self.kindWords[word] {
                hints.insert(kind)
                continue
            }
            if Self.stopwords.contains(word) || (!unspaced && word.unicodeScalars.count < 2) { continue }
            if seen.insert(word).inserted { terms.append(Term(text: word, unspaced: unspaced)) }
        }
        flush()
        // A query of one Chinese character ("猫") is still a query.
        if terms.isEmpty, singles.count == 1, let only = singles.first, Self.kindWords[only] == nil {
            terms.append(Term(text: only, unspaced: true))
        }
        var required = 0, optional = 0
        self.terms = terms.filter { term in
            if term.optional {
                optional += 1
                return optional <= Self.maxOptional
            }
            required += 1
            return required <= Self.maxRequired
        }
        // "照片" means pictures in folders and the Photos library's photos alike.
        if hints.contains(.image) { hints.insert(.photo) }
        kindHints = hints
    }

    /// The query's words with where they are. Chinese and Japanese are split into words by the system's tokenizer
    /// (NLTokenizer), the rest at anything that isn't a letter or digit.
    static func words(_ text: String) -> [(String, Range<String.Index>)] {
        var out: [(String, Range<String.Index>)] = []
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range])
            if Script.hasUnspaced(token) {
                out.append((token, range))
            } else {
                for part in token.components(separatedBy: CharacterSet.alphanumerics.inverted) where !part.isEmpty {
                    out.append((part, range))
                }
            }
            return true
        }
        return out
    }

    /// Single characters that are function words, measure words or request verbs: they never join a candidate word.
    static let singleStops: Set<String> = [
        "的", "了", "是", "在", "里", "那", "这", "哪", "个", "和", "与", "及", "或", "吗", "呢", "吧", "啊", "呀",
        "我", "你", "他", "她", "它", "们", "写", "找", "搜", "查", "看", "说", "讲", "有", "没", "页", "张", "份",
        "段", "篇", "次", "把", "被", "给", "让", "从", "到", "向", "对", "就", "都", "也", "还", "又", "很", "太",
        "更", "最", "上", "下", "中", "要", "想", "能", "会", "过", "着", "得", "地", "之", "其", "该", "每", "些",
        "一", "帮", "拍", "录", "存", "放", "发", "收", "用", "做", "去", "来", "叫", "跟", "关", "於",
        "裡", "這", "個", "們", "說", "給", "讓", "從", "對", "還", "會", "過", "幫", "錄", "發",
    ]

    /// Words that name a kind of item. They aren't looked for as words; the kind gets a bonus (not a filter: a
    /// "screenshot" query still finds a document that matches better).
    static let kindWords: [String: ItemKind] = [
        "screenshot": .screenshot, "screenshots": .screenshot, "截图": .screenshot, "截屏": .screenshot,
        "屏幕截图": .screenshot, "截圖": .screenshot,
        "photo": .image, "photos": .image, "picture": .image, "pictures": .image, "image": .image,
        "images": .image, "照片": .image, "相片": .image, "图片": .image, "圖片": .image, "图": .image,
        "pdf": .pdf, "pdfs": .pdf, "扫描件": .pdf, "掃描件": .pdf,
        "document": .doc, "documents": .doc, "doc": .doc, "docs": .doc, "note": .doc, "notes": .doc,
        "文档": .doc, "笔记": .doc, "表格": .doc, "幻灯片": .doc, "文檔": .doc, "筆記": .doc,
        "video": .video, "videos": .video, "clip": .video, "movie": .video, "视频": .video, "录像": .video,
        "影片": .video, "視頻": .video, "錄像": .video,
        "audio": .audio, "recording": .audio, "recordings": .audio, "podcast": .audio, "voice": .audio,
        "song": .audio, "录音": .audio, "音频": .audio, "语音": .audio, "播客": .audio, "錄音": .audio,
        "語音": .audio,
    ]

    /// Words that carry no meaning for finding things: English function words and request words, and Chinese ones
    /// of two characters or more (single characters are dropped anyway).
    static let stopwords: Set<String> = [
        // English
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "with", "and", "or", "my", "me", "i", "that", "this",
        "these", "those", "from", "about", "where", "what", "which", "who", "when", "is", "was", "are", "were", "be",
        "it", "its", "some", "any", "find", "show", "file", "files", "search", "look", "get", "please", "one",
        "did", "do", "does", "had", "has", "have", "there", "said", "says", "say",
        // Chinese
        "那个", "这个", "哪个", "那张", "这张", "那份", "这份", "那段", "这段", "那页", "这页", "那篇", "这篇",
        "那次", "这次", "那些", "这些", "一个", "一张", "一份", "一段", "一下", "我的", "你的", "他的", "她的",
        "帮我", "给我", "找到", "找找", "找出", "找一", "搜索", "搜一", "查找", "查一", "查查", "看看", "看一",
        "文件", "东西", "关于", "有关", "相关", "什么", "怎么", "哪里", "哪儿", "哪些", "时候", "之前", "以前", "以后",
        "上次", "最近", "说过", "说到", "提到", "写着", "写的", "里面", "里的", "上面", "上的", "记得", "好像",
        "应该", "是不是", "有没有", "一些", "我们", "你们", "他们", "可以", "能不能", "就是", "还是", "或者",
        "那個", "這個", "這張", "那張", "幫我", "搜尋", "東西", "關於", "甚麼", "什麼", "哪裡", "時候",
        // Relative times: the agent turns them into `since` / `until`; as words they match nothing useful.
        "上个月", "这个月", "本月", "下个月", "上月", "去年", "今年", "前年", "昨天", "前天", "今天", "上周",
        "本周", "这周", "上星期", "这星期", "上礼拜", "前几天", "那天", "当天", "月初", "月底", "年初", "年底",
        "上個月", "這個月", "這週", "上週",
    ]
}
