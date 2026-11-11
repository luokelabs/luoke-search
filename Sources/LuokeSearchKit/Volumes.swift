import Foundation

/// A disk the user chose to search, kept by its volume UUID (not its name: another disk named the same is another
/// disk) and the path it was mounted at last.
public struct ChosenVolume: Codable, Sendable, Equatable {
    public var uuid: String
    public var path: String

    public init(uuid: String, path: String) {
        self.uuid = uuid
        self.path = path
    }
}

/// A disk mounted now that the page may offer (`Volumes.external`).
public struct MountedVolume: Sendable, Equatable {
    public var uuid: String
    public var path: String
    public var name: String

    public init(uuid: String, path: String, name: String) {
        self.uuid = uuid
        self.path = path
        self.name = name
    }
}

public enum Volumes {
    /// The disks plugged into this Mac now that the page offers (「也搜这块盘」): local, not internal, writable (a
    /// disk image to install from is read-only), under /Volumes, not Time Machine's. Network shares aren't local, so
    /// not listed. Only what the system knows of each mount is asked: nothing on a disk is listed or opened (that
    /// would have macOS ask the user about removable volumes, in the background).
    public static func external() -> [MountedVolume] {
        let keys: [URLResourceKey] = [.volumeUUIDStringKey, .volumeNameKey, .volumeIsLocalKey, .volumeIsInternalKey,
                                      .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), let uuid = values.volumeUUIDString,
                  values.volumeIsLocal == true, values.volumeIsInternal != true, values.volumeIsReadOnly != true,
                  values.volumeIsRootFileSystem != true, values.volumeIsBrowsable != false else { return nil }
            let path = url.standardizedFileURL.path
            guard isOffered(path) else { return nil }
            return MountedVolume(uuid: uuid, path: path, name: values.volumeName ?? url.lastPathComponent)
        }
    }

    /// Where a disk may be offered: right under /Volumes, and not a Time Machine backup's mount.
    static func isOffered(_ path: String) -> Bool {
        guard path.hasPrefix("/Volumes/"), !path.dropFirst("/Volumes/".count).contains("/") else { return false }
        return !path.hasPrefix("/Volumes/com.apple.TimeMachine.") && !path.hasSuffix(".timemachine")
    }

    /// Where each chosen disk is searched now: where it's mounted, by its UUID; not mounted, where it was (the walk
    /// finds it unreachable and keeps what was read of it); left out while anything else is at that path: another
    /// disk offered, or one never offered (a network share, a read-only image), or a folder (`occupied`).
    static func roots(_ chosen: [ChosenVolume], mounted: [MountedVolume],
                      occupied: (_ path: String, _ uuid: String) -> Bool = Volumes.holdsAnother) -> [String] {
        chosen.compactMap { volume in
            if let here = mounted.first(where: { $0.uuid == volume.uuid }) { return here.path }
            if mounted.contains(where: { $0.path == volume.path }) { return nil }
            return occupied(volume.path, volume.uuid) ? nil : volume.path
        }
    }

    /// Whether something other than the disk `uuid` is at `path`: anything there on another volume, or on one with
    /// no UUID. Nothing there (unplugged) isn't. Only the mount point is asked, as `external` asks it, never what's on
    /// the disk (review of PR #114). A network share mounted there is another without asking it anything: one gone
    /// stale could hang the walk that asks.
    static func holdsAnother(_ path: String, _ uuid: String) -> Bool {
        if let flags = mountFlags(at: path), flags & UInt32(MNT_LOCAL) == 0 { return true }
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey])
        return values?.volumeUUIDString != uuid
    }

    /// The flags of what's mounted right at `path`, from the mount table as the system has it (`MNT_NOWAIT`: no file
    /// system is asked, so a stale share can't hang it); nil when nothing is mounted there.
    static func mountFlags(at path: String) -> UInt32? {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return nil }
        let buffer = UnsafeMutablePointer<statfs>.allocate(capacity: Int(count))
        defer { buffer.deallocate() }
        let got = getfsstat(buffer, Int32(Int(count) * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        for mount in UnsafeBufferPointer(start: buffer, count: Int(max(got, 0))) {
            var on = mount.f_mntonname
            let name = withUnsafeBytes(of: &on) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name == path { return mount.f_flags }
        }
        return nil
    }
}
