import AppKit
import SwiftUI

@main
struct CommaSwitcherApp: App {
    @State private var model = MenuModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(nsImage: MenuBarLabel.image(for: model.style?.label ?? "？"))
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
@Observable
final class MenuModel {
    var style: PunctuationStyle?
    var launchAtLogin: Bool

    init() {
        style = KotoeriPreferences.current()
        launchAtLogin = LoginItem.isEnabled
        // メニューを開くたびに読み直す。このアプリが持つメニューはメニューバーの一つだけ。
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// システム設定など外から変えられた場合に合わせて読み直す。
    func refresh() {
        style = KotoeriPreferences.current()
        launchAtLogin = LoginItem.isEnabled
    }

    func select(_ newStyle: PunctuationStyle) {
        style = KotoeriPreferences.apply(newStyle)
    }

    func toggleLaunchAtLogin() {
        do {
            try LoginItem.setEnabled(!launchAtLogin)
        } catch {
            NSLog("ログイン項目の切り替えに失敗しました: \(error)")
        }
        launchAtLogin = LoginItem.isEnabled
    }
}

struct MenuContent: View {
    let model: MenuModel

    var body: some View {
        ForEach(PunctuationStyle.allCases) { style in
            Toggle(style.label, isOn: Binding(
                get: { model.style == style },
                set: { _ in model.select(style) }
            ))
        }
        Divider()
        Toggle("ログイン時に起動", isOn: Binding(
            get: { model.launchAtLogin },
            set: { _ in model.toggleLaunchAtLogin() }
        ))
        Divider()
        Button("Comma Switcher を終了") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
