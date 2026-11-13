import AppKit
import SwiftUI

@main
struct CommaSwitcherApp: App {
    @State private var model = MenuModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Text(model.style?.label ?? "？")
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
        // システム設定で変えられたときもメニューバーの表示を合わせるため、定期的に読み直す。
        // 設定ファイルは cfprefsd が書くので変更通知を受け取れず、読み取りは軽いので 2 秒おきにする。
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStyle() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
    }

    func refreshStyle() {
        let current = KotoeriPreferences.current()
        if current != style { style = current }
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
