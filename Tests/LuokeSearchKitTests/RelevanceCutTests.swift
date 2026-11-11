import Foundation
import Testing
@testable import LuokeSearchKit

/// Weak results are left out (2026-11-09): a meaning match needs z ≥ 2 (≥ 1 only for a recording whose kind the
/// question names) and a cosine of at least the vector space's floor; whatever scores under half of the best goes,
/// unless it holds all of the question's words. Vectors here are set by hand, each at a chosen cosine to the question.
extension ReadsPictures {
    struct RelevanceCutTests {
        static let space = "embeddinggemma-2/1"

        /// Files indexed in a scratch folder, and their segments of one kind given vectors at chosen cosines.
        final class Folder {
            let scratch: Scratch
            let store: IndexStore
            var space = RelevanceCutTests.space

            init(_ files: [String: Data]) throws {
                scratch = try Scratch()
                for (name, data) in files { try scratch.write("files/" + name, data: data) }
                store = try scratch.store()
                let indexer = Indexer(store: store, crawler: Crawler(home: scratch.path))
                _ = try indexer.sync([scratch.path + "/files"])
                try indexer.readPending()
            }

            /// Every segment of `kind` in the file gets a vector at `cosines[file]` to `question` (axis 0); each its
            /// own other axis, so they're no closer to one another than through the question.
            func setVectors(kind: String, _ cosines: [String: Float]) throws {
                var rows: [(String, Int64)] = []
                try store.db.query("""
                    SELECT i.path, s.id FROM segments s JOIN items i ON i.id = s.item WHERE s.kind = '\(kind)'
                    """) { rows.append(($0.text(0) ?? "", $0.int(1))) }
                var vectors: [(Int64, [Float])] = []
                for (index, row) in rows.enumerated() {
                    let name = String(row.0.dropFirst(scratch.path.count + "/files/".count))
                    let cosine = try #require(cosines[name], "no cosine for \(name)")
                    vectors.append((row.1, Self.vector(cosine, axis: 1 + index + (kind == "text" ? 200 : 0))))
                }
                #expect(vectors.count >= cosines.count)
                try store.setVectors(vectors, space: space)
            }

            static func vector(_ cosine: Float, axis: Int) -> [Float] {
                var vector = [Float](repeating: 0, count: VectorMath.dimension)
                vector[0] = cosine
                vector[axis] = (1 - cosine * cosine).squareRoot()
                return vector
            }

            var question: QueryMeaning {
                var vector = [Float](repeating: 0, count: VectorMath.dimension)
                vector[0] = 1
                return QueryMeaning(vector: vector, space: space)
            }

            func search(_ text: String, cut: Bool = true, sources: Set<ItemSource>? = nil) throws -> SearchAnswer {
                let searcher = Searcher(store: store)
                searcher.cutsWeakHits = cut
                return try searcher.search(text, options: SearchOptions(sources: sources), meaning: question)
            }
        }

        static func blank() throws -> Data { try Drawn.png(Drawn.picture([], width: 400, height: 300)) }

        /// Blank pictures (nothing for OCR to read) by these names.
        static func photos(_ cosines: [String: Float]) throws -> [String: Data] {
            var files: [String: Data] = [:]
            for name in cosines.keys { files[name] = try blank() }
            return files
        }

        @Test("护照照片: the passport photos and the note, not the boarding pass a deviation up")
        func passportPhotos() throws {
            // z: about 4.5 and 4 for the passport's two, 1.5 for the boarding pass (as measured: 1.51, cosine 0.631).
            var cosines: [String: Float] = ["证件/IMG_1.png": 0.78, "证件/IMG_2.png": 0.77, "出差/IMG_3.png": 0.69]
            for index in 4...23 { cosines["相册/IMG_\(index).png"] = 0.60 + Float(index % 3) * 0.005 }
            var files = try Self.photos(cosines)
            files["证件/护照续签.md"] = Data("# 护照续签\n护照还有半年到期，续签要带旧护照和两张照片。".utf8)
            let folder = try Folder(files)
            try folder.setVectors(kind: "image", cosines)

            let before = try folder.search("护照照片", cut: false)
            #expect(before.hits.map(\.title).contains("IMG_3.png"))   // in before: the question names photos

            let answer = try folder.search("护照照片")
            #expect(Set(answer.hits.map(\.title)) == ["护照续签.md", "IMG_1.png", "IMG_2.png"])
            #expect(answer.totals?["files"] == 3)
        }

