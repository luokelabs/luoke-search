import Foundation
import Testing
@testable import LuokeSearchKit

// The page's folders (11-09): each on its own line with 「不搜了」, what a tap on it does, and the line under an empty
// result saying which folders were looked in. Synthetic files only.
extension ReadsPictures {
    struct PageFoldersTests {
        typealias Window = WindowTests

        /// The library's notes and contracts chosen, as the setup card or a plan would.
        static func agent() throws -> (Agent, notes: String, contracts: String) {
            let agent = try Agent()
            let notes = agent.library.root + "/notes", contracts = agent.library.root + "/合同"
            try Window.choose(agent, notes)
            try Window.choose(agent, contracts)
            return (agent, notes, contracts)
        }

        /// 「不搜了」 on `folder`'s line tapped, as the agent passes the button's context on.
        static func tap(_ agent: Agent, _ folder: String) -> [String: Any] {
            agent.call("search_settings_apply", ["folder": SearchService.folderID(folder)], tapped: SearchService.overviewPage)
        }

        static func buttons(_ page: Any, _ label: String) -> [[String: Any]] {
            let components = ((page as? [[String: Any]]) ?? []).flatMap {
                (($0["updateComponents"] as? [String: Any])?["components"] as? [[String: Any]]) ?? []
            }
            let labels = Set(components.filter { $0["text"] as? String == label }.compactMap { $0["id"] as? String })
            return components.filter { labels.contains($0["child"] as? String ?? "") }.compactMap {
                ((($0["action"] as? [String: Any])?["event"] as? [String: Any]))
            }
        }

