import Foundation
import Testing
@testable import LuokeSearchKit

// The settings changes besides adding a folder (coverage, 10-22): each kind of change as a plan's line and a card's,
// what carrying one out does to the index, and a plan whose settings changed since. Synthetic files only.
extension ReadsPictures {
    struct SettingsPlanTests {
        /// The library's folders searched, as if chosen before: its notes and its contracts.
        static func agent() throws -> (Agent, notes: String, contracts: String) {
            let agent = try Agent()
            let notes = agent.library.root + "/notes", contracts = agent.library.root + "/合同"
            var settings = Settings.load(agent.directory)
            settings.folders = [notes, contracts]
            try settings.save(agent.directory)
            return (agent, notes, contracts)
        }

        static func lines(_ result: [String: Any]) -> [String] {
            (result["structuredContent"] as? [String: Any])?["changes"] as? [String] ?? []
        }

        @Test("Each kind of change is a line of the plan and of its card; nothing changes until it's tapped")
        func everyKindOfChange() throws {
            let (agent, notes, _) = try Self.agent()
            let proposed = agent.call("search_settings", ["change": [
                "remove_folders": [notes], "skip_folders": [agent.library.root + "/app"], "photos": true,
                "on_battery": true,
            ]])
            #expect(Self.lines(proposed) == ["不再搜「notes」：它的内容会移出索引", "跳过「app」",
                                             "也搜「照片」里的照片和视频（要你允许读照片）", "用电池时也建索引（连着螺壳时，听螺壳的电池设置）"])
            let card = String(decoding: try JSONSerialization.data(withJSONObject: proposed["structuredContent"] ?? [:]),
                              as: UTF8.self)
            #expect(card.contains("不再搜「notes」") && card.contains("跳过「app」"))
            #expect(card.contains(notes.replacingOccurrences(of: "/", with: "\\/")))   // the path in the small print
            #expect(Settings.load(agent.directory).photos == false)   // only proposed
            // The other way round, and what's already so says nothing.
            let back = agent.call("search_settings", ["change": ["photos": false, "on_battery": false,
                                                                  "remove_folders": [agent.library.root + "/work"]]])
            #expect(Self.lines(back).isEmpty)
            var settings = Settings.load(agent.directory)
            settings.photos = true
            settings.onBattery = true
            try settings.save(agent.directory)
            #expect(Self.lines(agent.call("search_settings", ["change": ["photos": false, "on_battery": false]]))
                    == ["不再搜「照片」", "用电池时不建索引（新文件照样马上读；连着螺壳时，听螺壳的电池设置）"])
        }

        @Test("A folder taken out of the settings is taken out of the index when the plan is carried out")
        func removingAFolderPrunes() throws {
            let (agent, notes, contracts) = try Self.agent()
            let store = agent.library.store
            #expect(try store.item(path: notes + "/running.txt") != nil)
            let proposed = agent.call("search_settings", ["change": ["remove_folders": [notes]]])
            let plan = try #require((proposed["structuredContent"] as? [String: Any])?["plan_id"] as? String)
            let applied = agent.call("search_settings_apply", ["plan_id": plan], tapped: "s-\(plan)")
            #expect((applied["structuredContent"] as? [String: Any])?["done"] as? Bool == true)
            #expect(Settings.load(agent.directory).folders == [contracts])
            #expect(try store.item(path: notes + "/running.txt") == nil)
            #expect(try store.item(path: notes + "/疫苗.txt") == nil)
            #expect(try store.item(path: contracts + "/租赁合同摘要.md") != nil)
            #expect(try agent.library.search("宽窄巷子").hits.isEmpty)       // notes' words aren't found either
            #expect(try agent.library.search("押金").hits.first?.title == "租赁合同摘要.md")
        }

        @Test("A plan made before the settings changed again is stale; a folder that isn't there is refused")
        func stalePlans() throws {
            let (agent, notes, _) = try Self.agent()
            let proposed = agent.call("search_settings", ["change": ["skip_folders": [notes + "/old"]]])
            let plan = try #require((proposed["structuredContent"] as? [String: Any])?["plan_id"] as? String)
            var settings = Settings.load(agent.directory)
            settings.onBattery = true                                 // changed meanwhile (the command line, say)
            try settings.save(agent.directory)
            let applied = agent.call("search_settings_apply", ["plan_id": plan], tapped: "s-\(plan)")
            let structured = applied["structuredContent"] as? [String: Any]
            #expect(structured?["code"] as? String == "stale")
            #expect(((applied["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("又改过了") == true)
            #expect(Settings.load(agent.directory).skipFolders.isEmpty)
            let missing = agent.call("search_settings", ["change": ["add_folders": [agent.library.root + "/没有这个"]]])
            #expect((missing["structuredContent"] as? [String: Any])?["code"] as? String == "invalid")
        }
    }
}
