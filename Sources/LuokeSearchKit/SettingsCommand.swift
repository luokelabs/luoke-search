import Foundation

/// `luoke-search settings`: the user typing a change is the user's own say-so, carried out at once (through a plan, so
/// the checks are the same as the agent's).
///
/// The app as it ships takes it too (10-26: until the agent has a card for it, it's the only way to choose
/// folders by hand). That opens nothing new: any process of this user can write `settings.json` directly anyway, and
/// every walk judges the folders again (`Settings.searched`). The folders are judged as a plan's from the agent are
/// (`Settings.searchable`), what's skipped must be inside a folder searched, and the other development switches are
/// still refused or dropped (`CommandArguments.shippedRefusal`).
public enum SettingsCommand {
    public static let options: Set<String> = ["--index", "--add-folder", "--remove-folder", "--skip-folder", "--photos",
                                              "--on-battery", "--json"]

    /// Carries out the change typed, if any; returns what to print.
    public static func run(_ arguments: CommandArguments, directory: DataDirectory,
                           home: String = NSHomeDirectory()) throws -> String {
        try arguments.only(options)
        let service = try SearchService(directory: directory, hub: nil, home: home)
        service.restrictFolders = arguments.shipped
        func onOff(_ name: String) throws -> Bool? {
            guard let value = arguments.value(name) else { return nil }
            guard ["on", "off"].contains(value) else { throw CommandArguments.Failure("\(name) 后面写 on 或 off") }
            return value == "on"
        }
        var change = SearchService.Change()
        // Typed paths are relative to where the command runs; "~" is the home folder; the usual places by name
        // ("documents") stay names.
        func paths(_ name: String) -> [String] {
            arguments.values(name).map {
                !$0.hasPrefix("~") && ($0.contains("/") || $0.hasPrefix(".")) ? CommandArguments.absolute($0) : $0
            }
        }
        change.addFolders = paths("--add-folder")
        change.removeFolders = paths("--remove-folder")
        change.skipFolders = paths("--skip-folder")
        change.photos = try onOff("--photos")
        change.onBattery = try onOff("--on-battery")
        var out: [String] = []
        do {
            let (plan, lines) = try service.plan(change)
            if !plan.isEmpty {
                out.append(try service.apply(planID: plan.id, surfaceID: nil))
                for line in lines {
                    out.append("  \(line.text)")
                    if let path = line.path { out.append("    \(path)") }
                }
            }
        } catch let failure as ToolFailure {
            throw CommandArguments.Failure(failure.message)
        }
        let settings = Settings.load(directory)
        // The JSON alone, change or not: it's what's read by a program (luoke-search#46, defect 7).
        if arguments.json { return try JSONOutput.string(settings) }
        let folders = settings.searched(restricted: arguments.shipped, home: home)
        out.append("要搜的文件夹：" + (folders.isEmpty ? "还没选" : folders.joined(separator: "、")))
        if !settings.skipFolders.isEmpty { out.append("跳过：" + settings.skipFolders.joined(separator: "、")) }
        out.append("照片图库：\(settings.photos ? "搜" : "不搜")；用电池时建索引：\(settings.onBattery ? "是" : "否")（连着螺壳时，听螺壳的电池设置）")
        return out.joined(separator: "\n")
    }
}
