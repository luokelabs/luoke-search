import CoreGraphics
import Foundation
import Testing
@testable import LuokeSearchKit

// Files that are broken or unusual (coverage, 10-22): zips damaged where it matters, read as zips and as the Office
// files they'd be, and SVG pictures, which ImageIO doesn't open. Made here; nothing of the user's.
struct BadZipTests {
    /// Where the central directory starts (from the end record) and a damaged copy of `data`.
    static func damaged(_ data: Data, at offset: (Int) -> Int, to bytes: [UInt8]) -> Data {
        var copy = [UInt8](data)
        let end = data.count - 22
        let directory = Int(data.le32(end + 16))
        for (index, byte) in bytes.enumerated() { copy[offset(directory) + index] = byte }
        return Data(copy)
    }

    static let docx = ZipWriter.docx(paragraphs: ["年度总结"])

    @Test("A zip whose directory is damaged isn't read, and says why")
    func damagedDirectory() throws {
        let broken = Self.damaged(Self.docx, at: { $0 }, to: [0, 0, 0, 0])   // the first directory entry's signature
        #expect { try ZipArchive(data: broken) } throws: { "\($0)" == "damaged zip directory" }
        #expect { try ZipArchive(data: Data("not a zip at all".utf8)) } throws: { "\($0)" == "not a zip file" }
    }

    @Test("A zip whose entry is damaged opens, but that entry isn't read")
    func damagedEntry() throws {
        let broken = Self.damaged(Self.docx, at: { _ in 0 }, to: [0, 0, 0, 0])   // the first entry's local header
        let zip = try ZipArchive(data: broken)
        #expect(zip.names.contains("word/document.xml"))
        #expect { try zip.read("word/document.xml") } throws: { "\($0)" == "damaged zip entry" }
        #expect(try zip.read("not/there.xml") == nil)
    }

    @Test("A zip compressed some way other than stored or deflate isn't read")
    func unsupportedCompression() throws {
        let bzip2 = Self.damaged(Self.docx, at: { $0 + 10 }, to: [12, 0])   // the directory's method field: 12 = bzip2
        let zip = try ZipArchive(data: bzip2)
        #expect { try zip.read("word/document.xml") } throws: { "\($0)" == "unsupported zip compression" }
    }

    @Test("Office files damaged each of those ways are read as couldn't-be-read, not crashed on")
    func asDocuments() throws {
        let scratch = try Scratch()
        let cases: [(String, Data)] = [
            ("目录坏了.docx", Self.damaged(Self.docx, at: { $0 }, to: [0, 0, 0, 0])),
            ("条目坏了.docx", Self.damaged(Self.docx, at: { _ in 0 }, to: [0, 0, 0, 0])),
            ("压缩方式不认识.docx", Self.damaged(Self.docx, at: { $0 + 10 }, to: [12, 0])),
        ]
        for (name, data) in cases {
            let url = try scratch.write(name, data: data)
            let reading = Reader.read(url, kind: .doc)
            guard case .failed = reading.outcome else {
                Issue.record("\(name): \(reading.outcome)")
                continue
            }
            #expect(reading.pieces.isEmpty, "\(name)")
        }
        let fine = try scratch.write("好的.docx", data: Self.docx)
        #expect(Reader.read(fine, kind: .doc).pieces.contains { $0.text.contains("年度总结") })
    }
}

