import Foundation
import ImageIO

/// Walks the folders to search and lists the files to index, without opening them (except to tell a `.ts` video
/// from TypeScript, a Keynote `.key` from a key by its first 4 bytes, and a camera's pictures by their EXIF). Doesn't follow symbolic links, doesn't go into packages (apps, the Photos library: that one is
/// read through PhotoKit), hidden folders, `~/Library`, developer folders or the user's skipped folders; doesn't
/// list files that aren't on this Mac yet (iCloud placeholders: reading one would download it).
public struct Crawler {
    public struct Result: Sendable {
        public var files: [FoundFile] = []
        /// Files and folders passed over, by reason ("credential file": 3).
        public var skipped: [String: Int] = [:]
        /// Roots that aren't there (an unplugged drive) or can't be listed (macOS privacy settings).
        public var unreachable: [String] = []
        /// Paths there but not readable now, whose items are kept as they are: files whose contents iCloud moved off
        /// this Mac ("Optimize Mac Storage"), folders that can't be listed any more (reviews A-04, A-12).
        public var kept: [String] = []
        public var keptFolders: [String] = []
        /// Folders whose media were passed over as a dataset's (`Rules.datasetKinds`), with how many files.
        public var datasets: [String: Int] = [:]
        /// The walk was asked to stop: it's incomplete, and nothing may be removed because of it.
        public var stopped = false
    }

    public var excludedFolders: [String] = []
    public var excludedExtensions: Set<String> = []
    public var home: String = NSHomeDirectory()
    /// Asked between folders: a long walk ends early when the process must stop (review A-21).
    public var shouldStop: () -> Bool = { false }
    /// Whether a file's contents are only in iCloud (swapped in tests).
    public var isDataless: (stat) -> Bool = { $0.st_flags & Crawler.datalessFlag != 0 }

    public init(excludedFolders: [String] = [], excludedExtensions: Set<String> = [], home: String = NSHomeDirectory()) {
        self.excludedFolders = excludedFolders.map(Crawler.canonical)
        self.excludedExtensions = excludedExtensions
        self.home = home
    }