        @Test("Naming photos no longer lets a photo in at z 1: it needs 2, as any other meaning match")
        func photosNeedTwo() throws {
            // z about 3.2 for the penguin, 1.9 for the other (cosine 0.645, score within half of the best).
            var cosines: [String: Float] = ["动物园/IMG_1.png": 0.67, "动物园/IMG_2.png": 0.645]
            for index in 3...22 { cosines["相册/IMG_\(index).png"] = 0.60 + Float(index % 3) * 0.005 }
            let folder = try Folder(try Self.photos(cosines))
            try folder.setVectors(kind: "image", cosines)
            #expect(try folder.search("企鹅照片", cut: false).hits.map(\.title) == ["IMG_1.png", "IMG_2.png"])
            #expect(try folder.search("企鹅照片").hits.map(\.title) == ["IMG_1.png"])
        }

        @Test("A photo question nothing answers: the one standing out (z 4.5) is still too far, so nothing")
        func nothingAnswers() throws {
            var cosines: [String: Float] = ["动物园/IMG_1.png": 0.615]
            for index in 2...10 { cosines["相册/IMG_\(index).png"] = 0.52 + Float(index % 3) * 0.005 }
            let folder = try Folder(try Self.photos(cosines))
            try folder.setVectors(kind: "image", cosines)

            #expect(try folder.search("猫的照片", cut: false).hits.first?.title == "IMG_1.png")
            let answer = try folder.search("猫的照片")
            #expect(answer.hits.isEmpty)
            #expect(answer.confident == false)
            #expect(answer.totals?["files"] == 0)
            // Not the newest photos either: "猫" is a word, though too short to look for.
            #expect(try Searcher(store: folder.store).search("猫的照片").hits.isEmpty)
            #expect(try Searcher(store: folder.store).search("照片").hits.count == 10)
            #expect(Query("那段录音").onlyKindWords && !Query("猫的照片").onlyKindWords)
        }

        @Test("Named recordings still get z ≥ 1, if close enough")
        func namedRecordings() throws {
            var files: [String: Data] = [:]
            for name in ["a", "b", "c", "d"] { files["\(name).wav"] = Sound.wav(seconds: 5, tone: [0...5]) }
            let folder = try Folder(files)
            // a.wav stands about 1.65 deviations up.
            try folder.setVectors(kind: "audio", ["a.wav": 0.70, "b.wav": 0.66, "c.wav": 0.67, "d.wav": 0.65])
            #expect(try folder.search("开会时那段录音").hits.first?.title == "a.wav")
            #expect(try folder.search("开会时那段").hits.isEmpty)
        }

        @Test("Under half of the best goes, unless it holds every word of the question")
        func halfOfTheBest() throws {
            var cosines: [String: Float] = ["续签.md": 0.85, "半句.md": 0.55, "全词.md": 0.50]
            var files: [String: Data] = [
                "续签.md": Data("# 续签\n护照续签要带旧护照、两张照片和身份证。".utf8),
                "半句.md": Data("# 半句\n续签的事以后再说。".utf8),
                "全词.md": Data("# 全词\n护照续签。".utf8),
            ]
            for index in 1...8 {
                files["别的/\(index).md"] = Data("# 第\(index)篇\n今天天气不错，出去走走，第\(index)天。".utf8)
                cosines["别的/\(index).md"] = 0.50 + Float(index % 4) * 0.01
            }
            let folder = try Folder(files)
            try folder.setVectors(kind: "text", cosines)

            let before = try folder.search("护照 续签", cut: false)
            #expect(before.hits.map(\.title).contains("半句.md"))
            let answer = try folder.search("护照 续签")
            let titles = answer.hits.map(\.title)
            #expect(titles.first == "续签.md")
            #expect(titles.contains("全词.md"))      // every word: kept, however far below
            #expect(!titles.contains("半句.md"))     // half the words, a quarter of the best's score
            #expect(answer.totals?["files"] == titles.count)
        }

