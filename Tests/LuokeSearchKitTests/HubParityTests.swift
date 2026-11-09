import Foundation
import Testing
@testable import LuokeSearchKit

/// luoke-core's vectors against the reference ones (Tests/Reference/vectors.json, and vectors-extra.json for the texts
/// added since): cosine ≥ 0.999 each, as top-level ADR 0018 sets for the embedding task and as luoke-core's
/// tools/embed_parity.py checks from its side. The texts are in Tests/Reference/texts.json, for both to read
/// (embed_parity.py still has the first five written out until luoke-core switches to it).
///
/// Runs against the hub at $LUOKE_HUB_SOCKET (a lab hub with HOME and LUOKE_HOME kept apart, never the one the Mac
/// uses every day); skipped without one. Pictures and sound are checked when the hub's task takes them.
@Suite struct HubParityTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Reference")
    static let hub = ProcessInfo.processInfo.environment["LUOKE_HUB_SOCKET"].map { Hub(socket: $0) }
    static let agreement: Float = 0.999
    /// The same input sent alone or in a batch: only the padding differs.
    static let sameInput: Float = 0.9999

    /// One input the reference was made from: the text, and the input as sent, prompted as indexing and search prompt
    /// it (the first five are digup's, word for word).
    struct Text: Decodable {
        let name: String
        let prompt: String
        let title: String?
        let text: String
        let input: String
    }

    static let texts: [(name: String, text: String)] = ((try? Self.inputs()) ?? []).map { ($0.name, $0.input) }

    static func inputs() throws -> [Text] {
        struct File: Decodable { let texts: [Text] }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: folder.appendingPathComponent("texts.json"))).texts
    }

    struct Reference: Decodable {
        let vectorVersion: Int
        let vectors: [String: [Float]]

        enum CodingKeys: String, CodingKey {
            case vectorVersion = "vector_version", vectors
        }
    }

    static func reference(_ file: String = "vectors.json") throws -> Reference {
        try JSONDecoder().decode(Reference.self, from: Data(contentsOf: folder.appendingPathComponent(file)))
    }

    /// The vectors of both files: vectors.json stays as digup made it, the texts added since are in vectors-extra.json.
    static func references() throws -> [String: [Float]] {
        try reference().vectors.merging(reference("vectors-extra.json").vectors) { old, _ in old }
    }

    @Test func theReferenceIsThere() throws {
        let original = try Self.reference(), extra = try Self.reference("vectors-extra.json")
        #expect(original.vectorVersion == 1 && extra.vectorVersion == 1)
        #expect(original.vectors.count == 9 && extra.vectors.count == 7)
        #expect(Set(original.vectors.keys).isDisjoint(with: extra.vectors.keys))
        #expect(Self.texts.count == 12)
        let vectors = try Self.references()
        for (name, _) in Self.texts { #expect(vectors[name]?.count == VectorMath.dimension, "\(name)") }
    }

    /// The inputs are what indexing and search would send for those texts: a change to `Prompts` shows here, not as
    /// vectors that stop agreeing.
    @Test func theInputsAreAsWePromptThem() throws {
        for text in try Self.inputs() {
            let input = text.prompt == "query" ? Prompts.query(text.text) : Prompts.document(title: text.title, text: text.text)
            #expect(text.prompt == "query" || text.prompt == "document")
            #expect(text.input == input, "\(text.name)")
        }
    }

    @Test(.enabled(if: hub != nil)) func theHubsVectorsAgreeWithTheReference() throws {
        let reference = try Self.references()
        try #require(Self.texts.count == 12, "texts.json didn't load: nothing to compare")
        // Asked as someone waiting: a background request is refused while the hub counts the user as busy.
        let vectors = try Self.waitingWhileLoading { try Self.hub!.embed(Self.texts.map(\.text), priority: .userWaiting) }
        #expect(vectors.vectors.count == Self.texts.count)
        for ((name, _), vector) in zip(Self.texts, vectors.vectors) {
            let expected = try #require(reference[name])
            let cosine = VectorMath.cosine(vector, expected)
            #expect(cosine >= Self.agreement, "\(name): cosine \(cosine)")
            print("parity \(name): \(cosine)")
        }
        // A search sends its query alone, not padded to the longest of a batch: the same vector either way.
        for ((name, text), batched) in zip(Self.texts, vectors.vectors) where name.hasPrefix("query") {
            let alone = try #require(try Self.waitingWhileLoading {
                try Self.hub!.embed([text], priority: .userWaiting) }.vectors.first)
            let cosine = VectorMath.cosine(alone, batched)
            #expect(cosine >= Self.sameInput, "\(name) alone: cosine \(cosine) with the batch's")
            print("parity \(name) alone: \(cosine)")
        }
    }

    /// The pictures and the recording, sent as the reference was made from them: the files as they are, a picture
    /// at its budget (`frame-70` is the same photo at 70). Checked for whichever the hub's task takes.
    static let media: [(name: String, file: String, budget: Int?)] = [
        ("screen-280", "screen.png", 280), ("photo-140", "photo.jpg", 140), ("frame-70", "photo.jpg", 70),
        ("speech", "speech.wav", nil),
    ]

    @Test(.enabled(if: hub != nil)) func theHubsPicturesAndSoundAgreeWithTheReference() throws {
        let reference = try Self.reference()
        let task = try Self.hub!.embedTask(refresh: true)
        for item in Self.media where item.budget == nil ? task.takesAudio : task.takesImages {
            let data = try Data(contentsOf: Self.folder.appendingPathComponent(item.file))
            let input: Hub.Input = item.budget.map { .image(data, budget: $0) } ?? .audio(data)
            let result = try Self.waitingWhileLoading { try Self.hub!.embed(inputs: [input], priority: .userWaiting) }
            let vector = try #require(result.vectors.first ?? nil, "\(item.name): \(result.errors.first ?? nil ?? "-")")
            let cosine = VectorMath.cosine(vector, try #require(reference.vectors[item.name]))
            #expect(cosine >= Self.agreement, "\(item.name): cosine \(cosine)")
            print("parity \(item.name): \(cosine)")
        }
    }
}

extension HubParityTests {
    /// The hub answers `not_ready` while its worker loads the model (a few seconds after a start or an idle stop):
    /// asked again after the time it says, up to a minute.
    static func waitingWhileLoading<T>(_ work: () throws -> T) throws -> T {
        for _ in 0..<30 {
            do { return try work() } catch HubError.refused(let code, _, let retryAfter) where code == "not_ready" {
                Thread.sleep(forTimeInterval: retryAfter ?? 2)
            }
        }
        return try work()
    }
}
