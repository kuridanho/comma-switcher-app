import AppKit
import CoreText

/// メニューバーに出す句読点の画像を作る。
///
/// 全角の。、は字形が枠の左下に寄り、右と上に大きな余白があるため、
/// 文字のまま出すとメニューバーで間延びして見える。そこで字形の実際の
/// 輪郭だけを切り出して詰めて並べ、二つ組を上下中央にそろえたテンプレート画像にする。
enum MenuBarLabel {
    static let fontSize: CGFloat = 17
    static let height: CGFloat = 16
    static let gap: CGFloat = 2

    static func image(for text: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: fontSize)
        let lines = text.map { ch -> (CTLine, CGRect) in
            let str = NSAttributedString(string: String(ch), attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(str)
            return (line, CTLineGetImageBounds(line, nil))
        }
        let width = lines.reduce(0) { $0 + $1.1.width } + gap * CGFloat(max(lines.count - 1, 0))
        let inkMinY = lines.map(\.1.minY).min() ?? 0
        let inkMaxY = lines.map(\.1.maxY).max() ?? 0
        let offsetY = (height - (inkMaxY - inkMinY)) / 2 - inkMinY

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            var x: CGFloat = 0
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