struct SVGTests {
    /// Blue, a red band along its top, a white circle in the middle.
    static let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="300" height="150" viewBox="0 0 300 150">
          <rect width="300" height="150" fill="#3366cc"/><rect width="300" height="20" fill="#ff0000"/>
          <circle cx="150" cy="75" r="50" fill="#ffffff"/>
        </svg>
        """

    @Test("An SVG picture has its own size and is drawn at most twice that, at most as big as asked, on any screen")
    func svgPictures() throws {
        let scratch = try Scratch()
        let url = try scratch.write("图标.svg", Self.svg)
        let info = try #require(Pictures.info(url))
        #expect(info.width == 300 && info.height == 150)
        #expect(info.taken == nil)
        let boxed = try scratch.write("只有视框.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 640 480\"><rect width=\"640\" height=\"480\"/></svg>")
        let box = try #require(Pictures.info(boxed))
        #expect(box.width == 640 && box.height == 480)    // no width and height: its viewBox's
        // Twice its size when that fits; else as big as asked (it used to be 2× what was asked, times the screen's
        // scale: 400 for 100 on a Retina Mac).
        for (asked, width) in [(100, 100), (400, 400), (1024, 600), (3000, 600)] {
            let image = try Pictures.image(url, maxPixels: asked)
            #expect(image.width == width && image.height == width / 2, "asked for \(asked)")
        }
        // Upright: the red band on top, blue under it, the circle in the middle. In a bitmap of its own, 8-bit sRGB:
        // not the 16-bit one AppKit made for the screen.
        let drawn = try Pictures.image(url, maxPixels: 600)
        #expect(drawn.bitsPerComponent == 8 && drawn.colorSpace?.name == CGColorSpace.sRGB)
        let pixel = { ReadsPictures.GlobalSearchTests.pixel(drawn, x: $0, y: $1) }
        #expect(pixel(10, 10)[0] > 200 && pixel(10, 10)[2] < 60)
        #expect(pixel(10, 290)[2] > 150 && pixel(10, 290)[0] < 100)
        #expect(pixel(300, 150).allSatisfy { $0 > 240 })
        // Not an SVG, nor anything ImageIO knows: no size, and no picture.
        let junk = try scratch.write("坏图.png", data: Data("not a picture".utf8))
        #expect(Pictures.info(junk) == nil)
        #expect(throws: Pictures.Failure.self) { try Pictures.image(junk, maxPixels: 100) }
        let empty = try scratch.write("空的.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>")
        #expect(Pictures.svgImage(empty) == nil)          // no size, nothing to draw
        #expect(Pictures.info(empty) == nil)
    }

    @Test("An SVG icon is skipped as small as a PNG of its size is; a bigger SVG is read")
    func svgIconsAreSmall() throws {
        let scratch = try Scratch()
        func svg(_ side: Int) -> String {
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(side)\" height=\"\(side)\"><rect width=\"\(side)\" "
                + "height=\"\(side)\" fill=\"#3366cc\"/></svg>"
        }
        let icon = try scratch.write("图标.svg", svg(100))
        let square = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let png = try scratch.write("图标.png", data: Drawn.png(square.makeImage()!))
        for url in [icon, png] {
            let reading = Reader.read(url, kind: .image)
            guard case .skipped(let why) = reading.outcome else { Issue.record("\(url.lastPathComponent) was read"); continue }
            #expect(why == "small image")
            #expect(reading.info["width"] == "100" && reading.info["height"] == "100")
        }
        // An SVG's own size counts, not the size it's drawn at: 200 is below 256, though drawn at 400.
        guard case .skipped = Reader.read(try scratch.write("小图.svg", svg(200)), kind: .image).outcome else {
            Issue.record("a 200 × 200 SVG was read"); return
        }
        let big = Reader.read(try scratch.write("大图.svg", svg(300)), kind: .image)
        #expect(big.info["width"] == "300")
        #expect(big.pieces.contains { $0.kind == .image })
    }

    @Test("An SVG may declare any size: a huge one doesn't crash the read (nor a screenshot's OCR), a hairline is read")
    func svgDeclaredSizes() throws {
        let scratch = try Scratch()
        func svg(_ width: String, _ height: String) -> String {
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\"><rect width=\"100%\" "
                + "height=\"100%\" fill=\"#3366cc\"/></svg>"
        }
        // 1e20 wide: an Int can't hold it (review 11-02: the process ended). Its sides are kept to 1 … svgLargest.
        let wide = Reader.read(try scratch.write("宽.svg", svg("1e20", "10")), kind: .image)
        #expect(wide.info["width"] == String(Int(Pictures.svgLargest)) && wide.info["height"] == "10")
        #expect(wide.pieces.contains { $0.kind == .image })
        #expect(try Pictures.image(scratch.url.appendingPathComponent("宽.svg"), maxPixels: 1024).width == 1024)
        // Read as a screenshot: OCR at a size worked out from its sides, which overflowed at 1e17 (10 high: the OCR has
        // a strip to read, not a 3000-pixel square that slowed the tests around it).
        let shot = Reader.read(try scratch.write("Screenshot 2026-11-02 at 22.00.00.svg", svg("1e17", "10")),
                               kind: .screenshot)
        #expect(shot.info["width"] == String(Int(Pictures.svgLargest)))
        #expect(shot.pieces.contains { $0.kind == .image })
        // A hairline 1000 × 0.4: one pixel high, read (it rounded to 0 and was "can't open this picture").
        let hairline = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1000\" height=\"0.4\"><rect width=\"1000\" "
            + "height=\"0.4\"/></svg>"
        let line = Reader.read(try scratch.write("分隔线.svg", hairline), kind: .image)
        #expect(line.info["width"] == "1000" && line.info["height"] == "1")
        #expect(line.pieces.contains { $0.kind == .image })
    }
}

struct MCPErrorTests {
    struct Broke: Error {}
    /// What a real error's text can be: a line of the user's own.
    struct Quoting: Error, CustomStringConvertible { var description: String { "读不了：工资条.pdf" } }

    static func server() -> MCPServer {
        let server = MCPServer(name: "test", version: "1")
        server.add(MCPServer.Tool(name: "breaks", title: "坏的", description: "总是出错",
                                  schema: ["type": "object"]) { _, _ in throw Broke() })
        server.add(MCPServer.Tool(name: "quotes", title: "引", description: "出错时引用户的字",
                                  schema: ["type": "object"]) { _, _ in throw Quoting() })
        server.add(MCPServer.Tool(name: "refuses", title: "拒", description: "好好地说不行",
                                  schema: ["type": "object"]) { _, _ in throw ToolFailure("no", "不行") })
        server.add(MCPServer.Tool(name: "says", title: "说", description: "回一句",
                                  schema: ["type": "object", "required": ["what"]]) { arguments, _ in
            ("说了：\(arguments["what"] ?? "")", [:])
        })
        server.add(MCPServer.Resource(uri: "luoke-search://b", name: "乙") { ["n": 2] })
        server.add(MCPServer.Resource(uri: "luoke-search://a", name: "甲") { "现成的字" })
        server.add(MCPServer.Resource(uri: "luoke-search://broken", name: "坏的") { throw Broke() })
        return server
    }

    static func error(_ answer: [String: Any]?) -> (code: Int, message: String)? {
        guard let error = answer?["error"] as? [String: Any] else { return nil }
        return (error["code"] as? Int ?? 0, error["message"] as? String ?? "")
    }

    static func call(_ server: MCPServer, _ params: [String: Any]) -> [String: Any]? {
        server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": params])
    }

    @Test("Requests that aren't JSON-RPC 2.0 get the protocol's errors")
    func notJSONRPC() throws {
        let server = Self.server()
        let bytes = try #require(server.handle(json: Data("{not json".utf8)))
        let parsed = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        #expect(Self.error(parsed)?.code == -32700)
        #expect(Self.error(server.handle(["jsonrpc": "1.0", "id": 1, "method": "ping"]))?.code == -32600)
        #expect(Self.error(server.handle(["id": 1, "method": "ping"]))?.code == -32600)
        #expect(Self.error(server.handle([1, 2, 3]))?.code == -32600)
        #expect(Self.error(server.handle(["jsonrpc": "2.0", "id": true, "method": "ping"]))?.code == -32600)
        #expect(Self.error(server.handle(["jsonrpc": "2.0", "id": 1, "method": "ping", "params": [1]]))?.code == -32602)
        #expect(Self.error(server.handle(["jsonrpc": "2.0", "id": 1, "method": "nothing/here"]))?.code == -32601)
        #expect(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)   // no answer
    }

    @Test("A tool that isn't there, arguments that aren't an object, a tool that breaks")
    func toolErrors() {
        let server = Self.server()
        let missing = Self.error(Self.call(server, ["name": "nope"]))
        #expect(missing?.code == -32602 && missing?.message.contains("nope") == true)
        #expect(Self.error(Self.call(server, ["name": "says", "arguments": "what"]))?.code == -32602)
        let broke = Self.error(Self.call(server, ["name": "breaks"]))
        #expect(broke?.code == -32603 && broke?.message == "工具内部出错")   // nothing of the error itself
        let short = Self.call(server, ["name": "says", "arguments": [:]])?["result"] as? [String: Any]
        #expect(short?["isError"] as? Bool == true)
        #expect(((short?["structuredContent"] as? [String: Any])?["code"] as? String) == "invalid")
        let fine = Self.call(server, ["name": "says", "arguments": ["what": "好"]])?["result"] as? [String: Any]
        #expect(((fine?["content"] as? [[String: Any]])?.first?["text"] as? String) == "说了：好")
    }

    @Test("A tool's own fault leaves one line for the log: which one and the error's type, nothing else")
    func faultsAreLogged() {
        let server = Self.server()
        var lines: [String] = []
        server.logged = { lines.append($0) }
        _ = Self.call(server, ["name": "breaks"])
        _ = server.handle(["jsonrpc": "2.0", "id": 1, "method": "resources/read",
                           "params": ["uri": "luoke-search://broken"]])
        _ = Self.call(server, ["name": "quotes", "arguments": ["q": "工资"]])
        #expect(lines == ["tools/call breaks 出错 Broke", "resources/read luoke-search://broken 出错 Broke",
                          "tools/call quotes 出错 Quoting"])
    }

    @Test("Only faults are logged, and only names registered here: not what the agent sent")
    func logNamesOnlyWhatIsRegistered() {
        let server = Self.server()
        var lines: [String] = []
        server.logged = { lines.append($0) }
        _ = Self.call(server, ["name": "nope"])
        _ = Self.call(server, ["name": "refuses"])
        _ = Self.call(server, ["name": "says", "arguments": ["what": "好"]])
        _ = server.handle(["jsonrpc": "2.0", "id": 1, "method": "resources/read", "params": ["uri": "luoke-search://nope"]])
        #expect(lines.isEmpty)
        #expect(server.which("tools/call", ["name": "breaks"]) == "tools/call breaks")
        #expect(server.which("tools/call", ["name": "工资条"]) == "tools/call")
        #expect(server.which("tools/call", ["name": 1]) == "tools/call")
        #expect(server.which("resources/read", ["uri": "luoke-search://a"]) == "resources/read luoke-search://a")
        #expect(server.which("resources/read", ["uri": "luoke-search://工资条"]) == "resources/read")
        #expect(server.which("resources/read", ["name": "breaks"]) == "resources/read")
    }

    @Test("Resources are listed in order and read; an unknown or broken one is an error")
    func resources() throws {
        let server = Self.server()
        let listed = server.handle(["jsonrpc": "2.0", "id": 1, "method": "resources/list"])?["result"] as? [String: Any]
        let entries = try #require(listed?["resources"] as? [[String: Any]])
        #expect(entries.map { $0["uri"] as? String } == ["luoke-search://a", "luoke-search://b", "luoke-search://broken"])
        #expect(entries.allSatisfy { $0["mimeType"] as? String == "application/json" })
        let read = { (uri: String) in
            server.handle(["jsonrpc": "2.0", "id": 1, "method": "resources/read", "params": ["uri": uri]])
        }
        let text = ((read("luoke-search://a")?["result"] as? [String: Any])?["contents"] as? [[String: Any]])?.first?["text"]
        #expect(text as? String == "现成的字")
        let json = ((read("luoke-search://b")?["result"] as? [String: Any])?["contents"] as? [[String: Any]])?.first?["text"]
        #expect(json as? String == "{\"n\":2}")
        #expect(Self.error(read("luoke-search://nope"))?.code == -32002)
        #expect(Self.error(read("luoke-search://broken"))?.code == -32603)
    }

    @Test("An answer that can't be written as JSON becomes an internal error, not a crash")
    func unencodable() throws {
        let bytes = try #require(MCPServer.encode(["jsonrpc": "2.0", "id": 1, "result": ["score": Double.infinity]]))
        let parsed = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        #expect(Self.error(parsed)?.code == -32603)
    }
}

struct QuickTimeScriptTests {
    @Test("A file name with quotes and backslashes is escaped inside the AppleScript's string")
    func escaping() {
        let script = Opener.quickTimeScript(URL(fileURLWithPath: #"/tmp/录音 "第一段" a\b.m4a"#), at: 12.5)
        #expect(script.contains(#"set movie to open POSIX file "/tmp/录音 \"第一段\" a\\b.m4a""#))
        #expect(script.contains("set current time of movie to 12.5"))
        #expect(script.contains("tell application \"QuickTime Player\""))
        // The string closes only where it should: every quote inside it is escaped.
        let line = script.split(separator: "\n").first { $0.contains("POSIX file") }.map(String.init) ?? ""
        let inside = line.drop { $0 != "\"" }.dropFirst().dropLast()
        var escaped = false, unescapedQuotes = 0
        for character in inside {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true } else if character == "\"" { unescapedQuotes += 1 }
        }
        #expect(unescapedQuotes == 0)
        #expect(Opener.quickTimeScript(URL(fileURLWithPath: "/tmp/a.mp4"), at: -3).contains("current time of movie to 0"))
    }
}

/// Playing at a moment handed to luoke's own program (`LUOKE_HOST_FD`): none of these reaches `osascript`, which only
/// runs when `playOnHost` says nil.
struct PlayOnHostTests {
    static let file = URL(fileURLWithPath: "/tmp/录音 \"第一段\"\n第二行.m4a")

    static func pipeEnds() throws -> (read: Int32, write: Int32) {
        var ends: [Int32] = [0, 0]
        try #require(pipe(&ends) == 0)
        return (ends[0], ends[1])
    }

    static func play(_ descriptor: Int32, wait: TimeInterval = 1) -> Bool? {
        Opener.playOnHost(file, at: 12.5, environment: [Opener.hostVariable: String(descriptor)], wait: wait)
    }

    /// Everything waiting at `descriptor`, which the writer has closed.
    static func received(_ descriptor: Int32) -> Data {
        FileHandle(fileDescriptor: descriptor, closeOnDealloc: true).readDataToEndOfFile()
    }

    @Test("luoke hears the socket is up, on the channel it gave; no channel, nothing to say")
    func tellsHostItIsUp() throws {
        let ends = try Self.pipeEnds()
        Opener.tellHostUp(environment: [Opener.hostVariable: String(ends.write)])
        close(ends.write)
        #expect(String(decoding: Self.received(ends.read), as: UTF8.self) == "{\"up\": true}\n")
        Opener.tellHostUp(environment: [:])
    }

    @Test("Not started by luoke's own program: nothing is handed over, the caller goes on as before")
    func noHost() {
        #expect(Opener.playOnHost(Self.file, at: 1, environment: [:]) == nil)
        #expect(Opener.playOnHost(Self.file, at: 1, environment: [Opener.hostVariable: ""]) == nil)
    }

    @Test("One line of JSON, however the name is written", arguments: [false, true])
    func oneLine(socket: Bool) throws {
        var ends: [Int32] = [0, 0]
        if socket { try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0) } else { try #require(pipe(&ends) == 0) }
        #expect(Self.play(ends[1]) == true)
        close(ends[1])
        let said = Self.received(ends[0])
        #expect(said.last == UInt8(ascii: "\n"))
        #expect(said.filter { $0 == UInt8(ascii: "\n") }.count == 1)
        let line = try #require(try JSONSerialization.jsonObject(with: said) as? [String: Any])
        #expect(line.count == 2 && line["play"] as? String == Self.file.path && line["at"] as? Double == 12.5)
        #expect(String(decoding: said, as: UTF8.self).hasPrefix(#"{"play": "/tmp/"#))
    }

    @Test("Before the start is the start, and a time that isn't one is nothing to send")
    func oddTimes() throws {
        let line = try #require(Opener.playLine(URL(fileURLWithPath: "/tmp/a.mp4"), at: -3))
        #expect(String(decoding: line, as: UTF8.self) == "{\"play\": \"/tmp/a.mp4\", \"at\": 0.0}\n")
        #expect(Opener.playLine(Self.file, at: .nan) == nil)
        #expect(Opener.playLine(Self.file, at: .infinity) == nil)
    }

    @Test("The other end gone: false, so the file is opened plainly, and this process lives (no SIGPIPE)")
    func nobodyThere() throws {
        let ends = try Self.pipeEnds()
        defer { close(ends.write) }
        close(ends.read)
        #expect(Self.play(ends.write) == false)
    }

    @Test("The other end not reading: false after the wait, never stuck under the server's lock")
    func notReading() throws {
        let ends = try Self.pipeEnds()
        defer { close(ends.read); close(ends.write) }
        _ = fcntl(ends.write, F_SETFL, fcntl(ends.write, F_GETFL) | O_NONBLOCK)
        let filler = [UInt8](repeating: 0, count: 4096)
        while write(ends.write, filler, filler.count) > 0 {}
        _ = fcntl(ends.write, F_SETFL, fcntl(ends.write, F_GETFL) & ~O_NONBLOCK)
        let started = Date()
        #expect(Self.play(ends.write, wait: 0.2) == false)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test("What isn't a channel to write to is refused: not written to, and no `osascript` either",
          arguments: ["abc", "-1", "1", "2", "99999", "3x"])
    func notADescriptor(given: String) {
        #expect(Opener.playOnHost(Self.file, at: 1, environment: [Opener.hostVariable: given]) == false)
    }

    @Test("A number that's a file here (the variable inherited without the descriptor) isn't written into")
    func aFileIsLeftAlone() throws {
        let scratch = try Scratch()
        let path = scratch.path + "/index.db"
        let descriptor = open(path, O_CREAT | O_WRONLY, 0o600)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        #expect(Self.play(descriptor) == false)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).isEmpty)
    }

    @Test("The read end isn't one to write to")
    func theReadEnd() throws {
        let ends = try Self.pipeEnds()
        defer { close(ends.read); close(ends.write) }
        #expect(Self.play(ends.read) == false)
    }
}