        @Test("Similar: what is further than the floor isn't listed")
        func similarFloor() throws {
            var cosines: [String: Float] = ["起点.md": 1, "近.md": 0.70]
            var files: [String: Data] = ["起点.md": Data("# 起点\n第一段。".utf8), "近.md": Data("# 近\n第二段。".utf8)]
            for index in 1...8 {
                files["远/\(index).md"] = Data("# 远\(index)\n第\(index)段。".utf8)
                cosines["远/\(index).md"] = 0.40 + Float(index) * 0.03   // up to 0.64
            }
            let folder = try Folder(files)
            try folder.setVectors(kind: "text", cosines)
            let start = String(try #require(try folder.store.item(path: folder.scratch.path + "/files/起点.md")).id)
            let searcher = Searcher(store: folder.store)
            searcher.cutsWeakHits = false
            let before = try #require(try searcher.similar(to: start))
            #expect(before.hits.contains { ($0.signals?.cosine ?? 1) < 0.62 })
            searcher.cutsWeakHits = true
            let answer = try #require(try searcher.similar(to: start))
            #expect(answer.hits.first?.title == "近.md")
            #expect(answer.hits.allSatisfy { ($0.signals?.cosine ?? 0) >= 0.62 })
            #expect(answer.totals?["files"] == answer.hits.count)
        }

        @Test("Another vector space has no floor until it's measured")
        func otherSpace() throws {
            var cosines: [String: Float] = ["动物园/IMG_1.png": 0.615]
            for index in 2...10 { cosines["相册/IMG_\(index).png"] = 0.52 + Float(index % 3) * 0.005 }
            let folder = try Folder(try Self.photos(cosines))
            folder.space = "other/1"
            try folder.setVectors(kind: "image", cosines)
            #expect(try folder.search("猫的照片").hits.map(\.title) == ["IMG_1.png"])
        }

        @Test("The half is the best of every source's: a source's count is what its own list shows")
        func halfAcrossSources() throws {
            var cosines: [String: Float] = ["续签.md": 0.85, "半句.md": 0.55]
            var files: [String: Data] = [
                "续签.md": Data("# 续签\n护照续签要带旧护照、两张照片和身份证。".utf8),
                "半句.md": Data("# 半句\n续签的事以后再说。".utf8),
            ]
            for index in 1...8 {
                files["别的/\(index).md"] = Data("# 第\(index)篇\n今天天气不错，出去走走，第\(index)天。".utf8)
                cosines["别的/\(index).md"] = 0.50 + Float(index % 4) * 0.01
            }
            let folder = try Folder(files)
            try folder.setVectors(kind: "text", cosines)
            // 半句.md, made a Photos item: under half of a file's score, so not in the Photos list, nor counted there.
            let half = try #require(try folder.store.item(path: folder.scratch.path + "/files/半句.md")).id
            try folder.store.db.execute("UPDATE items SET source = 'photos', path = 'photos:H1' WHERE id = \(half)")
            let photos = try folder.search("护照 续签", sources: [.photos])
            #expect(photos.hits.isEmpty)
            #expect(photos.totals?["photos"] == 0 && photos.totals?["files"] == 1)
            #expect(try folder.search("护照 续签", cut: false, sources: [.photos]).hits.count == 1)
        }

        @Test("Words alone (no vector for the question) aren't cut at half: that wasn't measured")
        func wordsAlone() throws {
            let folder = try Folder([
                "续签.md": Data("# 续签\n护照续签要带旧护照、两张照片和身份证。".utf8),
                "半句.md": Data("# 半句\n续签的事以后再说。".utf8),
            ])
            let titles = try Searcher(store: folder.store).search("护照 续签").hits.map(\.title)
            #expect(titles == ["续签.md", "半句.md"])
        }

        @Test("A file gone since sets no bar for the others")
        func goneTop() throws {
            var cosines: [String: Float] = ["续签.md": 0.85, "半句.md": 0.55]
            var files: [String: Data] = [
                "续签.md": Data("# 续签\n护照续签要带旧护照、两张照片和身份证。".utf8),
                "半句.md": Data("# 半句\n续签的事以后再说。".utf8),
            ]
            for index in 1...8 {
                files["别的/\(index).md"] = Data("# 第\(index)篇\n今天天气不错，出去走走，第\(index)天。".utf8)
                cosines["别的/\(index).md"] = 0.50 + Float(index % 4) * 0.01
            }
            let folder = try Folder(files)
            try folder.setVectors(kind: "text", cosines)
            #expect(!(try folder.search("护照 续签").hits.map(\.title).contains("半句.md")))
            try FileManager.default.removeItem(atPath: folder.scratch.path + "/files/续签.md")
            #expect(try folder.search("护照 续签").hits.map(\.title) == ["半句.md"])
        }
    }
}