        static func json(_ page: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: page), as: UTF8.self)
        }

        @Test("Each folder is a line of its own with 「不搜了」, which names it by an id: no path anywhere on the page")
        func eachFolderHasItsButton() throws {
            let (agent, notes, contracts) = try Self.agent()
            let page = try Window.read(agent, "page/overview")
            let texts = Window.pageTexts(page)
            #expect(texts.contains("2 个") && texts.contains("notes") && texts.contains("合同"))
            let taps = Self.buttons(page, "不搜了")
            #expect(taps.map { $0["name"] as? String } == ["search_settings_apply", "search_settings_apply"])
            #expect(taps.map { ($0["context"] as? [String: String])?["folder"] }
                    == [SearchService.folderID(notes), SearchService.folderID(contracts)])
            #expect(!(try Self.json(page)).contains(agent.library.root))
            if let drawn = try Window.asTheAgentReadsThePage(agent, page) {
                #expect((drawn["problems"] as? [Any])?.isEmpty == true)
                let sent = (drawn["buttons"] as? [String: Any])?["不搜了"] as? [String: Any]
                #expect(sent?["name"] as? String == "search_settings_apply")
                // The last of the two by label: what the agent sends the tool is the id on the button.
                #expect((sent?["arguments"] as? [String: String])?["folder"] == SearchService.folderID(contracts))
            }
        }

        @Test("A credential in a folder's name: masked on its line and in the answer, and in nothing the page sends")
        func aCredentialInAFoldersName() throws {
            let agent = try Agent()
            let folder = agent.library.root + "/身份证 110101199003070017 资料"
            try agent.library.scratch.write("files/身份证 110101199003070017 资料/a.txt", "一段话")
            try Window.choose(agent, folder)
            let page = try Window.read(agent, "page/overview")
            #expect(!(try Self.json(page)).contains("110101199003070017"))
            #expect(Window.pageTexts(page).contains { $0.contains("0017") })
            let tapped = Self.tap(agent, folder)
            #expect(Window.code(tapped) == nil && !Window.text(tapped).contains("110101199003070017"))
            #expect(Settings.load(agent.directory).folders.isEmpty)
        }

        @Test("Before anything's chosen the page lists no 「不搜了」, and a tap is refused (the setup card stays)")
        func notBeforeSetup() throws {
            let agent = try Agent()
            let notes = agent.library.root + "/notes"
            var settings = Settings.load(agent.directory)
            settings.folders = [notes]   // written by hand: nothing was chosen
            try settings.save(agent.directory)
            let page = try Window.read(agent, "page/overview")
            #expect(Window.pageTexts(page).contains("notes") && Self.buttons(page, "不搜了").isEmpty)
            #expect(Window.code(Self.tap(agent, notes)) == "needs_setup")
            #expect(Settings.load(agent.directory).folders == [notes])
        }

        @Test("A tap on 「不搜了」 takes the folder out of the settings and its files out of the index, at once")
        func aTapStopsSearching() throws {
            let (agent, notes, contracts) = try Self.agent()
            let store = agent.library.store
            #expect(try store.item(path: notes + "/running.txt") != nil)
            let tapped = Self.tap(agent, notes)
            #expect(Window.code(tapped) == nil)
            #expect((tapped["structuredContent"] as? [String: Any])?["done"] as? Bool == true)
            #expect(Window.text(tapped) == "不再搜「notes」了，里面的内容已移出索引。")
            #expect(Settings.load(agent.directory).folders == [contracts])
            #expect(try store.item(path: notes + "/running.txt") == nil)
            #expect(try store.item(path: contracts + "/租赁合同摘要.md") != nil)
            // No plan is left behind for a card to carry out later.
            #expect(ToolState.load(agent.directory).plans.isEmpty)
            let texts = Window.pageTexts(try Window.read(agent, "page/overview"))
            #expect(texts.contains("1 个") && !texts.contains("notes"))
            // Tapped again (a page drawn before): nothing to do.
            let again = Self.tap(agent, notes)
            #expect(Window.code(again) == nil && Window.text(again) == "已经不搜了。")
        }

        @Test("Only a tap on the page, naming one folder the settings have; with the switch in the same call, refused")
        func onlyThePagesTap() throws {
            let (agent, notes, contracts) = try Self.agent()
            let id = SearchService.folderID(notes)
            #expect(Window.code(agent.call("search_settings_apply", ["folder": id])) == "needs_user_action")
            #expect(Window.code(agent.call("search_settings_apply", ["folder": id], tapped: "q-1234")) == "needs_user_action")
            for wrong: Any in [[id], "", String(repeating: "a", count: 65)] {
                #expect(Window.code(agent.call("search_settings_apply", ["folder": wrong], tapped: SearchService.overviewPage)) == "invalid")
            }
            // A path or a name is no id: one folder at a time, only as the page names it.
            #expect(Window.code(agent.call("search_settings_apply", ["folder": notes], tapped: SearchService.overviewPage)) == "invalid")
            #expect(Window.text(agent.call("search_settings_apply", ["folder": "notes"], tapped: SearchService.overviewPage)) == "已经不搜了。")
            // Both at once: neither half done.
            let both = agent.call("search_settings_apply", ["photos": true, "folder": id], tapped: SearchService.overviewPage)
            #expect(Window.code(both) == "invalid")
            #expect(Settings.load(agent.directory).photos == false)
            // A folder the settings don't have is let be: the settings, and the index, stay as they were.
            #expect(Window.text(Self.tap(agent, agent.library.root + "/work")) == "已经不搜了。")
            #expect(Settings.load(agent.directory).folders == [notes, contracts])
            #expect(try agent.library.store.item(path: agent.library.root + "/work/发布会.pptx") != nil)
        }

        @Test("A folder kept as a link, unlike the walk spells it, still goes")
        func aLinkedFolderGoes() throws {
            let (agent, notes, contracts) = try Self.agent()
            let link = agent.library.root + "/notes-link"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: notes)
            var settings = Settings.load(agent.directory)
            settings.folders.append(link)
            try settings.save(agent.directory)
            #expect(Window.pageTexts(try Window.read(agent, "page/overview")).contains("notes-link"))
            #expect(Window.text(Self.tap(agent, link)) == "不再搜「notes-link」了，里面的内容已移出索引。")
            #expect(Settings.load(agent.directory).folders == [notes, contracts])
        }

        @Test("A folder inside another one searched: its files stay, and the answer says so")
        func aFolderInsideAnother() throws {
            let agent = try Agent()
            let root = agent.library.root, notes = root + "/notes"
            try Window.choose(agent, root)
            try Window.choose(agent, notes)
            #expect(Window.text(Self.tap(agent, notes)) == "不再单独搜「notes」了：它在「files」里面，照样搜得到。")
            #expect(Settings.load(agent.directory).folders == [root])
            #expect(try agent.library.store.item(path: notes + "/running.txt") != nil)
        }

        @Test("The last folder may go too: then nothing's searched, the page says so, and the setup card doesn't return")
        func theLastFolder() throws {
            let agent = try Agent()
            let notes = agent.library.root + "/notes"
            try Window.choose(agent, notes)
            #expect(Window.code(Self.tap(agent, notes)) == nil)
            #expect(Settings.load(agent.directory).folders.isEmpty)
            #expect(try agent.library.store.item(path: notes + "/running.txt") == nil)
            let page = try Window.read(agent, "page/overview")
            #expect(Window.pageTexts(page).contains("还没选") && Self.buttons(page, "不搜了").isEmpty)
            #expect(agent.service.summary()["text"] as? String == "还没选要搜的地方")
            #expect(!(agent.service.outbox()["items"] as? [[String: Any]] ?? []).contains { $0["kind"] as? String == "needs-setup" })
            #expect(agent.service.searchedNote(sources: nil) == "现在一个文件夹都不搜；要搜的话，跟螺壳说要搜哪个。")
        }

        @Test("Two folders of the same name: each with the folder it's in")
        func sameNames() throws {
            let agent = try Agent()
            try agent.library.scratch.write("files/甲/资料/a.txt", "一段话")
            try agent.library.scratch.write("files/乙/资料/b.txt", "另一段话")
            try Window.choose(agent, agent.library.root + "/甲/资料")
            try Window.choose(agent, agent.library.root + "/乙/资料")
            try Window.choose(agent, agent.library.root + "/notes")
            let texts = Window.pageTexts(try Window.read(agent, "page/overview"))
            #expect(texts.contains("资料（甲）") && texts.contains("资料（乙）") && texts.contains("notes"))
        }

        @Test("The app as it ships: a folder it doesn't search isn't listed, nor counted")
        func restricted() throws {
            let (agent, notes, contracts) = try Self.agent()
            agent.service.restrictFolders = true
            var settings = Settings.load(agent.directory)
            settings.folders.append("/usr/share")
            try settings.save(agent.directory)
            let page = try Window.read(agent, "page/overview")
            #expect(Window.pageTexts(page).contains("2 个") && !Window.pageTexts(page).contains("share"))
            #expect(Self.buttons(page, "不搜了").count == 2)
            #expect(Window.text(Self.tap(agent, notes)).hasPrefix("不再搜「notes」"))
            #expect(Settings.load(agent.directory).folders == [contracts, "/usr/share"])
        }

        @Test("Many folders: the first ones listed, each with its button, then how many more; within a card's limit")
        func manyFolders() throws {
            let folders = (1...300).map { (name: "文件夹\($0)", id: "id\($0)") }
            let page = Cards.overview(exact: SearchState("可用"), semantic: SearchState("可用"), note: nil, folders: folders,
                                      photos: "off", lastRead: nil, changeable: true)
            let texts = Window.pageTexts(page)
            #expect(texts.contains("300 个") && texts.contains("文件夹\(Cards.maxFoldersShown)"))
            #expect(!texts.contains("文件夹\(Cards.maxFoldersShown + 1)"))
            #expect(texts.contains("还有 \(300 - Cards.maxFoldersShown) 个没列出；要不搜哪个，在对话里说"))
            #expect(Self.buttons(page, "不搜了").count == Cards.maxFoldersShown)
            let components = page.flatMap { (($0["updateComponents"] as? [String: Any])?["components"] as? [[String: Any]]) ?? [] }
            #expect(components.count <= 200)
        }

        static func card(_ result: [String: Any]) -> [String] {
            Window.pageTexts((result["structuredContent"] as? [String: Any])?["card"] ?? [])
        }

        @Test("Nothing found: the card and the answer say which folders were looked in")
        func anEmptyResultSaysWhere() throws {
            let (agent, _, _) = try Self.agent()
            let found = agent.call("search_query", ["query": "押金"])
            #expect(!Self.card(found).contains { $0.hasPrefix("找过的文件夹") })
            let none = agent.call("search_query", ["query": "潜水执照"])
            let line = "找过的文件夹：notes、合同。要搜别的文件夹，跟螺壳说一声。"
            #expect(Self.card(none).contains(line))
            #expect(Window.text(none).hasPrefix("没有找到对得上的。") && Window.text(none).contains("（\(line)）"))
            // Asked of the Photos library only: the folders weren't looked in, so nothing about them.
            let photos = agent.call("search_query", ["query": "潜水执照", "sources": ["photos"]])
            #expect(!Self.card(photos).contains { $0.hasPrefix("找过") } && !Window.text(photos).contains("找过"))
        }

        @Test("More than three folders by their first three")
        func theNoteNamesFewFolders() throws {
            let agent = try Agent()
            var settings = Settings.load(agent.directory)
            settings.folders = ["notes", "合同", "work", "app"].map { agent.library.root + "/" + $0 }
            try settings.save(agent.directory)
            #expect(agent.service.searchedNote(sources: nil) == "找过的文件夹：notes、合同、work 等 4 个。要搜别的文件夹，跟螺壳说一声。")
            #expect(agent.service.searchedNote(sources: [.files]) != nil && agent.service.searchedNote(sources: [.photos]) == nil)
        }
    }
}
