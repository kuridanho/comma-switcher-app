# Comma Switcher

macOS 標準の日本語入力で使う句読点の種類を、メニューバーから切り替えるアプリです。システム設定と同じ四通り（。、 / 。， / ．、 / ．，）を同じ順で並べ、いま選ばれている組み合わせを、角丸の枠で囲んでメニューバーに表示します。メニューにはログイン時に起動するかの切り替えと終了もあります。

## 仕組み

句読点の種類は `com.apple.inputmethod.Kotoeri` ドメインの `JIMPrefPunctuationTypeKey` に整数で入っています。値はシステム設定の並び順どおりで、0 が 。、、1 が 。，、2 が ．、、3 が ．， です。

切り替えるときは CFPreferences でこの値を書き、動いている標準日本語入力のプロセス（バンドル ID が `com.apple.inputmethod.Kotoeri.` で始まるもの）に SIGHUP を送ります。プロセスは終了し、次に日本語を入力した時点で起動し直して新しい値を読み込みます。設定はメニューを開いたときと2秒おきに読み直すので、システム設定で変えた場合も表示が追従します。

他アプリの設定を書き換えてシグナルを送るため、App Sandbox は使っていません。

## ビルド

最新の macOS と Xcode が必要です（開発時は macOS 27.2.1 と Xcode 27.2）。

```sh
open CommaSwitcher.xcodeproj
```

コマンドラインでは次のとおりです。

```sh
xcodebuild -project CommaSwitcher.xcodeproj -scheme CommaSwitcher -configuration Release -derivedDataPath build build
cp -R build/Build/Products/Release/CommaSwitcher.app /Applications/
xcodebuild -project CommaSwitcher.xcodeproj -scheme CommaSwitcher -derivedDataPath build test
```

ログイン時の起動は SMAppService で登録するため、/Applications に置いたアプリから有効にしてください。

## 配布について

いまは個人使用を前提に、ローカルの署名（Sign to Run Locally）でビルドしています。Hardened Runtime は有効にしてあり、バンドル ID は `io.github.kuridanho.CommaSwitcher` です。配布するときは、DEVELOPMENT_TEAM と Developer ID の署名を設定し、`xcrun notarytool` で公証してから GitHub Releases に置きます。
