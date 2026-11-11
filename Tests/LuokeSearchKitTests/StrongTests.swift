import Foundation
import Testing
@testable import LuokeSearchKit

/// `Hit.strong` is a result's own, not its place in the list: the window sets it beside other apps' sure results.
struct StrongTests {
    let space = "embeddinggemma-2/1"

    func signals(z: Double? = nil, cosine: Double? = nil, modality: String? = nil, share: Double = 0,
                 name: Double = 0) -> Hit.Signals {
        Hit.Signals(z: z, cosine: cosine, modality: modality, share: share, nameShare: name)
    }

    @Test func theWordsInTheName() {
        #expect(Searcher.isStrong(signals(share: 1, name: 1), space: nil))
        #expect(!Searcher.isStrong(signals(share: 1, name: 0.5), space: nil))
        // All the words in the text, no vectors: found, not sure (as a mail with them in its body only).
        #expect(!Searcher.isStrong(signals(share: 1), space: space))
        #expect(!Searcher.isStrong(nil, space: space))
    }

    @Test func closeInMeaningByModality() {
        #expect(Searcher.isStrong(signals(z: 2.5, cosine: 0.72, modality: "text"), space: space))
        #expect(!Searcher.isStrong(signals(z: 2.5, cosine: 0.71, modality: "text"), space: space))
        #expect(Searcher.isStrong(signals(z: 2.5, cosine: 0.70, modality: "image"), space: space))
        #expect(!Searcher.isStrong(signals(z: 2.5, cosine: 0.73, modality: "audio"), space: space))
        #expect(Searcher.isStrong(signals(z: 2.5, cosine: 0.74, modality: "audio"), space: space))
        // Close but not standing out among the rest.
        #expect(!Searcher.isStrong(signals(z: 1.9, cosine: 0.9, modality: "text"), space: space))
        #expect(Searcher.isStrong(signals(z: 2.0, cosine: 0.9, modality: "text"), space: space))
        #expect(!Searcher.isStrong(signals(z: 2.5, cosine: 0.69, modality: "image"), space: space))
        // Another vector space isn't measured: only names make a result sure there.
        #expect(!Searcher.isStrong(signals(z: 3, cosine: 0.9, modality: "text"), space: "other/1"))
        #expect(!Searcher.isStrong(signals(z: 3, cosine: 0.9, modality: "text"), space: nil))
    }

    func hit(_ title: String, strong: Bool, score: Double = 1) -> Hit {
        Hit(id: title, kind: .doc, title: title, path: "/a/" + title, where: nil, date: "2026-11-09", snippet: nil,
            why: "", score: score, strong: strong)
    }

    /// The card's texts in order (titles and the lines under them).
    func texts(_ hits: [Hit]) -> [String] {
        let answer = SearchAnswer(hits: hits, partial: false, partialReason: nil, confident: nil, tookMs: 1)
        let messages = Cards.results(answer, query: "护照", surfaceID: "s")
        let components = messages.compactMap { ($0["updateComponents"] as? [String: Any])?["components"] as? [[String: Any]] }
            .flatMap { $0 }
        return components.compactMap { $0["text"] as? String }
    }

    @Test func theCardSaysMaybeOnlyBesideSureOnes() throws {
        let mixed = texts([hit("护照.pdf", strong: true), hit("旅行清单.md", strong: false)])
        let maybe = mixed.indices.filter { mixed[$0].contains("可能相关") }
        // Once, under the second row's title.
        #expect(maybe.count == 1)
        let second = try #require(mixed.firstIndex(of: "旅行清单.md"))
        #expect(maybe.first.map { $0 > second } == true)
        #expect(!mixed.contains(Cards.noneSure))
        // None sure: one line says so, not 「可能相关」 on every row.
        let none = texts([hit("旅行清单.md", strong: false), hit("行李.md", strong: false)])
        #expect(none.contains(Cards.noneSure))
        #expect(none.filter { $0.contains("可能相关") && $0 != Cards.noneSure }.isEmpty)
        #expect(!texts([hit("护照.pdf", strong: true)]).contains { $0.contains("可能相关") })
    }

    @Test func judgedOnTheRowsShown() {
        // A sure one ranked sixth isn't on the card: the five shown are judged as none sure.
        let hits = (1...5).map { hit("长文\($0).md", strong: false) } + [hit("租赁合同.txt", strong: true)]
        let shown = texts(hits)
        #expect(shown.contains(Cards.noneSure))
        #expect(shown.filter { $0.contains("可能相关") && $0 != Cards.noneSure }.isEmpty)
    }

    @Test func aListingOfTheNewestSaysNeither() {
        let listing = texts([hit("截图1.png", strong: false, score: 0), hit("截图2.png", strong: false, score: 0)])
        #expect(!listing.contains { $0.contains("可能相关") })
    }

    /// The name segment also holds the folders above a file and its extension: only its own name counts.
    @Test func onlyItsOwnName() throws {
        let library = try Library()
        _ = try library.index()
        func strong(_ query: String) throws -> [String: Bool] {
            Dictionary(try library.search(query).hits.map { ($0.title, $0.strong) }) { first, _ in first }
        }
        #expect(try strong("合同")["租赁合同摘要.md"] == true)
        #expect(try strong("running")["running.txt"] == true)
        // In the folder named notes ("notes" in its text too): found, not sure.
        let notes = try strong("notes")
        #expect(notes["running.txt"] == false && notes["疫苗.txt"] == false)
        #expect(try strong("txt")["running.txt"] != true)
        // A listing of the newest isn't an answer.
        #expect(try library.search("").hits.allSatisfy { !$0.strong })
    }
}
