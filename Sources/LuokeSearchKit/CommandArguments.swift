import Foundation

/// A command line's arguments: positional ones, options with a value (`--index DIR` or `--index=DIR`), flags. Each
/// command says which options it takes (`only`): anything else is an error, never silently ignored (review B-09: a
/// mistyped `--indx` once meant the real data directory).
public struct CommandArguments {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    public var positional: [String] = []
    public var options: [String: [String]] = [:]
    public var flags: Set<String> = []
    /// This run is the app as it ships (`shipped`): set once its switches are dealt with.
    public var shipped = false

    public static let valued: Set<String> = ["--index", "--exclude", "--kind", "-n", "--since", "--until", "--testbed",
                                             "--add-folder", "--remove-folder", "--skip-folder", "--photos",
                                             "--on-battery", "--socket", "--sample", "--originals", "--scoring", "--transcripts",
                                             "--parent-pid"]

    public init(_ arguments: ArraySlice<String>) throws {
        var rest = arguments
        while let argument = rest.popFirst() {
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                let name = String(argument[..<equals])
                guard Self.valued.contains(name) else { throw Failure("\(name) 不带值") }
                options[name, default: []].append(String(argument[argument.index(after: equals)...]))
            } else if Self.valued.contains(argument) {
                guard let value = rest.popFirst() else { throw Failure("\(argument) 后面要跟一个值") }
                options[argument, default: []].append(value)
            } else if argument.hasPrefix("--") {
                flags.insert(argument)
            } else {
                positional.append(argument)
            }
        }
    }

    /// Fails on any option or flag outside `allowed`.
    public func only(_ allowed: Set<String>) throws {
        if let stray = (Set(options.keys).union(flags)).subtracting(allowed).sorted().first {
            throw Failure("这条命令没有 \(stray) 这个选项")
        }
    }

    /// A count option (`-n`): a whole number, kept within 1…50 as the agent's limit is (review B-21).
    public func count(_ name: String, default fallback: Int) throws -> Int {
        guard let text = value(name) else { return fallback }
        guard let number = Int(text) else { throw Failure("\(name) 后面要跟一个整数") }
        return min(max(number, 1), 50)
    }

    /// What only development runs and tests may set. The app as it ships takes none of them (pre-release review,
    /// should-fix 8, and its review): any process of this user could otherwise run it — with the folders and the
    /// Photos library macOS lets it read — on a data directory, socket, hub or opener of its own, and have it read
    /// what that process can't. Another data directory or home (`CFFIXED_USER_HOME` moves the home folder) is refused
    /// outright: a developer who expected one isn't left on the real `~/.luoke-search`. The rest are dropped:
    /// luoke-core runs its jobs with `LUOKE_HUB_SOCKET` set to its own socket, the one used anyway.
    public static let dataOptions: Set<String> = ["--index", "--socket"]
    public static let dataVariables = ["LUOKE_SEARCH_HOME", "CFFIXED_USER_HOME"]
    public static let developmentVariables = ["LUOKE_HUB_SOCKET", "LUOKE_SEARCH_PHOTOS", "LUOKE_SEARCH_OPENER",
                                              "LUOKE_SEARCH_EMBED_TASK", "LUOKE_SEARCH_TESTBED"]
    /// What the app as it ships runs: the service, the first pass (luoke-core's job), looking things up, and the
    /// settings typed by hand (`SettingsCommand`: no looser than now, any process of this user can write
    /// `settings.json` anyway, and the folders are judged as the agent's are).
    public static let shippedCommands: Set<String> = ["serve", "index", "status", "search", "open", "settings", "mcp",
                                                      "help", "-h", "--help"]

    /// Whether a run is the app as it ships: anything run from 螺壳搜索.app's executable (`app`), and `serve
    /// --resident` as luoke-core runs it. `developmentApp`: a development build of the app (`LUOKE_SEARCH_DEV_APP=1
    /// sh scripts/build_app.sh`), which still takes the switches.
    public static func shipped(app: Bool, command: String?, flags: Set<String>, developmentApp: Bool) -> Bool {
        !developmentApp && (app || command == "serve" && flags.contains("--resident"))
    }

    /// Why the app as it ships won't run `command` with these arguments and this environment, if it won't.
    public func shippedRefusal(command: String?, environment: [String: String]) -> String? {
        let switches = Self.dataOptions.filter { options[$0] != nil }.sorted()
            + Self.dataVariables.filter { environment[$0] != nil }   // empty too: an empty CFFIXED_USER_HOME is the cwd
        if !switches.isEmpty {
            return "发布版不认开发用的 \(switches.joined(separator: "、"))（它只用正式的数据目录）；开发请用命令行，或打开发版 app（LUOKE_SEARCH_DEV_APP=1 sh scripts/build_app.sh）"
        }
        if let command, !Self.shippedCommands.contains(command) { return "发布版不做 \(command)：开发请用命令行" }
        if command == "index", !positional.isEmpty { return "发布版只读设置里的文件夹，不另给" }
        return nil
    }

    /// `--parent-pid`: the process this run ends with (`ParentWatch`), if given.
    public func parentPID() throws -> pid_t? {
        guard let text = value("--parent-pid") else { return nil }
        guard let pid = pid_t(text), pid > 1 else { throw Failure("--parent-pid 后面要跟一个进程号") }
        return pid
    }

    public func value(_ name: String) -> String? { options[name]?.last }
    public func values(_ name: String) -> [String] { options[name] ?? [] }
    public var json: Bool { flags.contains("--json") }

    /// `--index`, else `$LUOKE_SEARCH_HOME`, else the real `~/.luoke-search` — that one only for the app's own
    /// executable: a development build has to say where (review B-09).
    public func dataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                              bundle: String? = LuokeSearch.bundleIdentifier) throws -> DataDirectory {
        if let index = value("--index") { return DataDirectory(url: URL(fileURLWithPath: Self.absolute(index))) }
        let standard = DataDirectory.standard(environment: environment)
        if standard.isStandard, bundle != LuokeSearch.bundleID {
            throw Failure("开发版要给 --index <数据目录>（或设 LUOKE_SEARCH_HOME），不用正式的 ~/.luoke-search")
        }
        return standard
    }

    /// luoke-core, if this run may ask one (`Hub.socket`). `background`: for the resident service, which never asks
    /// to run on battery power: `allow_battery` is for batch work the user started by hand (luoke-core; luoke-search#46,
    /// defect 2), and the app takes any option.
    public func hub(for directory: DataDirectory, background: Bool = false,
                    environment: [String: String] = ProcessInfo.processInfo.environment) -> Hub? {
        guard let socket = Hub.socket(for: directory, environment: environment) else { return nil }
        let hub = Hub(socket: socket)
        hub.allowBattery = !background && flags.contains("--allow-battery")
        return hub
    }

    /// A path made absolute without requiring it to exist yet.
    public static func absolute(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
    }
}
