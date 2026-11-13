import Foundation

/// 標準の日本語入力が持つ句読点の種類。
/// rawValue は com.apple.inputmethod.Kotoeri の JIMPrefPunctuationTypeKey に入る値で、
/// システム設定のメニューの並び順と一致する。
enum PunctuationStyle: Int, CaseIterable, Identifiable, Sendable {
    case maruTen = 0      // 。、
    case maruComma = 1    // 。，
    case periodTen = 2    // ．、
    case periodComma = 3  // ．，

    var id: Int { rawValue }

    var period: String {
        switch self {
        case .maruTen, .maruComma: "。"
        case .periodTen, .periodComma: "．"
        }
    }

    var comma: String {
        switch self {
        case .maruTen, .periodTen: "、"
        case .maruComma, .periodComma: "，"
        }
    }

    /// メニューとメニューバーに出す表記。システム設定と同じく句点、読点の順。
    var label: String { period + comma }
}
