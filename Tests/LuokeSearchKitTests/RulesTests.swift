import Foundation
import Testing
@testable import LuokeSearchKit

struct RulesTests {
    @Test("Files named like passwords, keys and certificates are never read", arguments: [
        "密码.txt", "我的密碼.docx", "银行口令.md", "私钥备份.txt", "钱包助记词.txt", "passwords.xlsx", "My Passwords.docx",
        "aws-credentials.csv", "github_recovery_codes.txt", "api-key.txt", "API Keys.md", "id_rsa", "id_ed25519.pub",
        ".env", ".env.local", "server.pem", "cert.p12", "vault.kdbx", "secrets.md", "パスワード.txt",
    ])
    func credentialFiles(_ name: String) {
        #expect(Rules.isCredentialFile(name))
        #expect(Rules.classify(URL(fileURLWithPath: "/x/" + name)) != .index(.doc))
    }

    @Test("Ordinary names that only look a bit like one are read", arguments: [
        "secretary-notes.docx", "Token economics.md", "Key dates.txt", "毕业证书.pdf", "keynote.pdf", "租赁合同.pdf",
        "passport-photo.jpg",
    ])
    func ordinaryNames(_ name: String) {
        #expect(!Rules.isCredentialFile(name))
    }

    @Test("#18: a Keynote deck saved as one file (.key, a zip) isn't a credential; a key file named .key is")
    func keynoteOrKey() throws {
        let scratch = try Scratch()
        let zip = ZipWriter.make([("index.apxl", "<keynote/>")])   // what a Keynote deck saved as one file is
        let deck = try scratch.write("files/Q3 review.key", data: zip)
        let upper = try scratch.write("files/Launch.KEY", data: zip)
        // A made-up key, its first line in two pieces: the public tree's scan takes a whole one for a real key.
        let pem = try scratch.write("files/server.key", "-----BEGIN " + "PRIVATE KEY-----\n"
                                    + "MIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEAAkEA\n-----END PRIVATE KEY-----\n")
        let empty = try scratch.write("files/empty.key", data: Data())
        let named = try scratch.write("files/api key backup.key", data: zip)   // a zip, but its name says credential
        let paired = try scratch.write("files/private.key", data: zip)          // so does "private" with "key"
        #expect(Rules.classify(deck) == .ignore)
        #expect(Rules.classify(upper) == .ignore)
        #expect(Rules.classify(pem) == .skip("credential file"))
        #expect(Rules.classify(empty) == .skip("credential file"))
        #expect(Rules.classify(named) == .skip("credential file"))
        #expect(Rules.classify(paired) == .skip("credential file"))
        #expect(Rules.classify(URL(fileURLWithPath: scratch.path + "/files/gone.key")) == .skip("credential file"))
        // Contents only in iCloud: not opened (that would download it), so it stays a credential.
        #expect(Rules.isZip(deck))
        #expect(!Rules.isZip(deck, isDataless: { _ in true }))
        // Walking the folder: the deck is passed over like any type that isn't read, the key reported.
        let walk = Crawler(home: scratch.path).walk([scratch.path + "/files"])
        #expect(walk.skipped["credential file"] == 4)
        #expect(walk.files.isEmpty)
    }

    @Test func kindsByName() {
        #expect(Rules.kind(of: URL(fileURLWithPath: "/x/a.MD")) == .doc)
        #expect(Rules.kind(of: URL(fileURLWithPath: "/x/a.pdf")) == .pdf)
        #expect(Rules.kind(of: URL(fileURLWithPath: "/x/IMG_1001.heic")) == .image)
        #expect(Rules.kind(of: URL(fileURLWithPath: "/x/截屏2026-09-20 上午10.05.33.png")) == .screenshot)
        #expect(Rules.kind(of: URL(fileURLWithPath: "/x/Screenshot 2026-10-02 at 11.20.51.png")) == .screenshot)
        #expect(Rules.kind(of: URL(fileURLWithPath: "/x/memo.m4a")) == .audio)
        #expect(Rules.kind(of: URL(fileURLWithPath: "/x/clip.mkv")) == .video)
        #expect(Rules.kind(of: URL(fileURLWithPath: "/x/main.swift")) == nil)
        #expect(Rules.kind(of: URL(fileURLWithPath: "/x/data.json")) == nil)
    }

    @Test func typeScriptIsNotVideo() throws {
        let scratch = try Scratch()
        let file = try scratch.write("app.ts", String(repeating: "export const x = 1;\n", count: 40))
        #expect(Rules.kind(of: file) == nil)
        var stream = Data(count: 188 * 4)
        for packet in 0..<4 { stream[packet * 188] = 0x47 }
        #expect(Rules.kind(of: try scratch.write("clip.ts", data: stream)) == .video)
    }

    @Test func foldersSkipped() {
        let home = "/home/someone"
        let skip = { (path: String) in Rules.skipReason(folder: URL(fileURLWithPath: path), home: home, excluded: [home + "/Old"]) }
        #expect(skip(home + "/.ssh") != nil)
        #expect(skip(home + "/Library") != nil)
        #expect(skip(home + "/Code/app/node_modules") != nil)
        #expect(skip(home + "/Media/cache.noindex") != nil)
        #expect(skip(home + "/Old/2019") != nil)
        #expect(skip(home + "/Documents/Library") == nil)
        #expect(skip(home + "/Oldies") == nil)
        #expect(skip(home + "/Documents") == nil)
    }

    @Test func codeProjectsOnlyGiveScreenshots() {
        #expect(Rules.isProject(["README.md", "Package.swift", "Sources"]))
        #expect(Rules.isProject(["App.xcodeproj"]))
        #expect(!Rules.isProject(["合同.pdf", "notes.md"]))
        let inProject = { (name: String) in Rules.classify(URL(fileURLWithPath: "/p/" + name), inProject: true) }
        #expect(inProject("README.md") == .skip("in a code project"))
        #expect(inProject("Screenshot 2026-10-01 at 10.00.00.png") == .index(.screenshot))
    }
}