    /// A folder as the walk spells its paths: absolute, with symbolic links resolved the way the system does
    /// (`realpath`: /tmp → /private/tmp, /var → /private/var). `URL.resolvingSymlinksInPath` isn't used: it strips
    /// "/private" again, and only when the path exists, so the same folder could be spelled two ways.
    public static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded
            : FileManager.default.currentDirectoryPath + "/" + expanded
        let standardized = URL(fileURLWithPath: absolute).standardizedFileURL.path
        guard let resolved = realpath(standardized, nil) else { return standardized }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func walk(_ roots: [String]) -> Result {
        var result = Result()
        for root in roots.map(Self.canonical) {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isFolder), isFolder.boolValue,
                  FileManager.default.isReadableFile(atPath: root),
                  (try? FileManager.default.contentsOfDirectory(atPath: root)) != nil else {
                result.unreachable.append(root)
                continue
            }
            walkFolder(URL(fileURLWithPath: root, isDirectory: true), inProject: false, isRoot: true,
                       chosen: Set(roots.map(Self.canonical)), into: &result)
            if result.stopped { break }
        }
        return result
    }

    /// Only `paths` (what FSEvents said changed), under `root`, with the same rules as a whole walk: a path inside a
    /// skipped, hidden or package folder gives nothing, a file inside a code project only if it's a screenshot. A folder
    /// is walked whole (it may have been moved in); a file is looked at alone; a path that's gone gives nothing.
    public func walk(_ paths: [String], under root: String) -> Result {
        var result = Result()
        let root = Self.canonical(root)
        var datasetsSeen: [String: [ItemKind: Int]] = [:]
        for path in paths {
            guard path == root || path.hasPrefix(root + "/") else { continue }
            // The folders between the root and the path: none may be skipped; any may make it a code project.
            var inProject = false
            var allowed = true
            var folder = root
            if let names = try? FileManager.default.contentsOfDirectory(atPath: root) { inProject = Rules.isProject(names) }
            let parts = path.dropFirst(root.count).split(separator: "/").map(String.init)
            for part in parts.dropLast() {
                folder += "/" + part
                let url = URL(fileURLWithPath: folder)
                if Rules.skipReason(folder: url, home: home, excluded: excludedFolders) != nil
                    || (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true {
                    allowed = false
                    break
                }
                if !inProject, let names = try? FileManager.default.contentsOfDirectory(atPath: folder) {
                    inProject = Rules.isProject(names)
                }
            }
            // A name changed only in case ("a.txt" → "A.txt") makes both spellings reach the same file on a disk that
            // ignores case: only the one the folder lists is the file (review A-19).
            guard allowed, path == root || Self.spelledAsListed(path) else { continue }
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: Set(Self.keys)), values.isSymbolicLink != true else {
                continue
            }
            if values.isDirectory == true {
                if path == root {
                    walkFolder(url, inProject: false, isRoot: true, into: &result)
                } else if values.isPackage != true,
                          Rules.skipReason(folder: url, home: home, excluded: excludedFolders) == nil {
                    walkFolder(url, inProject: inProject, into: &result)
                }
            } else if values.isRegularFile == true {
                let verdict = Rules.classify(url, inProject: inProject, excludedExtensions: excludedExtensions,
                                             isDataless: isDataless)
                if verdict == .keep { result.kept.append(path) }
                guard case .index(let kind) = verdict else { continue }
                // One picture, film or recording that changed in a dataset-like folder is passed over as a whole walk
                // would. (Its folder is listed once a batch, and only for those.)
                let parent = url.deletingLastPathComponent()
                if parent.path != root, [.image, .video, .audio].contains(kind) {
                    if datasetsSeen[parent.path] == nil {
                        let entries = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
                        datasetsSeen[parent.path] = datasetKinds(entries)
                    }
                    if datasetsSeen[parent.path]?[kind] != nil {
                        result.skipped["dataset-like folder", default: 0] += 1
                        continue
                    }
                }
                if let file = found(url, kind: kind) { result.files.append(file) } else { result.kept.append(path) }
            }
            if result.stopped { break }
        }
        return result
    }

    static let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]

    /// Whether the folder lists the path's last part spelled exactly so (Unicode normalization aside).
    static func spelledAsListed(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.precomposedStringWithCanonicalMapping
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent)
        else { return true }
        return names.contains { $0.precomposedStringWithCanonicalMapping == name }
    }

    /// `isRoot`: a folder the user chose; `chosen`: all the folders the user chose, in this walk. Those are never
    /// taken for a dataset, whatever they hold, also when walked as part of another (review D-10).
    private func walkFolder(_ folder: URL, inProject: Bool, isRoot: Bool = false, chosen: Set<String> = [],
                            into result: inout Result) {
        if result.stopped || shouldStop() {
            result.stopped = true
            return
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Self.keys,
                                                                         options: []) else {
            result.skipped["unreadable folder", default: 0] += 1
            result.keptFolders.append(folder.path)
            return
        }
        let inProject = inProject || Rules.isProject(entries.map(\.lastPathComponent))
        // Hundreds of machine-named media files of one kind: a dataset's, passed over and reported.
        let dataset = isRoot || chosen.contains(folder.path) ? [:] : datasetKinds(entries)
        if !dataset.isEmpty { result.datasets[folder.path] = dataset.values.reduce(0, +) }
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            autoreleasepool {
                let values = try? entry.resourceValues(forKeys: Set(Self.keys))
                if values?.isSymbolicLink == true { return }
                if values?.isDirectory == true {
                    if values?.isPackage == true {
                        if !entry.lastPathComponent.hasPrefix(".") { result.skipped["package", default: 0] += 1 }
                        return
                    }
                    if let reason = Rules.skipReason(folder: entry, home: home, excluded: excludedFolders) {
                        if reason != "hidden folder" { result.skipped[reason, default: 0] += 1 }
                        return
                    }
                    walkFolder(entry, inProject: inProject, chosen: chosen, into: &result)
                    return
                }
                guard values?.isRegularFile == true else { return }
                switch Rules.classify(entry, inProject: inProject, excludedExtensions: excludedExtensions,
                                      isDataless: isDataless) {
                case .ignore:
                    return
                case .keep:
                    result.kept.append(entry.path)
                case .skip(let reason):
                    result.skipped[reason, default: 0] += 1
                case .index(let kind):
                    if dataset[kind] != nil {
                        result.skipped["dataset-like folder", default: 0] += 1
                        return
                    }
                    guard let file = found(entry, kind: kind) else {
                        result.skipped["not on this Mac", default: 0] += 1
                        result.kept.append(entry.path)
                        return
                    }
                    result.files.append(file)
                }
            }
        }
    }

    /// `Rules.datasetKinds`, but pictures most of which say what camera took them (EXIF) are a camera's, whatever
    /// their names (review D-3).
    func datasetKinds(_ entries: [URL]) -> [ItemKind: Int] {
        var kinds = Rules.datasetKinds(entries, isDataless: isDataless)
        if kinds[.image] != nil,
           cameraMade(entries.filter { !$0.lastPathComponent.hasPrefix(".") && Rules.mediaKind(of: $0) == .image }) {
            kinds[.image] = nil
        }
        return kinds
    }

    /// Whether at least half of `sample` pictures, spread over them, name the camera that took them. Files only in
    /// iCloud aren't opened (that would download them).
    func cameraMade(_ pictures: [URL], sample: Int = 10) -> Bool {
        let sorted = pictures.sorted { $0.path < $1.path }
        let picked = sorted.count > sample ? (0..<sample).map { sorted[$0 * sorted.count / sample] } : sorted
        let made = picked.filter { url in
            var info = stat()
            guard lstat(url.path, &info) == 0, !isDataless(info),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] else { return false }
            return tiff[kCGImagePropertyTIFFMake] != nil || tiff[kCGImagePropertyTIFFModel] != nil
        }
        return !picked.isEmpty && made.count * 2 >= picked.count
    }

    /// SF_DATALESS: the file's contents are in iCloud, not on disk.
    public static let datalessFlag: UInt32 = 0x4000_0000

    func found(_ url: URL, kind: ItemKind) -> FoundFile? {
        var info = stat()
        guard lstat(url.path, &info) == 0, !isDataless(info) else { return nil }
        let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        return FoundFile(path: url.path, kind: kind, size: Int64(info.st_size), mtime: mtime,
                         inode: UInt64(info.st_ino), device: UInt64(UInt32(bitPattern: info.st_dev)))
    }
}
