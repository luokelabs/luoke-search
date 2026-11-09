import Compression
import Foundation

/// Reads entries of a zip file (docx, xlsx, pptx, odt are zips of XML). Stored and deflated entries only, no Zip64:
/// that covers what office suites write. One entry is never inflated past `maxEntryBytes`, so a zip bomb can't take
/// the machine's memory; all that's read of one archive, never past `totalBytes` (`fits`).
public struct ZipArchive {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localOffset: Int

        /// What reading it takes: its bytes inflated, or copied out if that's more (data said to inflate to little).
        var cost: Int { max(size, compressedSize) }
    }

    public static let maxEntryBytes = 256 << 20
    /// What all the entries read from one archive may come to (pre-release review, should-fix 3: a presentation
    /// naming one slide of 256 MB thousands of times had it inflated each time).
    public static let maxTotalBytes = 1 << 30

    /// What's been inflated so far, shared by copies of the archive, and whether an entry was left unread for it.
    final class Inflated {
        var bytes = 0
        var refused = false
    }

    let data: Data
    let entries: [String: Entry]
    let totalBytes: Int
    let inflated = Inflated()

    public var names: [String] { entries.keys.sorted() }

    /// Whether an entry was left unread because of `totalBytes` (`fits` said no): what was read of the file is cut.
    public var cut: Bool { inflated.refused }

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// `totalBytes`: what all the entries read may come to (smaller in tests).
    public init(data: Data, totalBytes: Int = ZipArchive.maxTotalBytes) throws {
        self.data = data
        self.totalBytes = totalBytes
        guard let end = Self.endOfCentralDirectory(in: data) else { throw Failure(description: "not a zip file") }
        let count = Int(data.le16(end + 10))
        var offset = Int(data.le32(end + 16))
        var entries: [String: Entry] = [:]
        for _ in 0..<count {
            guard offset + 46 <= data.count, data.le32(offset) == 0x0201_4B50 else {
                throw Failure(description: "damaged zip directory")
            }
            let nameLength = Int(data.le16(offset + 28))
            let extraLength = Int(data.le16(offset + 30))
            let commentLength = Int(data.le16(offset + 32))
            guard offset + 46 + nameLength <= data.count else { throw Failure(description: "damaged zip directory") }
            let nameBytes = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            let name = String(data: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)
            entries[name] = Entry(name: name, method: data.le16(offset + 10),
                                  compressedSize: Int(data.le32(offset + 20)), size: Int(data.le32(offset + 24)),
                                  localOffset: Int(data.le32(offset + 42)))
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// Whether reading the entry stays within what may be read of the archive in all (yes if there's no such entry).
    /// One that doesn't is noted (`cut`).
    public func fits(_ name: String) -> Bool {
        guard let entry = entries[name] else { return true }
        if inflated.bytes + entry.cost <= totalBytes { return true }
        inflated.refused = true
        return false
    }

    /// The entry's bytes, or nil if there's no such entry.
    public func read(_ name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        // A stored entry is its bytes as they are: one saying it's smaller would be counted short (review of
        // should-fix 3: thousands of names for one stored part of 200 MB, each said to be 1 byte).
        guard entry.method != 0 || entry.compressedSize == entry.size else { throw Failure(description: "damaged zip entry") }
        guard entry.cost <= Self.maxEntryBytes else { throw Failure(description: "zip entry too large") }
        guard fits(name) else { throw Failure(description: "zip entries too large in all") }
        inflated.bytes += entry.cost
        let local = entry.localOffset
        guard local + 30 <= data.count, data.le32(local) == 0x0403_4B50 else {
            throw Failure(description: "damaged zip entry")
        }
        let start = local + 30 + Int(data.le16(local + 26)) + Int(data.le16(local + 28))
        guard start + entry.compressedSize <= data.count else { throw Failure(description: "damaged zip entry") }
        let compressed = data.subdata(in: start..<(start + entry.compressedSize))
        switch entry.method {
        case 0:
            return compressed
        case 8:
            return try Self.inflate(compressed, size: entry.size)
        default:
            throw Failure(description: "unsupported zip compression")
        }
    }

    public func text(_ name: String) throws -> String? {
        try read(name).map { String(decoding: $0, as: UTF8.self) }
    }

    static func inflate(_ compressed: Data, size: Int) throws -> Data {
        if size == 0 { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out in
            compressed.withUnsafeBytes { input in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, size,
                                          input.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Failure(description: "damaged zip data") }
        return output
    }

    static func endOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowest = max(0, data.count - 22 - 65_535)
        var offset = data.count - 22
        while offset >= lowest {
            if data.le32(offset) == 0x0605_4B50 { return offset }
            offset -= 1
        }
        return nil
    }
}

extension Data {
    func le16(_ offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func le32(_ offset: Int) -> UInt32 {
        UInt32(le16(offset)) | UInt32(le16(offset + 2)) << 16
    }
}
