// Renders files for the scale corpus (scripts/testbed/make_scale.py): text PDFs, scanned PDFs (pages that are only
// pictures of text) and screenshots, each with its own made-up text. Nothing is read from the user's files.
//   swiftc -O scripts/testbed/scale_render.swift -o .dev/scale_render
//   .dev/scale_render <folder> pdf|scan|shot <count> <seed>
import AppKit

let arguments = CommandLine.arguments
let folder = URL(fileURLWithPath: arguments[1])
let kind = arguments[2]
let count = Int(arguments[3])!
var seed = UInt64(arguments[4])!

func next(_ bound: Int) -> Int {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Int((seed >> 33) % UInt64(bound))
}

let english = ["quarterly", "report", "budget", "client", "meeting", "invoice", "schedule", "project", "review", "update",
               "delivery", "contract", "renewal", "payment", "travel", "hotel", "flight", "summary", "decision", "risk",
               "release", "testing", "support", "customer", "survey", "training", "office", "policy", "approval", "plan"]
let chinese = ["季度", "报告", "预算", "客户", "会议", "发票", "排期", "项目", "评审", "更新", "交付", "合同", "续签", "付款",
               "出差", "酒店", "航班", "总结", "决定", "风险", "上线", "测试", "客服", "问卷", "培训", "办公室", "制度", "审批"]

func sentence() -> String {
    if next(2) == 0 {
        return (0..<(8 + next(8))).map { _ in english[next(english.count)] }.joined(separator: " ").capitalized + "."
    }
    return (0..<(6 + next(8))).map { _ in chinese[next(chinese.count)] }.joined() + "。"
}

func paragraph(_ sentences: Int) -> String { (0..<sentences).map { _ in sentence() }.joined(separator: " ") }

func draw(_ text: String, in rect: CGRect, size: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 4
    (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: style])
}

func picture(_ text: String, width: Int, height: Int, size: CGFloat) -> CGImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor(white: 0.97, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    draw(text, in: CGRect(x: 40, y: 40, width: width - 80, height: height - 80), size: size)
    image.unlockFocus()
    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

func pdf(_ url: URL, pages: Int, scanned: Bool) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    for _ in 0..<pages {
        context.beginPDFPage(nil)
        if scanned {
            context.draw(picture(paragraph(6 + next(6)), width: 1224, height: 1584, size: 30), in: box)
        } else {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            draw(paragraph(8 + next(10)), in: box.insetBy(dx: 60, dy: 60), size: 13)
            NSGraphicsContext.restoreGraphicsState()
        }
        context.endPDFPage()
    }
    context.closePDF()
}

try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for index in 0..<count {
    autoreleasepool {
        switch kind {
        case "pdf":
            pdf(folder.appendingPathComponent(String(format: "doc-%05d.pdf", index)), pages: 1 + next(6), scanned: false)
        case "scan":
            pdf(folder.appendingPathComponent(String(format: "scan-%05d.pdf", index)), pages: 1 + next(2), scanned: true)
        default:
            let url = folder.appendingPathComponent(String(format: "Screenshot 2026-%02d-%02d at %d.%02d.%02d.png",
                                                           1 + next(12), 1 + next(28), 1 + next(12), next(60), index % 60))
            let rep = NSBitmapImageRep(cgImage: picture(paragraph(4 + next(6)), width: 1440, height: 900, size: 22))
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
print("rendered \(count) \(kind) in \(folder.path)")
