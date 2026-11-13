import AppKit
import Foundation

/// 標準の日本語入力の句読点設定を読み書きする。
///
/// 書き換えただけでは動いている入力メソッドは古い値を使い続けるため、
/// 入力メソッドのプロセスに SIGHUP を送って終了させる。プロセスは次に
/// 日本語入力を使った時点で起動し直し、新しい値を読み込む。
enum KotoeriPreferences {
    static let domain = "com.apple.inputmethod.Kotoeri"
    static let punctuationKey = "JIMPrefPunctuationTypeKey"
    /// RomajiTyping と KanaTyping の両方を対象にする。
    static let inputMethodBundlePrefix = "com.apple.inputmethod.Kotoeri."

    /// 現在の設定。値がない、または想定外の値のときは nil。
    static func current() -> PunctuationStyle? {
        CFPreferencesAppSynchronize(domain as CFString)
        guard let value = CFPreferencesCopyAppValue(punctuationKey as CFString, domain as CFString) as? Int else {
            return nil
        }
        return PunctuationStyle(rawValue: value)
    }

    /// 設定を書き換え、入力メソッドを再起動させる。書き戻した値を読み直して返す。
    @discardableResult
    static func apply(_ style: PunctuationStyle) -> PunctuationStyle? {
        CFPreferencesSetValue(
            punctuationKey as CFString,
            style.rawValue as CFNumber,
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        restartInputMethods()
        return current()
    }

    /// 動いている標準日本語入力のプロセスに SIGHUP を送る。
    static func restartInputMethods() {
        let targets = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier?.hasPrefix(inputMethodBundlePrefix) == true
        }
        for app in targets {
            kill(app.processIdentifier, SIGHUP)
        }
    }
}
