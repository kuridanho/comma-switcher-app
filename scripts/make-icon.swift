// アプリのアイコンを描く。使い方: swift scripts/make-icon.swift <案 D|E|F> <出力 PNG>
// 1024px の画布に、macOS のアイコンの決まりに沿って 824px の角丸の本体を描く。
import AppKit
import CoreText

let variant = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let size: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func gradient(_ ctx: CGContext, _ path: CGPath, _ top: CGColor, _ bottom: CGColor) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()
}

/// 字形の輪郭の中心を (cx, cy) に合わせて一文字描く。
func glyph(_ ctx: CGContext, _ ch: String, size fs: CGFloat, center: CGPoint, color c: CGColor, weight: String = "HiraginoSans-W6") {
    let font = CTFontCreateWithName(weight as CFString, fs, nil)
    let attr = NSAttributedString(string: ch, attributes: [.font: font, .foregroundColor: NSColor(cgColor: c)!])
    let line = CTLineCreateWithAttributedString(attr)
    ctx.textMatrix = .identity
    let b = CTLineGetImageBounds(line, nil)
    ctx.textPosition = CGPoint(x: center.x - b.midX, y: center.y - b.midY)
    CTLineDraw(line, ctx)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

// 影
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(shape); ctx.setFillColor(color(0x000000)); ctx.fillPath()
ctx.restoreGState()

/// 記号に、真下へ落ちるかすかな影を付けて描く。
func symbol(_ chars: [String], size fs: CGFloat, color c: CGColor, gap: CGFloat = 60) {
    let font = CTFontCreateWithName("HiraginoSans-W7" as CFString, fs, nil)
    ctx.textMatrix = .identity
    let lines = chars.map { ch -> (CTLine, CGRect) in
        let l = CTLineCreateWithAttributedString(NSAttributedString(string: ch, attributes: [.font: font, .foregroundColor: NSColor(cgColor: c)!]))
        return (l, CTLineGetImageBounds(l, nil))
    }
    let total = lines.reduce(0) { $0 + $1.1.width } + gap * CGFloat(lines.count - 1)
    let minY = lines.map(\.1.minY).min()!, maxY = lines.map(\.1.maxY).max()!
    var x = size / 2 - total / 2
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, 0.18))
    for (l, b) in lines {
        ctx.textPosition = CGPoint(x: x - b.minX, y: size / 2 - (minY + maxY) / 2)
        CTLineDraw(l, ctx)
        x += b.width + gap
    }
    ctx.restoreGState()
}

switch variant {
case "D":
    // 白に近い灰の地に、濃い灰の読点を一つ。
    gradient(ctx, shape, color(0xFFFFFF), color(0xE4E4EA))
    symbol(["、"], size: 760, color: color(0x2C2C30))
case "E":
    // 青の地に、白の句点と読点。
    gradient(ctx, shape, color(0x4FA0FF), color(0x1460E6))
    symbol(["。", "、"], size: 520, color: color(0xFFFFFF), gap: 70)
case "F":
    // 黒鉛色の地に、白のカンマを一つ。
    gradient(ctx, shape, color(0x8A8A92), color(0x4A4A52))
    symbol(["，"], size: 760, color: color(0xFFFFFF))
default:
    fatalError("案は D、E、F のいずれか")
}

// 上端のかすかな光沢
ctx.saveGState(); ctx.addPath(shape); ctx.setStrokeColor(color(0xFFFFFF, 0.35)); ctx.setLineWidth(3); ctx.strokePath(); ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
