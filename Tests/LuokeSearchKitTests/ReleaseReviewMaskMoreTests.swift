import Foundation
import Testing
@testable import LuokeSearchKit

// The pre-release security review (10-23), should-fix 7 and what was listed then as not yet looked after (10-26:
// done now): PINs, the Japanese and Korean words, passphrases with spaces, passwords over 64 characters, cards
// written with dots, Arabic-Indic digits, "the password for the WiFi is …", folders' names. The samples are the
// review's own (made up); so is everything else here.
struct ReleaseReviewMaskMoreTests {
    static let leaked: [(text: String, secret: String)] = [
        // PINs.
        ("PIN: 7391", "7391"),
        ("PIN码 864209", "864209"),
        ("银行卡 PIN 码是 482913", "482913"),
        ("My PIN is 4821, don't tell", "4821"),
        ("pin code: 5521", "5521"),
        ("SIM PIN：０９１７", "０９１７"),
        ("银行卡PIN码：482913", "482913"),
        ("SIM卡PIN：1234", "1234"),
        ("手机PIN码是1234", "1234"),
        ("PIN No. 4821", "4821"),
        ("PIN 번호 5521", "5521"),
        ("PIN No.: 7391", "7391"),
        ("PIN is: 7391", "7391"),
        ("PINコード：1234", "1234"),
        ("The PIN for the safe is 4821", "4821"),
        // Japanese and Korean.
        ("パスワード: Tr0ub4dor9x", "Tr0ub4dor9x"),
        ("Wi-Fiのパスワードは「abc12345」です", "abc12345"),
        ("ルーターのパスワードは home2026! です", "home2026!"),
        ("暗証番号：4821", "4821"),
        ("비밀번호: qwer1234!", "qwer1234!"),
        ("와이파이 비밀번호는 home2026! 입니다", "home2026!"),
        ("공유기 패스워드: admin7788", "admin7788"),
        ("비번 1234abcd", "1234abcd"),
        ("와이파이 비번 1234", "1234"),
        ("パスワード abc12345", "abc12345"),
        ("암호: qwer1234", "qwer1234"),
        ("暗証番号 4821", "4821"),
        ("パスワードを abc123! に変更", "abc123!"),
        ("비밀번호를 qwer1234!로 바꿨어요", "qwer1234!"),
        // Passphrases with spaces.
        ("密码是 correct horse battery staple", "horse battery staple"),
        ("密码是 correct horse battery staple 记得改", "horse battery staple"),
        ("Password: correct horse battery staple (changed in May)", "horse battery staple"),
        ("新密码设为 purple monkey dishwasher lamp", "monkey dishwasher"),
        ("Password: Correct Horse Battery Staple", "Horse Battery"),
        ("my password is correct horse battery staple 42.", "horse battery"),
        ("密码是：correct horse battery staple", "horse battery"),
        ("密码是“purple monkey dishwasher”", "monkey dishwasher"),
        ("passphrase: Tr0ub4dor&3", "Tr0ub4dor&3"),
        // Longer than 64.
        ("密码：" + String(repeating: "Ab3$", count: 20), "Ab3$Ab3$Ab3$Ab3$"),
        ("password=" + String(repeating: "x9Y", count: 30) + " end", String(repeating: "x9Y", count: 5)),
        ("WiFi密码" + String(repeating: "8", count: 70), "88888888"),
        // Cards with dots, and in Arabic-Indic digits.
        ("Visa 4111.1111.1111.1111 到期 12/28", "1111.1111"),
        ("Card ४१११ ११११ ११११ ११११", "११११ ११११"),
        ("บัตร ๔๑๑๑๑๑๑๑๑๑๑๑๑๑๑๑", "๑๑๑๑๑๑๑๑"),
        ("Amex 3782.822463.10005", "822463"),
        ("رقم البطاقة ٤١١١ ١١١١ ١١١١ ١١١١", "١١١١ ١١١١"),
        ("کارت ۴۱۱۱۱۱۱۱۱۱۱۱۱۱۱۱", "۱۱۱۱۱۱۱۱"),
        ("身份证 ١١٠١٠١١٩٩٠٠٣٠٧٠٠١٧", "١٩٩٠٠٣٠٧"),
        // What it's for, between.
        ("The password for the WiFi is Abc12345", "Abc12345"),
        ("The password to the router was admin123!", "admin123!"),
        ("Password for guest WiFi: Gu3st-2026", "Gu3st-2026"),
        ("the passwords for both accounts are Spring2026", "Spring2026"),
        ("The password for the office printer on floor three is Pr1nt3r!", "Pr1nt3r!"),
        ("the password for wifi is now Abc12345", "Abc12345"),
        ("password for the guest WiFi = Gu3st2026", "Gu3st2026"),
        ("password for: Abc12345", "Abc12345"),
    ]

    @Test("Should-fix 7 and the phrasings listed then: masked", arguments: leaked)
    func masked(sample: (text: String, secret: String)) {
        let out = Secrets.mask(sample.text)
        #expect(!out.contains(sample.secret), "\(out)")
        #expect(out.contains("〔"), "\(out)")
    }

