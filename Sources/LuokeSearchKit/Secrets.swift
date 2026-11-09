import Foundation

/// Credentials in text, found as luoke-mem finds them (`luoke_mem/sensitive.py`, `find_secrets`, 888b424): passwords
/// and one-time codes said as such, keys and tokens, full card numbers (Luhn-checked) and ID numbers. Only that string
/// is replaced, everything else stays: passwords, codes and keys by what they were ("〔密码〕"), as luoke-mem's
/// `mask_secrets` does; a full card or ID number keeps its last 4 ("〔证件号 ****0017〕"; 10-22: "保留后四位"),
/// where luoke-mem masks the whole.
/// Snippets and titles go out to the agent masked: results, cards and the answer's text never carry a credential
/// (agent tool protocol §8; review C-08). The index keeps the text as written (10-22: a full ID or card number
/// finds its file), searched on this Mac only.
public enum Secrets {
    static let names = ["password": "密码", "code": "验证码", "key": "密钥", "card": "卡号", "id": "证件号",
                        "seed": "助记词", "recovery": "恢复码"]

    private static func pattern(_ text: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: text, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    static let passwordWords = #"(?:密码|密碼|口令|passphrase|pass phrase|password|passwd|passcode|pwd)"#
    /// What a password's value may be: anything up to a space or a sentence's punctuation; past 64 characters, more
    /// of it only if it isn't Chinese (one of 80 was cut at 64, its end left showing: pre-release review, should-fix
    /// 7; a sentence after "密码是" with no punctuation isn't taken further than before).
    static let passwordValue = #"([^\s，。,;；、）)]{3,64}[^\s，。,;；、）)\p{Han}]*+)"#
    /// Japanese and Korean words for it (should-fix 7: "パスワード:", "비밀번호:"), said with a separator, a particle
    /// or a space.
    static let otherPasswordWords = #"(?:パスワード|パスコード|暗証番号|비밀번호|패스워드|비번|암호)"#
    /// What a value after them is made of: up to a space, punctuation, a quote's end, or the sentence's own letters
    /// ("…は abc123 です").
    static let otherCharacters = #"[^\s，。,;；、）)」』"”\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]"#
    /// A value after them, not a rule's length or a date ("パスワード：8〜16文字", "비밀번호는 8~16자로", "2024年").
    static let otherValue = "(" + otherCharacters + #"{3,}+)(?!\s*+(?:文字|桁|자리|글자|자|位|年|月|日|개))"#
    /// Words a passphrase isn't made of: a rule's, or a sentence's ("Password: must be at least eight characters",
    /// "my password is stored in the vault", "the password is something only Bob knows").
    static let notPassphrase = #"(?:a|an|the|and|or|of|to|in|on|at|is|are|was|were|be|been|being|by|for|with|from|as|"#
        + #"into|if|so|but|when|must|should|can|could|will|would|may|not|no|never|always|now|also|very|still|just|"#
        + #"already|since|last|least|one|your|you|my|our|we|it|this|that|use|has|have|had|contain|contains|same|"#
        + #"i|me|he|she|his|her|its|they|them|their|us|who|what|which|where|why|how|here|there|these|those|then|than|"#
        + #"too|only|some|any|all|each|every|both|more|most|other|about|after|before|over|up|out|off|something|"#
        + #"anything|nothing|everything|know|knows|need|needs|kept|written|"#
        + #"stored|saved|sent|shared|expired|changed|reset|required|incorrect|wrong|invalid|characters?|letters?|digits?)"#
    /// A passphrase's word: small, or with a capital first ("Correct Horse Battery Staple"), and not one of those.
    static let phraseWord = #"(?!"# + notPassphrase + #"\b)(?-i:[A-Za-z][a-z]{1,11})"#
    /// What comes between the word and a passphrase: "是 / 为 / 设为…" (a colon after it too), a colon, "is".
    static let phraseSaid = passwordWords + #"(?:\s*+(?:是|为|為|就是|都是|也是|改成了?|改为了?|设为|设成|换成了?)(?:\s*+[:=])?"#
        + #"|\s*+[:=]|\s++(?:is|was)(?=\s))\s*+"#
    /// What may follow "PIN": "码", "code", "No.", "번호", "コード"; and what says the number is it.
    static let pinSuffix = #"\s*+(?:码|碼|(?i:code|number|no\.?)|번호|コード|番号)"#
    static let pinSaid = #"(?:\s*+(?:是|为|為|:|：|=|#|(?i:is)\b))"#

    /// A value with a digit or a sign in it: what English words between can be followed by and still be a password
    /// ("password is Hunter2Xyz", not "the password is incorrect").
    static let passwordLike = #"(?=[^\s，。,;；、）)]*[0-9!@#$%^&*])"#

    /// A value said to be a password or a code, right after the word ("密码是 abc123", "验证码：482913"). Runs of
    /// whitespace are taken whole (`\s*+`): the same matches, as a value never starts with one, without trying every
    /// way to split a long run (a sheet's tabs, a page's ideographic spaces).
    static let said: [(String, NSRegularExpression)] = [
        // Words between, in Chinese ("密码就是", "密碼是", "密码改成了"; pre-release review, must-fix 5).
        ("password", pattern(passwordWords + #"(?:\s*+(?:是|为|為|:|：|=|就是|都是|也是|改成了?|改为了?|设为|设成|换成了?))++\s*+"#
                             + passwordValue, caseInsensitive: true)),
        // In English, before a value with a digit or a sign ("my password is Hunter2Xyz", "Password - Tr0ub4dor9x").
        ("password", pattern(passwordWords + #"(?:\s*+(?::|=|#|-(?=\s)|(?:is|was)(?=\s)))++\s*+"# + passwordLike
                             + passwordValue, caseInsensitive: true)),
        // Spaces only, and not an English word after ("password was changed", "password for the WiFi").
        ("password", pattern(passwordWords + #"\s++(?!(?:is|was|are|were|for|the|and|has|have|had|of|to|in|on|at|that|this|will|"#
                             + #"must|should|can|may|not|field|reset|manager|policy|protected|changed|required)\b)"# + passwordValue,
                             caseInsensitive: true)),
        ("password", pattern(#"\b(?:pw|pass)\s*+[:=]\s*+"# + passwordValue, caseInsensitive: true)),
        // Nothing between, in Chinese, before letters and digits with a digit in them ("WiFi密码88886666"): not
        // "密码学", "密码锁", "忘记密码...", "密码App".
        ("password", pattern(#"(?:密码|密碼|口令)((?=[A-Za-z!@#$%^&*_+=?~-]*[0-9])[0-9A-Za-z!@#$%^&*_+=?~-]{3,})"#)),
        // What it's for, between ("The password for the WiFi is Abc12345", "password to the router: admin123", "The
        // PIN for the safe is 4821"), before a value with a digit or a sign (should-fix 7; not "the password for the
        // account is incorrect").
        ("password", pattern(#"(?:\bpass(?:word|phrase)s?|(?<![A-Za-z0-9])(?-i:PIN))\s++(?:for|to|of)\b\s*+(?:[^\s,.;:=]++\s*+){0,6}?"#
                             + #"(?:(?:is|was|are)\b(?:\s++now\b)?|[:=])\s*+[:=]?\s*+"# + passwordLike + passwordValue,
                             caseInsensitive: true)),
        // Words with spaces between ("密码是 correct horse battery staple", "Password: Correct Horse Battery Staple",
        // "my password is correct horse battery staple"; should-fix 7: only the first word was masked): four to ten
        // words, a number after them at most, then nothing but punctuation or the sentence's own letters; three in
        // quotes, the quotes masked with them (as a value in quotes is by the rules above, which would else take its
        // first word with the quote). Not words of a rule or a sentence (`notPassphrase`: "must be at least eight
        // characters").
        ("password", pattern(phraseSaid + #"(["'“‘「『]"# + phraseWord + #"(?:\x20{1,3}"# + phraseWord + #"){2,9}["'”’」』])"#,
                             caseInsensitive: true)),
        ("password", pattern(phraseSaid + "(" + phraseWord + #"(?:\x20{1,3}"# + phraseWord + #"){3,9}(?:\x20{1,3}[0-9]{1,6})?)"#
                             + #"(?![\x20\t]{0,3}[A-Za-z0-9])"#, caseInsensitive: true)),
        // Japanese and Korean (should-fix 7): after a colon or "="; after a particle (は, が, を, 는, 은, 이, 가, 를, 을)
        // or only a space, the value has a digit or a sign, as after "is".
        ("password", pattern(otherPasswordWords + #"\s*+[:=]\s*+[「『"“]?"# + otherValue)),
        ("password", pattern(otherPasswordWords + #"(?:\s*+(?:は|が|を|는|은|이|가|를|을))?\s*+[「『"“]?"#
                             + "(?=" + otherCharacters + #"*[0-9!@#$%^&*])"# + otherValue)),
        // A PIN ("PIN: 7391", "PIN码 864209", "银行卡PIN码：482913"; should-fix 7): "PIN" in capitals ("Pin 2024" is a
        // pinout's) or any "pin code", "PIN码"; four to eight digits. Not after a letter or a digit ("SPIN"), which a
        // Chinese character isn't. "PIN 1234" with nothing between is a model's or a year's ("PIN 2026 年发布").
        ("password", pattern(#"(?<![A-Za-z0-9])(?:PIN(?:"# + pinSuffix + pinSaid + #"*+|"# + pinSaid + #"++)|(?i:pin)"#
                             + pinSuffix + pinSaid + #"*+)\s*+([0-9]{4,8})(?![0-9])"#)),
        // A code of letters has a digit in it too ("code 7KX9QZ", not "code review"); not an error's or a status's
        // code ("error code is 50001").
        ("code", pattern(#"(?:验证码|校验码|动态码|确认码|安全码|one[- ]time code|verification code|security code|\bOTP\b|"#
                         + #"(?<!error )(?<!status )(?<!exit )(?<!return )(?<!zip )(?<!area )(?<!postal )(?<!country )\bcode\b)"#
                         + #"\s*+(?:(?:是|为|:|：|=|is)\s*+){0,2}([0-9]{4,8}|(?=[A-Z]*[0-9])[A-Z0-9]{6})\b"#,
                         caseInsensitive: true)),
        ("code", pattern(#"\b(?:G-)?([0-9]{4,8})\s*+(?:是|为|is)\s*+(?:(?:你的|您的|your)\s*+)?(?:\S+\s+)?"#
                         + #"(?:验证码|校验码|动态码|verification code|code|OTP)"#, caseInsensitive: true)),
        // "护照号码" too, which luoke-mem's rule (护照号?) misses; "Passport #:", "passport number is".
        ("id", pattern(#"(?:护照(?:号码?)?|passport)(?:\s*+(?:no\b\.?|number|#|是|为|:|：|is\b))*+\s*+([A-Z]{1,2}[0-9]{6,9})\b"#,
                       caseInsensitive: true)),
        // A key or token by its name, the name ending in the word: "api_key: …", "aws_secret_access_key = …",
        // "GITHUB_TOKEN=…" (not "tokenizer.model = …"). A value in quotes up to its quote ("SECRET_KEY = 'k#3m!…'"),
        // else one with a digit in it (not "Token=ETHEREUM_MAINNET").
        ("key", pattern(#"(?:secret|token|api[_-]?key|apikey|access[_-]?key|private[_-]?key|secret[_-]?key)["']?\s*+[:=]\s*+"#
                        + #""([^"\n]{8,200})""#, caseInsensitive: true)),
        ("key", pattern(#"(?:secret|token|api[_-]?key|apikey|access[_-]?key|private[_-]?key|secret[_-]?key)["']?\s*+[:=]\s*+"#
                        + #"'([^'\n]{8,200})'"#, caseInsensitive: true)),
        ("key", pattern(#"(?:secret|token|api[_-]?key|apikey|access[_-]?key|private[_-]?key|secret[_-]?key)["']?\s*+[:=]\s*+"#
                        + #"((?=[^\s"',;]*[0-9])[^\s"',;]{16,})"#, caseInsensitive: true)),
        ("key", pattern(#"(?:\bapi key|\bsecret key|\baccess key|密钥|私钥|秘钥|令牌)\s*+(?:是|为|:|：|=)\s*+["']?"#
                        + #"((?=[^\s"',;，。]*[0-9])[^\s"',;，。]{16,})"#, caseInsensitive: true)),
        ("key", pattern(#"\b(?:bearer|basic)\s++((?=[A-Za-z0-9+/=_.~-]*[0-9])[A-Za-z0-9+/=_.~-]{16,})"#, caseInsensitive: true)),
        // A wallet's words: twelve to twenty-four of them, English or Chinese.
        ("seed", pattern(#"(?:助记词|mnemonic(?: phrase)?|seed phrase|recovery phrase)\s*+(?:是|为|:|：|=)?\s*+"#
                         + #"((?:(?:[a-z]{3,8}|\p{Han})\s++){11,23}(?:[a-z]{3,8}|\p{Han}))"#, caseInsensitive: true)),
        // Recovery codes, each with a digit in it ("3f9a1-b7c2e", not "should only be used once").
        ("recovery", pattern(#"(?:recovery codes?|backup codes?|恢复码|备用码|救援码)\s*+(?:是|为|:|：|=)?\s*+"#
                             + #"((?:(?=[A-Za-z-]*[0-9])[A-Za-z0-9]{4,12}(?:-[A-Za-z0-9]{4,12})?[\s,，、]++){1,15}"#
                             + #"(?=[A-Za-z-]*[0-9])[A-Za-z0-9]{4,12}(?:-[A-Za-z0-9]{4,12})?)"#, caseInsensitive: true)),
    ]

    /// Long, mixed, random: base64 too ("+", "/", "=" at the end; it may follow a "=": "?key=AIza…"). One with a "/"
    /// is a path, not a key, if it starts with one, has a "-" or "_" and no "+" (base64 has one pair or the other), or
    /// its first part, or most of its parts, are words ("Documents/…") (`find`).
    static let random = pattern(#"(?<![A-Za-z0-9/+_-])(?=[A-Za-z0-9_+/-]*[0-9])(?=[A-Za-z0-9_+/-]*[a-z])(?=[A-Za-z0-9_+/-]*[A-Z])"#
                                + #"[A-Za-z0-9_+/-]{32,}={0,2}(?![A-Za-z0-9/+_=-])"#)

    /// A string that is a secret wherever it stands.
    static let alone: [(String, NSRegularExpression)] = [
        ("key", pattern(#"\b(?:sk|pk|rk|ghp|gho|ghs|ghu|glpat|xox[abp])[-_][A-Za-z0-9_-]{16,}"#)),
        ("key", pattern(#"\bAKIA[0-9A-Z]{16}\b"#)),
        ("key", pattern(#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#)),   // a JWT
        ("key", pattern(#"-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY(?: BLOCK)?-----|$)"#)),
        // A long key's later lines, in a part of the text without its BEGIN line: three or more lines like base64,
        // the first with capitals and small letters (not a list of hashes in hex).
        ("key", pattern(#"(?<![A-Za-z0-9+/=])(?=[A-Za-z0-9+/]*[a-z])(?=[A-Za-z0-9+/]*[A-Z])[A-Za-z0-9+/]{40,76}={0,2}"#
                        + #"(?:\s++[A-Za-z0-9+/]{40,76}={0,2}){2,}(?:\s++[A-Za-z0-9+/]{1,76}={0,2})?(?![A-Za-z0-9+/=])"#)),
        ("key", random),
        // An ID number, as written in one or with a space or a hyphen between its parts ("110101 19900307 0017",
        // "110101-1990-0307-0017"; pre-release review, should-fix 4).
        ("id", pattern(#"(?<![0-9])[1-9][0-9]{5}[ -]?(?:19|20)[0-9]{2}[ -]?(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])[ -]?"#
                       + #"[0-9]{3}[0-9Xx](?![0-9])"#)),
    ]

    static let dottedCard = pattern(#"(?<![0-9.])(?:[0-9]{4}\.[0-9]{6}\.[0-9]{4,5}|[0-9]{4}(?:\.[0-9]{4}){2,3}(?:\.[0-9]{1,4})?)"#
                                    + #"(?![0-9]|\.[0-9])"#)

    static func luhn(_ digits: [Int]) -> Bool {
        var total = 0
        for (index, digit) in digits.reversed().enumerated() {
            total += index % 2 == 1 ? (digit > 4 ? digit * 2 - 9 : digit * 2) : digit
        }
        return total % 10 == 0
    }

    /// The credentials in the text: ranges (UTF-16, as `NSString` counts) and kinds, in order, not overlapping.
    /// Looked for through invisible formatting (`Script.isInvisible`): "pass\u{AD}word: …" is a password as keyword
    /// search finds "password" in it, and a value split by a soft hyphen is masked whole. A zero-width space is
    /// looked through both ways, as a word break ("4111…1111\u{200B}12/28" is a card and its expiry) and as nothing
    /// (web pages put them in long keys to wrap them), and what either finds is masked. The ranges are mapped back
    /// onto the text as written, the invisible characters inside them included.
    public static func find(_ text: String) -> [(range: NSRange, kind: String)] {
        guard text.unicodeScalars.contains(where: Script.isInvisible) else { return visible(text) }
        var found = looked(text, breaking: true)
        if text.unicodeScalars.contains("\u{200B}") { found += looked(text, breaking: false) }
        var out: [(range: NSRange, kind: String)] = []
        for (range, kind) in found.sorted(by: { $0.range.location < $1.range.location }) {
            if let last = out.last, range.location < last.range.location + last.range.length {
                let end = max(last.range.location + last.range.length, range.location + range.length)
                out[out.count - 1].range.length = end - last.range.location
            } else {
                out.append((range, kind))
            }
        }
        return out
    }

    /// `visible` on the text without its invisible formatting, a zero-width space a space if `breaking`, the ranges
    /// mapped back.
    private static func looked(_ text: String, breaking: Bool) -> [(range: NSRange, kind: String)] {
        var shown = String.UnicodeScalarView(), origin: [Int] = []   // for each UTF-16 unit of `shown`, its place
        var place = 0
        for scalar in text.unicodeScalars {
            let width = scalar.utf16.count
            if !Script.isInvisible(scalar) {
                shown.append(scalar)
                origin += place..<(place + width)
            } else if breaking, scalar.value == 0x200B {
                shown.append(" ")
                origin.append(place)
            }
            place += width
        }
        return visible(String(shown)).compactMap { range, kind in
            guard range.length > 0, range.location + range.length <= origin.count else { return nil }
            let start = origin[range.location], end = origin[range.location + range.length - 1] + 1
            return (NSRange(location: start, length: end - start), kind)
        }
    }

    /// `find` in text without invisible formatting. Looked for with full-width letters, digits and signs as plain ones
    /// ("１１０１０１…" is an ID number too, and the snippet shows it as written): one UTF-16 unit for one, so the
    /// ranges are the same in the text as written.
    static func visible(_ text: String) -> [(range: NSRange, kind: String)] {
        let text = folded(text)
        let all = NSRange(text.startIndex..., in: text)
        let string = text as NSString
        var found: [(NSRange, String)] = []
        for (kind, regex) in said {
            for match in regex.matches(in: text, range: all) where match.range(at: 1).location != NSNotFound {
                found.append((match.range(at: 1), kind))
            }
        }
        for (kind, regex) in alone {
            for match in regex.matches(in: text, range: all) {
                if regex === random, case let value = string.substring(with: match.range), value.contains("/") {
                    let word = { (part: Substring) in
                        part.count >= 3 && part.allSatisfy(\.isLetter) && part.dropFirst().allSatisfy(\.isLowercase)
                            && part.contains { "aeiouAEIOU".contains($0) }
                    }
                    let parts = value.split(separator: "/")
                    if value.hasPrefix("/") || !value.contains("+") && (value.contains("-") || value.contains("_"))
                        || parts.first.map(word) == true || parts.filter(word).count * 2 > parts.count { continue }
                }
                found.append((match.range, kind))
            }
        }
        found += cards(in: string).map { ($0, "card") }
        // Written with dots between its groups ("4111.1111.1111.1111"; should-fix 7): as a card's are only, so a
        // decimal, a version or an address isn't taken for one.
        for match in dottedCard.matches(in: text, range: all) {
            let digits = string.substring(with: match.range).compactMap(\.wholeNumberValue)
            if (13...19).contains(digits.count), luhn(digits) { found.append((match.range, "card")) }
        }
        var out: [(range: NSRange, kind: String)] = []
        for (range, kind) in found.sorted(by: { ($0.0.location, -$0.0.length) < ($1.0.location, -$1.0.length) }) {
            if let last = out.last, range.location < last.range.location + last.range.length { continue }
            out.append((range, kind))
        }
        return out
    }

    /// Card numbers (UTF-16 ranges): in each run of digit groups (separated by one space or hyphen), the whole run if
    /// it's 13–19 digits and passes Luhn, as before. Else, now, the parts of it that start and end where its groups do,
    /// are grouped as cards are (one group, fours, Amex's 4-6-5 and 4-6-4), are 13–19 digits, pass, and start with
    /// 2–6 (as cards do: Visa, Mastercard, Amex, UnionPay…) unless they start the run. So a number written with its
    /// expiry, its CVV or a phone number beside it is still found ("4111 1111 1111 1111 12/28"; pre-release review,
    /// must-fix 3), and dates and phone numbers aren't taken for one. A "/" ends a run. Of parts that overlap, the one
    /// of the commoner length wins, then the first: a date before a card ("2026-10-23 4111 …") doesn't take half of it.
    static func cards(in text: NSString) -> [NSRange] {
        func isDigit(_ unit: unichar) -> Bool { unit >= 0x30 && unit <= 0x39 }
        let count = text.length
        var out: [NSRange] = []
        var index = 0
        while index < count {
            guard isDigit(text.character(at: index)), index == 0 || !isDigit(text.character(at: index - 1)) else {
                index += 1
                continue
            }
            // The run's groups: where each starts and ends, and its digits.
            var groups: [(start: Int, end: Int)] = []
            var at = index
            while true {
                let start = at
                while at < count, isDigit(text.character(at: at)) { at += 1 }
                groups.append((start, at))
                let separator = at < count ? text.character(at: at) : 0
                guard separator == 0x20 || separator == 0x2D, at + 1 < count, isDigit(text.character(at: at + 1)) else { break }
                at += 1
            }
            index = at
            let digits = groups.map { group in (group.start..<group.end).map { Int(text.character(at: $0)) - 0x30 } }
            let all = digits.flatMap { $0 }
            if (13...19).contains(all.count), luhn(all) {
                out.append(NSRange(location: groups[0].start, length: groups[groups.count - 1].end - groups[0].start))
                continue
            }
            let lengths = [16, 15, 19, 13, 14, 17, 18]   // commoner first
            var parts: [(first: Int, last: Int, rank: Int)] = []
            for first in groups.indices {
                guard first == 0 || (2...6).contains(digits[first].first ?? 0) else { continue }
                var length = 0
                for last in first..<groups.count {
                    length += digits[last].count
                    if length > 19 { break }
                    let sizes = digits[first...last].map(\.count)
                    let grouped = sizes.count == 1 || sizes == [4, 6, 5] || sizes == [4, 6, 4]
                        || sizes.dropLast().allSatisfy { $0 == 4 } && sizes[sizes.count - 1] <= 4
                    guard length >= 13, grouped, luhn(digits[first...last].flatMap { $0 }) else { continue }
                    parts.append((first, last, lengths.firstIndex(of: length)!))
                }
            }
            var taken = Set<Int>()
            for part in parts.sorted(by: { ($0.rank, $0.first) < ($1.rank, $1.first) })
            where !(part.first...part.last).contains(where: taken.contains) {
                taken.formUnion(part.first...part.last)
                out.append(NSRange(location: groups[part.first].start, length: groups[part.last].end - groups[part.first].start))
            }
        }
        return out.sorted { $0.location < $1.location }
    }

    /// What a table's cell says the cells under it (as a column's name) or after it (as a label: "WiFi 密码 | 8888…")
    /// are. The word ends the cell, a colon, a note in brackets or a number after it aside: "WiFi 密码", "密码：",
    /// "Password (plain)", "密码2", not "密码学", "密码提示", "bypass". "PIN" only in capitals ("Pin" is a pinout's).
    static let labels: [(kind: String, words: [String])] = [
        ("password", ["密码", "密碼", "口令", "password", "passwords", "passwd", "pwd", "pw", "pass", "passcode", "pin码",
                      "pin code", "passphrase", "pass phrase", "パスワード", "パスコード", "暗証番号", "비밀번호", "패스워드",
                      "비번"]),
        ("code", ["验证码", "校验码", "动态码", "安全码", "verification code", "totp", "otp", "2fa"]),
        ("key", ["密钥", "私钥", "秘钥", "secret", "client secret", "token", "api key", "apikey", "api_key", "access key",
                 "secret key"]),
        ("seed", ["助记词", "mnemonic", "seed phrase"]),
        ("recovery", ["恢复码", "备用码", "recovery code", "recovery codes", "backup codes"]),
    ]

    /// The kind of credential a cell names (`labels`), if it's a short label that ends with one of the words.
    static func label(_ cell: String) -> String? {
        var text = folded(cell).trimmingCharacters(in: .whitespaces)
        // What may come after the word: a colon, a note in brackets, a number.
        while let last = text.last, ":：".contains(last) || last.isNumber || last == " " { text.removeLast() }
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") { text = String(text[..<open]) }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 24 else { return nil }
        if text.hasSuffix("PIN") { return "password" }
        text = text.lowercased()
        for (kind, words) in labels {
            for word in words where text.hasSuffix(word) {
                // An English word whole: not the end of a longer one.
                let before = text.dropLast(word.count).last
                if word.first!.isASCII, let before, before.isASCII, before.isLetter { continue }
                return kind
            }
        }
        return nil
    }

    /// Whether a table's cell looks like a value rather than a column's name: a digit or a sign in it, or capitals
    /// inside a long word.
    static func valueLike(_ cell: String) -> Bool {
        if cell.contains(where: { $0.isNumber || "!@#$%^&*_+=?~".contains($0) }) { return true }
        return cell.count >= 6 && !cell.contains(" ") && cell.dropFirst().contains(where: \.isUppercase)
            && cell.contains(where: \.isLowercase)
    }

    /// Whether a table's cell looks like a password: 6 to 64 characters, no space, not an address (an "@", "://",
    /// "www."), and at least three kinds of character among small letters, capitals, digits and signs
    /// (!#$%^&*+=?~). `withSign`: a sign has to be one of them (for a column whose name says something else).
    static func passwordLike(_ cell: String, withSign: Bool = false) -> Bool {
        guard (6...64).contains(cell.count), !cell.contains(where: \.isWhitespace), !cell.contains("@"),
              !cell.contains("://"), !cell.lowercased().hasPrefix("www.") else { return false }
        let sign = cell.contains { "!#$%^&*+=?~".contains($0) }
        let kinds = [cell.contains(where: \.isLowercase), cell.contains(where: \.isUppercase),
                     cell.contains { $0.isASCII && $0.isNumber }, sign]
        return kinds.filter { $0 }.count >= 3 && (sign || !withSign)
    }

    /// U+FF01–FF5E as U+0021–007E, the ideographic space as a space, the other digits of the Basic Multilingual Plane
    /// (Arabic-Indic, Devanagari, Thai…) as 0–9 (should-fix 7); everything else as it is. One UTF-16 unit for one:
    /// digits past the BMP stay as they are.
    static func folded(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFF01...0xFF5E: scalars.append(Unicode.Scalar(scalar.value - 0xFEE0)!)
            case 0x3000: scalars.append(" ")
            case 0x80...0xFFFF where scalar.properties.numericType == .decimal:
                scalars.append(Unicode.Scalar(0x30 + UInt8(scalar.properties.numericValue ?? 0)))
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// What a credential becomes: what it was ("〔验证码〕"); a card or ID number with its last 4 ("〔卡号 ****1111〕").
    static func replacement(_ value: String, kind: String) -> String {
        let name = names[kind] ?? kind
        guard kind == "card" || kind == "id" else { return "〔\(name)〕" }
        return "〔\(name) ****\(String(value.filter { $0.isLetter || $0.isNumber }.suffix(4)))〕"
    }

    /// The text with each credential replaced (`replacement`), everything else as it is.
    public static func mask(_ text: String) -> String { mask(text, keeping: 0).text }

    /// `mask`, and where a place in the text (a UTF-16 offset) is in what it gives: a place inside a credential is at
    /// the start of what replaced it.
    static func mask(_ text: String, keeping place: Int) -> (text: String, place: Int) {
        let found = find(text)
        guard !found.isEmpty else { return (text, place) }
        let string = text as NSString
        var out = "", last = 0, moved = place
        for (range, kind) in found {
            out += string.substring(with: NSRange(location: last, length: range.location - last))
            let replaced = replacement(string.substring(with: range), kind: kind)
            if place >= range.location + range.length {
                moved += replaced.utf16.count - range.length
            } else if place > range.location {
                moved = out.utf16.count
            }
            out += replaced
            last = range.location + range.length
        }
        return (out + string.substring(from: last), moved)
    }
}
