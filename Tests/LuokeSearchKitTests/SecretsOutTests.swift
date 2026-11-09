import Foundation
import Testing
@testable import LuokeSearchKit

/// Credentials masked as they go out (10-22): the index keeps the text as written, so a full
/// ID or card number finds its file; what reaches the agent (titles, snippets, the card, the answer's text) has a card
/// or ID number down to its last 4 and a password, code or key gone whole. Every sample is made up.
extension ReadsPictures {
    struct SecretsOutTests {
        static let lines = ["护照号 E12345678，有效期到 2031 年", "身份证 110101199003070017",
                            "信用卡 4111 1111 1111 1111 订酒店用", "接口 key: sk-abc123def456ghi789jkl0",
                            "登录验证码 482913，5 分钟内有效", "邮箱密码是 Lk-2026-qwe，别外传"]
        /// Each made-up value, what it goes out as, and a piece of it that mustn't go out either.
        static let samples: [(raw: String, out: String, piece: String)] = [
            ("E12345678", "〔证件号 ****5678〕", "E1234"),
            ("110101199003070017", "〔证件号 ****0017〕", "11010119"),
            ("4111 1111 1111 1111", "〔卡号 ****1111〕", "4111 1111"),
            ("sk-abc123def456ghi789jkl0", "〔密钥〕", "def456"),
            ("482913", "〔验证码〕", "482913"),
            ("Lk-2026-qwe", "〔密码〕", "Lk-2026"),
        ]

        final class Corpus {
            let scratch: Scratch
            let store: IndexStore

            init(_ files: [String: Data]) throws {
                scratch = try Scratch()
                for (path, data) in files { try scratch.write("files/" + path, data: data) }
                store = try scratch.store()
                let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
                _ = try indexer.sync([scratch.path + "/files"])
                try indexer.readPending()
            }

            static func travel() throws -> Corpus {
                try Corpus(["出行/出行资料.md": Data(("# 出行资料\n" + lines.joined(separator: "\n")).utf8),
                            "Screenshot 2026-10-22 at 09.30.00.png":
                                try Drawn.png(Drawn.picture(lines, width: 1600, height: 700))])
            }

            /// A tool called as the agent calls it: the whole answer (text, hits, card) as JSON text.
            func agentAnswer(_ query: String) throws -> String { try call("search_query", ["query": query]) }

