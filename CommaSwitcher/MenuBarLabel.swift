import AppKit
import CoreText

/// メニューバーに出す句読点の画像を作る。
///
/// 全角の。、は字形が枠の左下に寄り、右と上に大きな余白があるため、
/// 文字のまま出すとメニューバーで間延びして見える。そこで字形の実際の
/// 輪郭だけを切り出して並べ、入力ソースの表示に似た角丸の枠で囲んだテンプレート画像にする。
enum MenuBarLabel {
    static let fontSize: CGFloat = 17
    static let height: CGFloat = 16
    static let gap: CGFloat = 4
    static let padding: CGFloat = 4
    static let lineWidth: CGFloat = 1.2
    static let cornerRadius: CGFloat = 3.5

    /// 切り替えても枠の大きさが変わらないよう、四通りのうち最も幅のあるものに合わせる。
    static let frameWidth: CGFloat = ceil(
        PunctuationStyle.allCases.map { inkWidth(of: glyphs(for: $0.label)) }.max()! + padding * 2
    )

    static func glyphs(for text: String) -> [(CTLine, CGRect)] {
        let font = NSFont.systemFont(ofSize: fontSize)
        return text.map { ch in
            let str = NSAttributedString(string: String(ch), attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(str)
            return (line, CTLineGetImageBounds(line, nil))
        }
    }

    static func inkWidth(of lines: [(CTLine, CGRect)]) -> CGFloat {
        lines.reduce(0) { $0 + $1.1.width } + gap * CGFloat(max(lines.count - 1, 0))
    }

    static func image(for text: String) -> NSImage {
        let lines = glyphs(for: text)
        let inkWidth = inkWidth(of: lines)
        let width = max(frameWidth, ceil(inkWidth + padding * 2))
        let inkMinY = lines.map(\.1.minY).min() ?? 0
        let inkMaxY = lines.map(\.1.maxY).max() ?? 0
        let offsetY = (height - (inkMaxY - inkMinY)) / 2 - inkMinY

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let frame = NSBezierPath(
                roundedRect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                xRadius: cornerRadius, yRadius: cornerRadius
            )
            frame.lineWidth = lineWidth
            NSColor.black.setStroke()
            frame.stroke()
            var x = (width - inkWidth) / 2
            for (line, bounds) in lines {
                ctx.textPosition = CGPoint(x: x - bounds.minX, y: offsetY)
                CTLineDraw(line, ctx)
                x += bounds.width + gap
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = text
        return image
    }
}
