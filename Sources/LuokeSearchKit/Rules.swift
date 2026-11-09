import Foundation

/// What an item is; decides how it is read and shown (CONTEXT.md「类型」). `photo` is the Photos library's (PhotoKit);
/// a picture file in a folder is an `image`.
public enum ItemKind: String, CaseIterable, Codable, Sendable {
    case doc, pdf, screenshot, image, video, audio, photo
}

/// What a file found while walking is to the index.
public enum Classification: Equatable, Sendable {
    case index(ItemKind)
    /// Not read, with a reason worth reporting ("credential file").
    case skip(String)
    /// Not a type luoke-search reads at all; not reported.
    case ignore
    /// Not read now nor counted anywhere, but what was read of it before stays: a file that can't be told without
    /// downloading it (`Rules.isUnopenedStream`).
    case keep
}

/// What to read, what to skip, and which kind a file is. Pure functions of names and a few file attributes.
public enum Rules {
    // MARK: Kinds

    static let docExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "rtf", "doc", "docx", "odt", "html", "htm", "xlsx", "pptx", "csv", "tsv",
    ]
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "avif", "tif", "tiff", "gif", "bmp", "svg",
        "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf",
    ]
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "3gp", "mkv", "webm", "avi", "flv", "wmv", "ogv", "mts", "m2ts", "ts",
    ]
    static let audioExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aif", "aiff", "caf", "flac", "aac", "ogg", "opus", "amr",
    ]

    /// Names macOS and screenshot tools give screenshots, in the languages people run macOS in.
    static let screenshotPrefixes = [
        "Screenshot", "Screen Shot", "CleanShot", "SCR-", "截屏", "屏幕快照", "屏幕截图", "螢幕截圖", "螢幕快照", "スクリーンショット",
    ]

    /// The kind a file's name says it is, or nil for types luoke-search doesn't read. Doesn't touch the file except
    /// for `.ts` (a video, or TypeScript?) and screenshots' Spotlight marker.
    public static func kind(of url: URL, isDataless: (stat) -> Bool = { $0.st_flags & Crawler.datalessFlag != 0 }) -> ItemKind? {
        let ext = url.pathExtension.lowercased()
        if docExtensions.contains(ext) { return .doc }
        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return isScreenshot(url) ? .screenshot : .image }
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) {
            if ext == "ts" || ext == "mts" { return isTransportStream(url, isDataless: isDataless) ? .video : nil }
            return .video
        }
        return nil
    }

    /// A screenshot: macOS marks the ones it takes (the mark survives moving and copying); other tools are known by
    /// the names they give.
    public static func isScreenshot(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if screenshotPrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        return hasScreenCaptureMark(url)
    }

    static func hasScreenCaptureMark(_ url: URL) -> Bool {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW) > 0
        }
    }

    /// Whether a file starts like a zip (PK\u{3}\u{4}): only its first 4 bytes are read, and none of a file whose
    /// contents are only in iCloud (reading it would download it).
    static func isZip(_ url: URL, isDataless: (stat) -> Bool = { $0.st_flags & Crawler.datalessFlag != 0 }) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, !isDataless(info),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04])
    }

    /// MPEG transport streams have a 0x47 sync byte every 188 (or 192) bytes; TypeScript doesn't. A file whose contents
    /// are only in iCloud isn't opened (reading it would download it; luoke-search#46, defect 4), so it isn't known to
    /// be one (`isUnopenedStream`).
    static func isTransportStream(_ url: URL, isDataless: (stat) -> Bool = { $0.st_flags & Crawler.datalessFlag != 0 }) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, !isDataless(info),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 600), data.count >= 400 else { return false }
        let bytes = [UInt8](data)
        return (bytes[0] == 0x47 && bytes[188] == 0x47 && bytes[376] == 0x47)
            || (bytes[4] == 0x47 && bytes[196] == 0x47 && bytes[388] == 0x47)
    }

    /// A `.ts` or `.mts` whose contents are only in iCloud: a film or TypeScript, which can't be told without
    /// downloading it (luoke-search#46, defect 4). The walk keeps what was read of it while it was here, not dropping
    /// a film, and counts it nowhere, not making TypeScript a film not on this Mac (review 11-02).
    static func isUnopenedStream(_ url: URL, isDataless: (stat) -> Bool = { $0.st_flags & Crawler.datalessFlag != 0 }) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ext == "ts" || ext == "mts" else { return false }
        var info = stat()
        return lstat(url.path, &info) == 0 && isDataless(info)
    }

    // MARK: Credentials

    /// Extensions of key, certificate and password-vault files.
    static let credentialExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "p8", "p7b", "keystore", "jks", "ppk", "kdbx", "kdb", "gpg", "pgp", "asc",
        "crt", "cer", "der", "csr", "mobileprovision", "ovpn", "keychain", "keychain-db", "1pif", "opvault",
    ]
    /// Whole names (or their starts) of key and secret files.
    static let credentialNamePrefixes = [
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".env", ".netrc", ".npmrc", ".pypirc", ".htpasswd", "htpasswd",
    ]
    /// Words in a name (split at anything that isn't a letter or digit) that mark a credential file. Not "token" or
    /// "key" alone: too many ordinary documents are named with them ("Token economics.pdf", "Key dates.md").
    static let credentialWords: Set<String> = [
        "password", "passwords", "passwd", "passcode", "passcodes", "pwd", "credential", "credentials",
        "secret", "secrets", "apikey", "apikeys", "privatekey", "2fa", "otp",
    ]
    /// Word pairs that mark one ("API key", "recovery codes").
    static let credentialPairs: [(String, String)] = [
        ("api", "key"), ("api", "keys"), ("private", "key"), ("recovery", "code"), ("recovery", "codes"),
        ("backup", "codes"), ("seed", "phrase"), ("seed", "words"), ("access", "key"), ("access", "keys"),
    ]
    /// For scripts written without spaces: matched anywhere in the name.
    static let credentialFragments = [
        "密码", "密碼", "口令", "密钥", "密鑰", "私钥", "私鑰", "助记词", "助記詞", "恢复码", "恢復碼", "备用码", "備用碼",
        "パスワード", "暗証番号", "비밀번호",
        // Long enough never to be part of an ordinary word: matched inside one too ("MyPasswords", "1PasswordExport").
        "password", "passwd", "passcode", "credential", "apikey", "privatekey", "mnemonic",
    ]
    /// Names password managers and browsers export to.
    static let credentialExports = ["logins.csv", "bitwarden_export", "bitwarden-export", "lastpass_export", "keepass"]

    /// The words of a name, split at anything that isn't a letter or digit, where a lower-case letter meets an
    /// upper-case one ("WiFiPassword"), and where Chinese or Japanese meets Latin ("银行password").
    static func nameWords(_ name: String) -> [String] {
        var words: [String] = [], current = ""
        var previous: Character?
        for character in name {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current) }
                current = ""
                previous = nil
                continue
            }
            if let previous, !current.isEmpty,
               (previous.isLowercase && character.isUppercase)
                || Script.hasUnspaced(String(previous)) != Script.hasUnspaced(String(character)) {
                words.append(current)
                current = ""
            }
            current.append(character)
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }

    /// A file whose name says it holds passwords, keys or certificates. These are never read: what's in them must not
    /// end up in an index, a result or a card (top-level ADR 0013: credentials aren't content).
    public static func isCredentialFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if credentialExtensions.contains(ext) { return true }
        if credentialNamePrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        if credentialExports.contains(where: { lower.hasPrefix($0) }) { return true }
        return isCredentialName(name)
    }

    /// A name (of a file or a folder) made of credential words (review A-06: folders count too).
    static func isCredentialName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if credentialFragments.contains(where: { lower.contains($0) }) { return true }
        let words = nameWords(name)
        if words.contains(where: credentialWords.contains) { return true }
        for (first, second) in credentialPairs {
            if zip(words, words.dropFirst()).contains(where: { $0 == first && $1 == second }) { return true }
            if words.contains(first + second) { return true }
        }
        return false
    }

    // MARK: Folders

    /// Folders that hold tools' and libraries' files, not the user's.
    static let skippedFolderNames: Set<String> = [
        "node_modules", "bower_components", "venv", "site-packages", "__pycache__", "DerivedData", "Pods", "Carthage",
    ]
    /// A folder with one of these in it is a code project: code search isn't in the first version, so of a project
    /// only screenshots are read (people drop them into project folders).
    static let projectMarkers: Set<String> = [
        ".git", "package.json", "Package.swift", "pyproject.toml", "setup.py", "requirements.txt", "Cargo.toml",
        "go.mod", "pom.xml", "build.gradle", "build.gradle.kts", "Gemfile", "composer.json", "CMakeLists.txt",
    ]
    static let projectBundleExtensions: Set<String> = ["xcodeproj", "xcworkspace"]

    /// Why a folder isn't walked into, or nil to walk it. `home` is the user's home; `excluded` the folders the user
    /// skipped.
    public static func skipReason(folder: URL, home: String, excluded: [String]) -> String? {
        let name = folder.lastPathComponent
        let path = folder.path
        if name.hasPrefix(".") { return "hidden folder" }
        if skippedFolderNames.contains(name) { return "developer folder" }
        if isCredentialName(name) { return "credential folder" }
        if name.hasSuffix(".noindex") { return ".noindex folder" }
        if path == home + "/Library" { return "~/Library" }
        if excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return "excluded folder" }
        return nil
    }

    // MARK: Datasets

    /// Names cameras and phones give, which look machine-made but are the user's photos and videos.
    static let cameraPrefixes = ["img", "dsc", "dscn", "dscf", "pxl", "mvimg", "vid", "mov", "gopr", "gp0", "dji",
                                 "sam_", "wp_", "photo", "screenshot", "screen shot", "截屏", "屏幕快照", "微信图片", "mmexport"]

    /// Words datasets and exports of frames put before a number ("frame_0042", "clip-000123", "sample.0001"). Any
    /// other word and a number is how cameras and apps name files (P1010001, C0001, MVI_1234, GH010001, Voice 001,
    /// Wedding_0001…), too many to list (review D-3).
    static let datasetWords: Set<String> = [
        "frame", "frames", "clip", "sample", "image", "slice", "tile", "patch", "crop", "chunk", "segment", "seg",
        "render", "output", "out", "train", "test", "val", "mask", "depth", "rgb", "sprite", "item", "data", "example",
    ]

    /// A machine-made name ("000123", "clip_000123", "3f9a1c0e-…"), not a camera's or an app's ("IMG_1234",
    /// "20231015_143022").
    public static func looksMachineNamed(_ stem: String) -> Bool {
        let name = stem.lowercased()
        if cameraPrefixes.contains(where: { name.hasPrefix($0) }) { return false }
        // A date: phones, messengers and exports name files by when ("20231015_143022", "signal-2023-10-15-…").
        if name.range(of: #"(19|20)\d\d[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\d|3[01])"#, options: .regularExpression) != nil {
            return false
        }
        if name.range(of: #"^\d{3}_\d{4}$"#, options: .regularExpression) != nil { return false }   // Kodak: 100_0001
        if name.range(of: #"^[0-9a-f]{8,}([-_][0-9a-f]{4,})*$"#, options: .regularExpression) != nil { return true }
        let word = name.prefix(while: { $0.isASCII && $0.isLetter })
        guard word.isEmpty || datasetWords.contains(String(word)) else { return false }
        return name.dropFirst(word.count).range(of: #"^[-_. ]?\d{3,}([-_.]\d+)*$"#, options: .regularExpression) != nil
    }

    /// A picture, film or recording by its name alone (a `.ts` looked into): what `datasetKinds` counts, without
    /// `kind(of:)`'s look for the screenshot mark on every picture.
    static func mediaKind(of url: URL, isDataless: (stat) -> Bool = { $0.st_flags & Crawler.datalessFlag != 0 }) -> ItemKind? {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) {
            return ext == "ts" || ext == "mts" ? (isTransportStream(url, isDataless: isDataless) ? .video : nil) : .video
        }
        return nil
    }

    /// The media kinds a folder holds like a dataset (training data, an export of frames, not the user's own): at
    /// least `minimum` files of one kind, 70% of them with machine-made names. The idea is upstream DigUp's (F-13).
    static func datasetKinds(_ files: [URL], minimum: Int = 300, isDataless: (stat) -> Bool = { $0.st_flags & Crawler.datalessFlag != 0 }) -> [ItemKind: Int] {
        var stems: [ItemKind: [String]] = [:]
        for file in files {
            // Hidden files aren't read; "._IMG_1234.jpg" (what macOS leaves on exFAT drives) would count twice.
            guard !file.lastPathComponent.hasPrefix("."), let kind = mediaKind(of: file, isDataless: isDataless) else { continue }
            stems[kind, default: []].append(file.deletingPathExtension().lastPathComponent)
        }
        var out: [ItemKind: Int] = [:]
        for (kind, names) in stems where names.count >= minimum {
            if Double(names.filter(looksMachineNamed).count) / Double(names.count) >= 0.7 { out[kind] = names.count }
        }
        return out
    }

    /// Whether the folder's entries make it a code project.
    static func isProject(_ names: [String]) -> Bool {
        names.contains { projectMarkers.contains($0) || projectBundleExtensions.contains(($0 as NSString).pathExtension) }
    }

    /// How a file found while walking is to be treated. `inProject`: it is inside a code project.
    public static func classify(_ url: URL, inProject: Bool = false, excludedExtensions: Set<String> = [],
                                isDataless: (stat) -> Bool = { $0.st_flags & Crawler.datalessFlag != 0 }) -> Classification {
        let name = url.lastPathComponent
        if name.hasPrefix(".") { return name.hasPrefix(".env") ? .skip("credential file") : .ignore }
        if isCredentialFile(name) {
            // ".key" is also a Keynote deck saved as one file (a zip): not read, like any type luoke-search doesn't
            // read, and not reported as a credential (luoke-search#18). A key, a file that can't be looked into, and
            // one whose name says credential with or without its extension ("private.key") stay credentials.
            if url.pathExtension.lowercased() == "key", isZip(url),
               !isCredentialFile((name as NSString).deletingPathExtension), !isCredentialName(name) {
                return .ignore
            }
            return .skip("credential file")
        }
        let excluded = excludedExtensions.contains(url.pathExtension.lowercased())
        // Kept in a code project too: one read while it was here was a film read outside one.
        if isUnopenedStream(url, isDataless: isDataless) { return excluded ? .skip("excluded type") : .keep }
        guard let kind = kind(of: url, isDataless: isDataless) else { return .ignore }
        if excluded { return .skip("excluded type") }
        if inProject && kind != .screenshot { return .skip("in a code project") }
        return .index(kind)
    }
}