            func call(_ tool: String, _ arguments: [String: Any]) throws -> String {
                let service = try SearchService(directory: DataDirectory(url: scratch.url.appendingPathComponent("data")),
                                                hub: nil, opener: Opened().opener, home: scratch.path)
                // As if tapped on the card (search_open needs it; the read-only tools don't look).
                let tap = ["surfaceId": "q-1", "componentId": "b1", "at": "2026-10-22T10:00:00+08:00"]
                let answer = AgentTools.server(service).handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                                "params": ["name": tool, "arguments": arguments,
                                                                           "_meta": ["ai.luoke/user-action": tap]]])
                return String(decoding: try JSONSerialization.data(withJSONObject: answer ?? [:]), as: UTF8.self)
            }
        }

        /// Case aside: OCR reads "Lk-2026-qwe" as "LK-2026-qwe".
        static func carriesNone(_ text: String, _ comment: Comment) {
            let text = text.lowercased()
            for sample in samples {
                #expect(!text.contains(sample.raw.lowercased()), "\(comment): \(sample.raw)")
                #expect(!text.contains(sample.piece.lowercased()), "\(comment): \(sample.piece)")
            }
            #expect(!text.contains("4111111111111111"), comment)
        }

        @Test("Out to the agent, a card or ID number keeps its last 4; a password, code or key goes whole")
        func goingOut() throws {
            let corpus = try Corpus.travel()
            // Each hit: the document's, and the screenshot's as OCR read it.
            let hits = try Searcher(store: corpus.store).search("护照 身份证").hits
            for title in ["出行资料.md", "Screenshot 2026-10-22 at 09.30.00.png"] {
                let snippet = hits.first { $0.title == title }?.snippet ?? ""
                for sample in Self.samples { #expect(snippet.contains(sample.out), "\(title): \(sample.out) in \(snippet)") }
                Self.carriesNone(snippet, "\(title)")
            }
            let answer = try corpus.agentAnswer("护照 身份证")
            #expect(answer.contains("出行资料.md"))
            #expect(answer.contains("Screenshot"))
            Self.carriesNone(answer, "search_query")
            #expect(answer.contains("护照号 〔证件号 ****5678〕，有效期到 2031 年"))   // the words around them stay
            withExtendedLifetime(corpus) {}
        }

        @Test("The index keeps the text as written: a full ID, card or passport number finds its file, masked")
        func fullNumbersFindTheirFile() throws {
            let corpus = try Corpus.travel()
            var indexed = ""
            try corpus.store.db.query("SELECT body FROM fts") { indexed += ($0.text(0) ?? "") + "\n" }
            for sample in Self.samples { #expect(indexed.contains(sample.raw), "\(sample.raw) in the index") }
            let searcher = Searcher(store: corpus.store)
            for (number, out) in [("110101199003070017", "〔证件号 ****0017〕"), ("4111 1111 1111 1111", "〔卡号 ****1111〕"),
                                  ("E12345678", "〔证件号 ****5678〕"), ("sk-abc123def456ghi789jkl0", "〔密钥〕")] {
                let hit = try searcher.search(number).hits.first { $0.title == "出行资料.md" }
                #expect(hit != nil, "\(number)")
                #expect(hit?.snippet?.contains(out) == true, "\(number): \(hit?.snippet ?? "")")
                Self.carriesNone(hit?.snippet ?? "", "snippet for \(number)")
                // As the agent gets it, too.
                let answer = try corpus.agentAnswer(number)
                #expect(answer.contains("出行资料.md"), "\(number)")
                Self.carriesNone(answer, "search_query \(number)")
            }
            withExtendedLifetime(corpus) {}
        }

        @Test("A number written full-width is masked as it goes out, and found by its plain digits")
        func fullWidth() throws {
            let corpus = try Corpus(["证件.txt": Data("身份证 １１０１０１１９９００３０７００１７，卡号 ４１１１ １１１１ １１１１ １１１１".utf8)])
            let hit = try Searcher(store: corpus.store).search("110101199003070017").hits.first
            #expect(hit?.title == "证件.txt")
            let snippet = hit?.snippet ?? ""
            #expect(snippet.contains("〔证件号 ****００１７〕"), "\(snippet)")
            #expect(snippet.contains("〔卡号 ****１１１１〕"), "\(snippet)")
            #expect(!snippet.contains("１１０１０１"), "\(snippet)")
            #expect(!snippet.contains("４１１１"), "\(snippet)")
            withExtendedLifetime(corpus) {}
        }

        @Test("A worksheet's cells are masked under their column's name")
        func sheets() throws {
            let sheet = ZipWriter.xlsx(sheet: "名单", shared: ["姓名", "护照号", "有效期", "账号", "密码", "验证码", "张三",
                                                                "E12345678", "alice", "Hunter-2026x"],
                                       rows: [["s:0", "s:1", "s:2", "s:3", "s:4", "s:5"], ["s:6", "s:7", "2031", "s:8", "s:9", "482913"]])
            let corpus = try Corpus(["名单.xlsx": sheet])
            let snippet = try Searcher(store: corpus.store).search("张三").hits.first?.snippet ?? ""
            for shown in ["护照号：〔证件号 ****5678〕", "密码：〔密码〕", "验证码：〔验证码〕", "账号：alice"] {
                #expect(snippet.contains(shown), "\(shown) in \(snippet)")
            }
            for raw in ["E12345678", "Hunter-2026x", "482913"] { #expect(!snippet.contains(raw), "\(raw) in \(snippet)") }
            #expect(try Searcher(store: corpus.store).search("E12345678").hits.first?.title == "名单.xlsx")
            withExtendedLifetime(corpus) {}
        }

        @Test("A card number wrapped over two lines is one, and masked")
        func wrapped() throws {
            let corpus = try Corpus(["转账.txt": Data("请转到卡号 4111 1111\n1111 1111 尽快\n另一张 4111-1111\r\n1111-1111 不用".utf8)])
            let snippet = try Searcher(store: corpus.store).search("尽快").hits.first?.snippet ?? ""
            #expect(snippet.contains("请转到卡号 〔卡号 ****1111〕 尽快"), "\(snippet)")
            #expect(snippet.contains("另一张 〔卡号 ****1111〕 不用"), "\(snippet)")
            #expect(!snippet.contains("4111"), "\(snippet)")
            withExtendedLifetime(corpus) {}
        }

        @Test("Asked for a credential itself, the snippet is where it was, masked")
        func askedForTheValue() throws {
            let filler = String(repeating: "这里是占位用的普通句子，", count: 60)
            let corpus = try Corpus(["长.txt": Data((filler + "护照号 E12345678，有效期到 2031 年。" + filler
                                                     + "备用钥匙 AKIAABCDEFGHIJKLMNOP 放在抽屉里。" + filler).utf8)])
            let searcher = Searcher(store: corpus.store)
            for (asked, shown) in [("E12345678", "护照号 〔证件号 ****5678〕，有效期"), ("AKIAABCDEFGHIJKLMNOP", "备用钥匙 〔密钥〕 放在")] {
                let snippet = try searcher.search(asked).hits.first?.snippet ?? ""
                #expect(snippet.contains(shown), "\(asked): \(snippet)")
                #expect(!snippet.contains(asked), "\(asked): \(snippet)")
            }
            withExtendedLifetime(corpus) {}
        }

        @Test("A file whose name holds an ID number: its title, and the answer to opening it, keep the last 4")
        func names() throws {
            let corpus = try Corpus(["身份证 110101199003070017.txt": Data("复印件放在书房的抽屉里".utf8)])
            let hit = try Searcher(store: corpus.store).search("110101199003070017").hits.first
            #expect(hit?.title == "身份证 〔证件号 ****0017〕.txt")
            #expect(hit?.why == "名字对得上")
            let opened = try corpus.call("search_open", ["id": hit?.id ?? ""])
            #expect(opened.contains("〔证件号 ****0017〕"), "\(opened)")
            #expect(!opened.contains("11010119"), "\(opened)")
            let revealed = try corpus.call("search_open", ["id": hit?.id ?? "", "reveal": true])
            #expect(revealed.contains("〔证件号 ****0017〕"), "\(revealed)")
            #expect(!revealed.contains("11010119"), "\(revealed)")
            withExtendedLifetime(corpus) {}
        }

        @Test("A credential at a snippet's edge isn't cut out of its mask")
        func snippetEdges() throws {
            // The snippet starts 53 characters before the word asked for. Spaced so that, were it cut before being
            // masked, it would start right after "密码是 " (the password no longer said to be one) and four
            // characters into the card (twelve digits left: no longer a full card number).
            let filler = String(String(repeating: "这里是占位用的普通句子，", count: 40).prefix(120))
            let tail = String(repeating: "后面还有别的内容。", count: 30)
            let password = filler + "邮箱密码是 " + "Lk-2026-qwe" + String(filler.prefix(42)) + "发票" + tail
            let card = filler + "尾款用这张卡 " + "4111 1111 1111 1111" + String(filler.prefix(39)) + "收据" + tail
            let corpus = try Corpus(["a.txt": Data(password.utf8), "b.txt": Data(card.utf8)])
            let searcher = Searcher(store: corpus.store)
            let first = try searcher.search("发票").hits.first { $0.title == "a.txt" }?.snippet ?? ""
            #expect(first.contains("〔密码〕"), "\(first)")
            #expect(!first.contains("Lk-2026"), "\(first)")
            let second = try searcher.search("收据").hits.first { $0.title == "b.txt" }?.snippet ?? ""
            #expect(second.contains("〔卡号"), "\(second)")
            #expect(!second.contains("1111 1111"), "\(second)")
            withExtendedLifetime(corpus) {}
        }
    }
}
