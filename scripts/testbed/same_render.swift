// Renders the same-topic corpus's papers and screens (scripts/testbed/make_same_topic.py): a text PDF, a photo of the
// same paper (grey background, the sheet a little turned), a screenshot. Text set in the system's fonts; everything
// in it is made up.
//
//     swift scripts/testbed/same_render.swift <spec.json>
//     spec: [{"path": "…", "kind": "pdf" | "paper" | "screen", "lines": ["…", …]}, …]
import AppKit
import CoreText
import Foundation

struct Item: Decodable {
    let path: String
    let kind: String
    let lines: [String]
}

func draw(_ lines: [String], in context: CGContext, x: CGFloat, top: CGFloat, size: CGFloat, gray: CGFloat = 0) {
    let font = CTFontCreateWithName("PingFang SC" as CFString, size, nil)
    let color = NSColor(white: gray, alpha: 1)
    for (index, line) in lines.enumerated() {
        let text = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: color])
        context.textPosition = CGPoint(x: x, y: top - CGFloat(index) * size * 1.7)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }
}

func pdf(_ item: Item) throws {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    draw(item.lines, in: context, x: 60, top: 760, size: 15)
    context.endPDFPage()
    context.closePDF()
    try (data as Data).write(to: URL(fileURLWithPath: item.path))
}

func bitmap(width: Int, height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
}

func write(_ context: CGContext, to path: String, type: NSBitmapImageRep.FileType) throws {
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    let data = rep.representation(using: type, properties: type == .jpeg ? [.compressionFactor: 0.85] : [:])!
    try data.write(to: URL(fileURLWithPath: path))
}

/// A sheet of paper photographed on a desk: a grey-brown background, the sheet a little turned, the text slightly grey.
func paper(_ item: Item) throws {
    let width = 1600, height = 1200
    let context = bitmap(width: width, height: height)
    context.setFillColor(CGColor(red: 0.55, green: 0.5, blue: 0.45, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
    context.rotate(by: -0.04)
    let sheet = CGRect(x: -560, y: -520, width: 1120, height: 1040)
    context.setFillColor(CGColor(gray: 0.94, alpha: 1))
    context.fill(sheet)
    draw(item.lines, in: context, x: sheet.minX + 70, top: sheet.maxY - 110, size: 40, gray: 0.15)
    try write(context, to: item.path, type: .jpeg)
}

/// A window on a screen: a title bar, then the lines as a settings page shows them.
func screen(_ item: Item) throws {
    let width = 1440, height = 900
    let context = bitmap(width: width, height: height)
    context.setFillColor(CGColor(gray: 0.97, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(gray: 0.86, alpha: 1))
    context.fill(CGRect(x: 0, y: height - 56, width: width, height: 56))
    for (index, color) in [CGColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), CGColor(red: 1, green: 0.74, blue: 0.18, alpha: 1),
                           CGColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(x: 22 + index * 26, y: height - 37, width: 16, height: 16))
    }
    context.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 260, height: height - 56))
    draw(item.lines, in: context, x: 320, top: CGFloat(height) - 140, size: 34)
    try write(context, to: item.path, type: .png)
}

let spec = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
for item in spec {
    switch item.kind {
    case "pdf": try pdf(item)
    case "paper": try paper(item)
    case "screen": try screen(item)
    default: fatalError("unknown kind \(item.kind)")
    }
}
print("rendered \(spec.count)")
