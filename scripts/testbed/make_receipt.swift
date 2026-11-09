// Makes testbed/zh/receipts/港湾咖啡小票_20261005.pdf: a scanned receipt (the page is only a picture, so it can only be
// found through OCR), with Chinese and English mixed on every line, as receipts from chain cafés in China are. The shop,
// the items and the numbers are made up.
//
//     swift scripts/testbed/make_receipt.swift testbed/zh/receipts/港湾咖啡小票_20261005.pdf
import AppKit
import CoreText
import Foundation

let lines: [(String, CGFloat)] = [
    ("HARBOR COFFEE 港湾咖啡", 46), ("Jing'an Store 静安店", 30), ("2026-10-05 09:12   No. 0418", 26), ("", 20),
    ("Oat Latte 燕麦拿铁 (L)      x1   ¥38.00", 28), ("Butter Croissant 黄油可颂   x1   ¥22.00", 28),
    ("Cold Brew 冷萃咖啡          x1   ¥32.00", 28), ("", 20),
    ("Subtotal 小计                    ¥92.00", 28), ("Member Discount 会员折扣         -¥9.20", 28),
    ("Total 合计                       ¥82.80", 34), ("", 20), ("Paid by Alipay 支付宝支付", 28),
    ("Thank you 谢谢光临", 28),
]

let width = 1000, height = 1500
let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Slightly grey paper, as a scan has.
context.setFillColor(CGColor(gray: 0.96, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
var y = CGFloat(height) - 120
for (text, size) in lines {
    let font = CTFontCreateWithName("PingFang SC" as CFString, size, nil)
    let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
    context.textPosition = CGPoint(x: 70, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    y -= size * 1.9
}
let picture = context.makeImage()!

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let data = NSMutableData()
var box = CGRect(x: 0, y: 0, width: 400, height: 600)
let pdf = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
pdf.beginPDFPage(nil)
pdf.draw(picture, in: box)
pdf.endPDFPage()
pdf.closePDF()
try (data as Data).write(to: out)
print("wrote \(out.path)")