    /// Text with the words in it, or numbers like these, that isn't a credential.
    static let plain = [
        "PIN 码的作用是什么", "Pin 13 is GPIO", "Pin 2024 is GPIO", "SPIN 2000 rpm", "PIN-1234 型号", "PIN 1234 型号",
        "PIN 2026 年发布", "PIN: 123456789", "the PIN 1000 series", "Pin: 2400 baud", "pin 一下这条消息",
        "パスワードを忘れた場合", "パスワード：未設定", "パスワードは変更されました", "비밀번호를 변경하세요",
        "비밀번호는 영문과 숫자를 섞어 주세요", "パスワードは Google アカウントと同じです", "パスワード：8〜16文字",
        "비밀번호는 8~16자로 설정", "パスワードは2024年に変更しました", "암호화 방식은 AES256",
        "密码是 to be decided later", "the password is stored in the vault", "the password was never shared with anyone",
        "The password is correct and you can log in", "The password is something only Bob knows here",
        "密码规则：至少 8 位", "the password for the account is incorrect",
        "The password for this account has expired", "the password for the island is somewhere",
        "版本 1.2.3.4", "IP 192.168.1.100", "π = 3.14159265358979323", "金额 1234.5678 元", "坐标 37.7749,-122.4194",
        "4111.1111 是两段", "电话 ٠١٢٣ ٤٥٦ ٧٨٩", "build 1234.5678.9012.3456", "v1.4111.1111.1111.1111",
        "序号 4111.1111.1111.1111.1111.1111", "序号 4111.1111.1111.11111",
    ]

    @Test("Ordinary text near these phrasings isn't masked", arguments: plain)
    func notMasked(text: String) {
        #expect(Secrets.mask(text) == text)
    }

    @Test("A passphrase is masked whole, a card with dots keeps its last 4, Arabic-Indic digits are kept as written")
    func asReplaced() {
        #expect(Secrets.mask("密码是 correct horse battery staple") == "密码是 〔密码〕")
        #expect(Secrets.mask("Visa 4111.1111.1111.1111 到期") == "Visa 〔卡号 ****1111〕 到期")
        #expect(Secrets.mask("卡 ٤١١١ ١١١١ ١١١١ ١١١١") == "卡 〔卡号 ****١١١١〕")
        #expect(Secrets.mask("PIN码 864209 别忘") == "PIN码 〔密码〕 别忘")
        #expect(Secrets.mask("パスワードは「abc12345」です") == "パスワードは「〔密码〕」です")
        #expect(Secrets.mask("银行卡PIN码：482913") == "银行卡PIN码：〔密码〕")
        #expect(Secrets.mask("Password: Correct Horse Battery Staple") == "Password: 〔密码〕")
        #expect(Secrets.mask("my password is correct horse battery staple 42.") == "my password is 〔密码〕.")
        // In quotes, the quotes go with it, as a quoted value's do after "密码是".
        #expect(Secrets.mask("密码是“purple monkey dishwasher”") == "密码是〔密码〕")
        // Over 64 characters, to its end; Chinese after it isn't taken.
        #expect(Secrets.mask("WiFi密码" + String(repeating: "8", count: 70)) == "WiFi密码〔密码〕")
        #expect(Secrets.mask("密码：" + String(repeating: "x9", count: 40) + "然后记得改") == "密码：〔密码〕然后记得改")
        // A sentence after "密码是" isn't a passphrase: only its first word goes, as on main. Nor words with more
        // words after them.
        #expect(Secrets.mask("密码是 correct horse battery staple and nothing else")
                == "密码是 〔密码〕 horse battery staple and nothing else")
        #expect(Secrets.mask("密码是 one of the things we never talk about in this house anyway")
                == "密码是 〔密码〕 of the things we never talk about in this house anyway")
        // A rule said after a colon isn't a passphrase: only its first word goes, as on main (the colon's rule).
        #expect(Secrets.mask("Password: must be at least eight characters") == "Password: 〔密码〕 be at least eight characters")
        #expect(Secrets.mask("password: see the vault entry for details") == "password: 〔密码〕 the vault entry for details")
    }

    @Test("A table whose column is named in Japanese or Korean is masked as a Chinese or English one is")
    func otherLabels() {
        for name in ["パスワード", "暗証番号", "비밀번호", "패스워드", "비번", "passphrase"] {
            #expect(Secrets.label(name) == "password")
            #expect(Secrets.label("新しい" + name) == "password")
        }
        #expect(Secrets.label("パスワード変更") == nil)
    }

    @Test("A folder's name goes out masked in plans and the outbox, as a file's title does")
    func folderNames() throws {
        let setup = try SetupHome()
        let folder = setup.home + "/Desktop/身份证 110101199003070017 资料"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        #expect(setup.service.display(folder) == "身份证 〔证件号 ****0017〕 资料")
        var change = SearchService.Change()
        change.addFolders = [folder]
        let (_, lines) = try setup.service.plan(change)
        let sent = lines.map(\.text).joined(separator: "\n")
        #expect(!sent.contains("19900307"), "\(sent)")
        #expect(sent.contains("〔证件号 ****0017〕"))
        // The path itself still goes out as it is (10-22), in the card's small print and the outbox's id: what
        // this checks is the name only.
    }
}
