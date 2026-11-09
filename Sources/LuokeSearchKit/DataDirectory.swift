import Foundation

/// Where luoke-search keeps everything: `~/.luoke-search` unless a command says otherwise (`--index`, or
/// `LUOKE_SEARCH_HOME`). Only this account can open it (700), and it is kept out of Time Machine: the index holds the
/// text of the user's files, and backups would copy it somewhere it was never meant to be.
///
///     <data>/index.noindex/index.sqlite   the index (".noindex": Spotlight leaves it alone)
///     <data>/run/agent.sock               the MCP socket for luoke-agent (a later block)
public struct DataDirectory: Sendable {
    public let url: URL
    /// The real one (`~/.luoke-search`, chosen by default), not a development or test run's own (`--index`,
    /// `LUOKE_SEARCH_HOME`). Only the real one talks to the luoke-core the Mac uses every day (`Hub.socket(for:)`).
    public let isStandard: Bool

    public init(url: URL, isStandard: Bool = false) {
        self.url = url.standardizedFileURL
        self.isStandard = isStandard
    }

    /// `~/.luoke-search`, or `$LUOKE_SEARCH_HOME` when it is set.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> DataDirectory {
        if let home = environment["LUOKE_SEARCH_HOME"], !home.isEmpty {
            return DataDirectory(url: URL(fileURLWithPath: (home as NSString).expandingTildeInPath))
        }
        return DataDirectory(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".luoke-search"),
                             isStandard: true)
    }

    public var indexFolder: URL { url.appendingPathComponent("index.noindex") }
    public var indexFile: URL { indexFolder.appendingPathComponent("index.sqlite") }
    public var runFolder: URL { url.appendingPathComponent("run") }

    /// Creates the folders if needed, makes them private (700) and keeps the whole data directory out of Time Machine.
    /// Safe to call every time.
    public func prepare() throws {
        let manager = FileManager.default
        for folder in [url, indexFolder, runFolder] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
        try Self.excludeFromBackup(url)
    }

    /// Time Machine skips an item with the "exclude from backup" attribute (what `tmutil addexclusion` sets). It sticks
    /// to the folder, so it holds when the folder moves.
    static func excludeFromBackup(_ folder: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = folder
        try folder.setResourceValues(values)
    }

    public static func isExcludedFromBackup(_ folder: URL) -> Bool {
        let values = try? folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        return values?.isExcludedFromBackup ?? false
    }
}
