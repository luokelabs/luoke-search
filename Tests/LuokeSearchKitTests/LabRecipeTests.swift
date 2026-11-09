import Foundation
import Testing

// The lab hub's recipe (`scripts/lab_recipe.py`, which `scripts/lab_hub.sh` runs): the same copy whether luoke-core's
// dev.json names the embedding task luoke-search.embed, as since its rename (11-02), or digup.embed, as a copy from
// before it does. Made-up recipes in luoke-core's shape; nothing is started.

struct LabRecipeTests {
    static let script = packageRoot.appendingPathComponent("scripts/lab_recipe.py").path

    /// A dev.json as luoke-core's: the task named as before the rename (`renamed: false`) or as now.
    static func recipe(renamed: Bool) -> [String: Any] {
        let embed = renamed ? "luoke-search.embed" : "digup.embed"
        return [
            "recipe_version": "dev-7",
            "engine": ["app": "/Applications/oMLX.app", "version": "0.7.0"],
            "tiers": ["16": ["max_gb": 24], "32": ["max_gb": 64], "128": ["max_gb": 999]],
            "assignment": ["16": ["base": "base-9b", "special": ["luoke-ime.rerank": "small", embed: "embedder"]]],
            "tasks": [
                embed: ["accessory": renamed ? "luoke-search" : "digup", "kind": "embed",
                        "params": ["*": ["batch": 32, "max_tokens": 2048]]],
                "luoke-ime.rerank": ["accessory": "luoke-ime", "kind": "score", "params": ["*": ["batch": 8]]],
            ],
            "verified": [renamed ? "luoke-search" : "digup": ["versions": ["0.1.0"]], "luoke-ime": ["versions": ["*"]]],
        ]
    }

    /// Runs the script on `recipe`: its exit status and the copy it wrote, if any.
    static func lab(_ recipe: [String: Any], in scratch: Scratch) throws -> (status: Int32, copy: [String: Any]?) {
        let source = try scratch.write("dev.json", data: try JSONSerialization.data(withJSONObject: recipe))
        let copy = scratch.url.appendingPathComponent("lab.json")
        try? FileManager.default.removeItem(at: copy)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", script, source.path, copy.path, "/lab/oMLX.app", "omlx-lab"]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let written = (try? Data(contentsOf: copy)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        return (process.terminationStatus, written as? [String: Any])
    }

    @Test("either name luoke-core gives the embedding task, the same lab copy: luoke-search's task alone, with pictures and sound")
    func eitherName() throws {
        let scratch = try Scratch()
        let before = try Self.lab(Self.recipe(renamed: false), in: scratch)
        let after = try Self.lab(Self.recipe(renamed: true), in: scratch)
        #expect(before.status == 0 && after.status == 0)
        let copy = try #require(after.copy)
        #expect(NSDictionary(dictionary: try #require(before.copy)).isEqual(to: copy))

        let tasks = try #require(copy["tasks"] as? [String: [String: Any]])
        #expect(Set(tasks.keys) == ["luoke-search.embed", "luoke-ime.rerank"])
        let embed = try #require(tasks["luoke-search.embed"])
        #expect(embed["accessory"] as? String == "luoke-search")
        let params = try #require((embed["params"] as? [String: [String: Any]])?["*"])
        #expect(NSDictionary(dictionary: params).isEqual(to: [
            "batch": 32, "max_tokens": 2048, "image_batch": 8, "image_budgets": [70, 140, 280, 560, 1120],
            "audio_batch": 2, "max_image_bytes": 4_000_000, "max_audio_bytes": 1_100_000, "max_audio_secs": 30,
        ]))
        let assignment = try #require(copy["assignment"] as? [String: [String: Any]])
        #expect(Set(assignment.keys) == ["16", "32", "128"])
        for tier in assignment.values {
            #expect(tier["base"] is NSNull)
            #expect(tier["special"] as? [String: String] == ["luoke-search.embed": "embeddinggemma-2"])
        }
        let verified = try #require(copy["verified"] as? [String: Any])
        #expect(Set(verified.keys) == ["luoke-search", "luoke-ime"])
        #expect((verified["luoke-search"] as? [String: [String]])?["versions"] == ["*"])
        #expect(copy["recipe_version"] as? String == "dev-7-luoke-search-lab")
        #expect(copy["engine"] as? [String: String] == ["app": "/lab/oMLX.app", "version": "omlx-lab"])
    }

    @Test("both names, or neither: no copy, and the lab hub doesn't start on a recipe it can't tell")
    func notOneName() throws {
        let scratch = try Scratch()
        var both = Self.recipe(renamed: false)
        var tasks = try #require(both["tasks"] as? [String: Any])
        tasks["luoke-search.embed"] = tasks["digup.embed"]
        both["tasks"] = tasks
        var neither = Self.recipe(renamed: false)
        tasks.removeValue(forKey: "digup.embed")
        tasks.removeValue(forKey: "luoke-search.embed")
        neither["tasks"] = tasks
        for recipe in [both, neither] {
            let lab = try Self.lab(recipe, in: scratch)
            #expect(lab.status != 0)
            #expect(lab.copy == nil)
        }
    }

    // lab_hub.sh itself isn't run here: it links /tmp/lksr and starts a hub. Its call is read instead.
    @Test("lab_hub.sh makes the recipe with this script, arguments in order, before linking anything, and starts on it")
    func labHubCallsIt() throws {
        let hub = try String(contentsOf: packageRoot.appendingPathComponent("scripts/lab_hub.sh"), encoding: .utf8)
        let lines = hub.components(separatedBy: "\n")
        let call = #"/usr/bin/python3 -I "$repo/scripts/lab_recipe.py" "$src/recipes/dev.json" "$recipe" "$engine_app" "$engine""#
        let made = try #require(lines.firstIndex(of: call))
        let linked = try #require(lines.firstIndex { $0.hasPrefix("ln ") })
        #expect(made < linked)
        #expect(hub.contains(#"--recipe "$recipe""#))
        #expect(!hub.contains("<<"))
    }
}
