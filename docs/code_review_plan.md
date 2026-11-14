# Comma Switcher コードレビュー計画書 (Code Review Plan)

## 1. 計画概要・背景・目的

### 1.1 対象リポジトリの概要
- **リポジトリ名**: `comma-switcher-app`
- **対象アプリケーション**: `Comma Switcher`（macOS メニューバー常駐ユーティリティ）
- **主要機能**:
  - macOS 標準日本語入力（旧ことえり / Kotoeri）における句読点設定（「。、」「。，」「．、」「．，」）をメニューバーからワンクリックで切り替え。
  - CoreText と AppKit を用いた、字形余白補正および角丸枠線付きメニューバーテンプレート画像の動的描画。
  - macOS システム設定（`com.apple.inputmethod.Kotoeri`）との双方向同期（2秒周期の軽量ポーリングおよびメニュー展開時同期）。
  - `ServiceManagement.SMAppService` によるログイン時の自動起動（Launch at Login）の管理。

### 1.2 技術スタックと実行環境の特性
| 項目 | 設定・仕様 | 備考・技術的背景 |
| :--- | :--- | :--- |
| **開発言語・バージョン** | Swift 6.0 (`SWIFT_VERSION = 6.0`) | Strict Concurrency Check 完全準拠 |
| **対象プラットフォーム** | macOS 26.0+ (`MACOSX_DEPLOYMENT_TARGET = 26.0`) | 最新 macOS API（SwiftUI, Swift Testing 等）を活用 |
| **UI アーキテクチャ** | SwiftUI `MenuBarExtra` (`.menuBarExtraStyle(.menu)`) | Dock アイコンを持たないメニューバー常駐型アプリ (`LSUIElement`) |
| **状態管理** | Observation Framework (`@Observable`), `@MainActor` | メインスレッド隔離による UI 状態の完全保護 |
| **プロセス間通信 (IPC)** | CoreFoundation `CFPreferences` + POSIX `kill(pid, SIGHUP)` | 他プロセス（Kotoeri）の設定変更とホットリロード |
| **描画サブシステム** | CoreText (`CTLine`), AppKit (`NSImage`, `NSBezierPath`) | CJK 句読点固有の字形余白を自動測定しインク幅で枠囲み生成 |
| **ログイン項目制御** | ServiceManagement (`SMAppService.mainApp`) | macOS 13+ 推奨の最新ログイン項目 API |
| **テストフレームワーク** | Swift Testing (`import Testing`) | Swift 6 標準の宣言的テストフレームワーク |
| **App Sandbox** | **無効 (`ENABLE_APP_SANDBOX = NO`)** | 他アプリ（Kotoeri）への設定書き込み・シグナル送信のため必然的に除外 |
| **コード署名・ランタイム** | Hardened Runtime 有効 (`ENABLE_HARDENED_RUNTIME = YES`) | アドホック署名（Sign to Run Locally）および将来の公証に対応 |

### 1.3 背景とコードレビューの目的
Comma Switcher は、約 420 行（Swift ソース 249 行、テスト 21 行、スクリプト 101 行、CI 16 行、README 33 行）という極めて軽量かつ焦点を絞った構成で美しい UI と実用的な利便性を実現しています。
しかしながら、本アプリケーションは以下の通り **macOS システムの深部・他プロセスと直接対話する極めてセンシティブな特性** を有しています：
1. **App Sandbox の非使用**: システム設計上サンドボックスを無効化して動作するため、万一の脆弱性や不正コードの混入がユーザー環境全体に影響を及ぼしうる。
2. **POSIX `kill(SIGHUP)` によるプロセス停止**: 動いている日本語入力システム（`com.apple.inputmethod.Kotoeri.*`）に対して外部からシグナルを送信して再起動を促すため、ユーザーの入力セッション保護（未確定文字列の喪失防止）やシグナル送信エラーの厳格な制御が不可欠である。
3. **CoreFoundation / CoreText の低層 API 呼び出し**: メモリ管理、クラッシュ耐性（強制アンラップの排除）、描画パフォーマンスの最適化が求められる。
4. **常駐プロセスとしてのリソース効率**: 2秒周期のタイマーや通知リスナーが稼働し続けるため、CPU ウェイクアップ、メモリリーク、省電力性に対する配慮が必要である。

本コードレビュー計画書は、**「全体的な品質（Quality）」「設計・アーキテクチャ（Architecture & Design）」「保守性（Maintainability）」「安全性・セキュリティ・信頼性（Security & Safety）」** の 4 観点から、具体的・定量的かつ再現可能な評価基準と検証手順を定義し、将来にわたる安全で堅牢な運用の基盤を確立することを目的とします。

---

## 2. レビュー推進体制・評価基準

### 2.1 評価重要度（Severity）の定義
レビュー指摘事項は、影響度およびリスクに応じて以下の 4 段階に分類します。

| 重要度 | 定義 | 判定例 | リリース / マージ方針 |
| :--- | :--- | :--- | :--- |
| **Blocker**<br>(致命的) | アプリケーションのクラッシュ、ユーザーの未確定入力文字列の消失、セキュリティ脆弱性、不当な特権行使、OS/他プロセスの破壊を招く欠陥。 | ・強制アンラップによる起動時・描画時クラッシュ<br>・無制限のプロセスへのシグナル誤送信<br>・悪意あるコードの混入やキーロガーAPIの利用 | **即時解消必須**<br>（未解決でのマージ・リリースは一切不可） |
| **Critical**<br>(重大) | 主要機能の動作不全、リソースリーク（メモリ・タイマー・通知トークン）、例外・エラーの不適切な握りつぶし、Swift 6 並行性違反。 | ・`NotificationCenter` トークンや `Timer` の永続リーク<br>・`SMAppService` 登録失敗時のサイレント破棄<br>・テスト環境でモック差し替え不能な過度な密結合 | **原則解消必須**<br>（未解決でのマージ不可） |
| **Major**<br>(主要) | パフォーマンス劣化、UI レスポンス低下、過度な同期 IPC 呼び出し、構造化ログ設計の不備、テスト網羅率不足。 | ・画像生成キャッシュの欠如による毎秒無駄な再描画<br>・レガシー `NSLog` の残存<br>・主要ドメインロジックの単体テスト不足（カバレッジ 80% 未満） | **スプリント内の対応を推奨**<br>（対応方針合意の上でマージ可） |
| **Minor**<br>(軽微) | コードスタイル、可読性、軽微な定数化、コメント表現の微修正、ドキュメントの補足。 | ・マジックナンバーの定数切り出し<br>・README の記載微調整<br>・Swift 構文の最新シュガーシンタックス適用 | **バックログ登録の上で順次対応可** |

### 2.2 合否判定基準（Pass / Fail 基準）
Pull Request の承認（Approve）およびマージには、以下の全条件を満たすことを必須とします。
1. **Blocker および Critical 指摘事項が 0 件** であること。
2. **Major 指摘事項について、修正が完了しているか、または次期イテレーションでの対応計画が合意されていること**。
3. **すべての自動テスト（Swift Testing）がパス** し、既存機能に対するリグレッションが一切発生していないこと。
4. **Swift 6 コンパイル警告（Warning）がゼロ** であること（`-warnings-as-errors` でのビルド成功）。
5. **静的解析・検証コマンドにおいて、セキュリティ違反（イベントタップ等の禁止 API 利用）が 0 件** であること。

---

## 3. 【評価観点 1】全体的な品質（Quality）

### レビューチェックリスト一覧

| ID | レビュー項目 | 対象ファイル・行番号 | 重要度 | 概要 |
| :--- | :--- | :--- | :--- | :--- |
| **Q-1** | 外部連携エラーハンドリングと伝播 | `CommaSwitcherApp.swift:59-66`<br>`LoginItem.swift:10-16`<br>`KotoeriPreferences.swift:26-37,40-47` | Critical | 外部 API（`SMAppService`, `CFPreferencesSynchronize`, `kill()`）の失敗検知、UI フィードバック、例外伝播の完全性。 |
| **Q-2** | 実行時クラッシュリスク（強制アンラップ）の排除 | `MenuBarLabel.swift:18-20` | Blocker | プロダクションコードにおける `!`（強制アンラップ）の完全排除と防御的フォールバック設計。 |
| **Q-3** | 画像描画パフォーマンスとキャッシュ効率 | `MenuBarLabel.swift:22-29,35-63`<br>`CommaSwitcherApp.swift:12` | Major | メニューバーアイコン用 `NSImage` の生成負荷、CoreText 解析キャッシュ、Retina / 外観追従の最適化。 |
| **Q-4** | アクセシビリティ（Accessibility）適合性 | `MenuBarLabel.swift:60-61`<br>`CommaSwitcherApp.swift:69-89` | Major | VoiceOver によるメニューバーおよび各メニュー項目の読み上げ品質、アクセシビリティ属性の検証。 |
| **Q-5** | 省電力性およびポーリング負荷の最適化 | `CommaSwitcherApp.swift:35-42` | Major | 2秒周期タイマー（tolerance 0.5s）の CPU ウェイクアップ・電力影響評価とイベント駆動への代替検討。 |

---

### 詳細レビュー仕様

#### Q-1: 外部連携エラーハンドリングと伝播
- **対象ファイル・行番号**:
  - `CommaSwitcher/CommaSwitcherApp.swift:59-66` (`toggleLaunchAtLogin`)
  - `CommaSwitcher/LoginItem.swift:10-16` (`setEnabled`)
  - `CommaSwitcher/KotoeriPreferences.swift:26-37` (`apply`), `40-47` (`restartInputMethods`)
- **具体的なレビュー項目**:
  1. `LoginItem.setEnabled` 呼び出し失敗時、`catch` ブロック内で単にログ出力（`NSLog`）して `launchAtLogin` を元に戻すだけでなく、ユーザーに対してなぜ登録に失敗したのか（例: `/Applications` 外からの実行、システム設定での管理者承認待ち `.requiresApproval`）を知らせる手立てがあるか。
  2. `CFPreferencesSynchronize` の戻り値（`Boolean`）が検証されているか。書き込み失敗時に設定の巻き戻しやエラー伝播が行われているか。
  3. `kill(app.processIdentifier, SIGHUP)` の実行結果（戻り値 `-1`、`errno`）が確認されているか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: 外部 API の成否が確実に検証され、失敗時にログ出力だけでなく、UI 整合性の保持および適切なエラーハンドリング（または呼び出し元への `throws` 伝播）が行われていること。
  - **Fail**: API 呼び出しの戻り値が破棄され、エラー発生時にもサイレントに処理が続行されている。
- **確認手順 / 検証方法**:
  1. `CommaSwitcherApp.swift`、`LoginItem.swift`、`KotoeriPreferences.swift` の実装を確認する。
  2. アプリを `/tmp` 等の一時フォルダで実行し、「ログイン時に起動」をトグルした際のエラー挙動を確認する。

#### Q-2: 実行時クラッシュリスク（強制アンラップ）の排除
- **対象ファイル・行番号**:
  - `CommaSwitcher/MenuBarLabel.swift:18-20` (`frameWidth`)
- **具体的なレビュー項目**:
  ```swift
  static let frameWidth: CGFloat = ceil(
      PunctuationStyle.allCases.map { inkWidth(of: glyphs(for: $0.label)) }.max()! + padding * 2
  )
  ```
  1. `PunctuationStyle.allCases.map { ... }.max()!` において、静的コレクションであるため現行は非空であるが、将来的な変更や防御的コーディングの観点から安全なアンラップ（`?? 0` 等）が施されているか。
  2. コードベース全体で、他に不要な `!` が存在しないか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: プロダクションコード内に未保護の強制アンラップ（Force Unwrap）が一切存在せず、常に安全なデフォルトフォールバックが定義されていること。
  - **Fail**: 空配列や予期せぬ入力に対して `Fatal error: Unexpectedly found nil while unwrapping an Optional value` でクラッシュする可能性が残存している。
- **確認手順 / 検証方法**:
  1. `grep -rnE "[a-zA-Z0-9_\)]\!" CommaSwitcher/` を実行し、該当箇所以外に強制アンラップが存在しないことを確認する。
  2. `MenuBarLabel.frameWidth` の定義を `?? 0` または安全な計算式に置き換えるレビュー指摘を行う。

#### Q-3: 画像描画パフォーマンスとキャッシュ効率
- **対象ファイル・行番号**:
  - `CommaSwitcher/MenuBarLabel.swift:22-29, 35-63` (`glyphs`, `image`)
  - `CommaSwitcher/CommaSwitcherApp.swift:12` (`Image(nsImage: ...)`)
- **具体的なレビュー項目**:
  1. 句読点スタイルは 4 通り（+ フォールバック「？」）に限られているにもかかわらず、状態変更やメニュー再評価のたびに `CoreText` の属性付き文字列生成、字形境界計算、`NSImage` の新規インスタンス化が行われていないか。
  2. メニューバー画像がメモリ上にキャッシュ（Dictionary や静的プロパティ）されているか。
  3. `image.isTemplate = true` により、外観モード（Light / Dark）やアクセントカラーの切り替え時に OS レベルで正しく再着色され、過剰な再生成が不要になっているか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: 頻繁な再描画イベント時にも同一画像の冗長な CoreText 解析・描画処理が抑制され、メモリと CPU リソースが節約されていること。
  - **Fail**: メインスレッド上でメニューバー再描画のたびに無駄な動的描画ブロックが実行されている。
- **確認手順 / 検証方法**:
  1. Xcode Instruments（Time Profiler / Allocations）をアタッチし、メニュー開閉時および設定変更時の CPU/メモリ割り当てプロファイルを測定する。

#### Q-4: アクセシビリティ（Accessibility）適合性
- **対象ファイル・行番号**:
  - `CommaSwitcher/MenuBarLabel.swift:60-61`
  - `CommaSwitcher/CommaSwitcherApp.swift:69-89` (`MenuContent`)
- **具体的なレビュー項目**:
  1. `image.accessibilityDescription` に句読点ラベル（例: `"。、"`）が正しくセットされ、VoiceOver がメニューバーアイコンの内容を正確に読み上げられるか。
  2. メニュー内の各 Toggle（「。、」「。，」等）および「ログイン時に起動」「Comma Switcher を終了」が VoiceOver フォーカスを受け取り、選択状態を正しくアナウンスできるか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: macOS の VoiceOver および Accessibility Inspector において、すべての要素が識別可能で、かつ適切な説明と操作状態がアナウンスされること。
  - **Fail**: 支援技術に対して「イメージ」とだけ読み上げられたり、トグルの選択状態が正しく通知されない。
- **確認手順 / 検証方法**:
  1. Accessibility Inspector（Xcode 付属）または VoiceOver（`Cmd + F5`）を起動し、メニューバー要素およびメニュー項目を順次フォーカスして読み上げ内容を検証する。

#### Q-5: 省電力性およびポーリング負荷の最適化
- **対象ファイル・行番号**:
  - `CommaSwitcher/CommaSwitcherApp.swift:35-42` (`init` 内の Timer)
- **具体的なレビュー項目**:
  1. 2秒周期タイマー（`timeInterval: 2`, `tolerance: 0.5`）がメインスレッド上で動作し、バックグラウンドでの不要な CPU ウェイクアップを引き起こしていないか。
  2. システム設定変更通知を受け取れない理由（`cfprefsd` が直接ファイル更新）の妥当性が維持されているか、または Darwin Notification や FSEvents によるイベント監視の実現可能性が調査されているか。
  3. タイマー動作時の差分チェック（`if current != style`）により、不要な SwiftUI レンダリングが確実に抑制されているか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: アイドル時の CPU 使用率が 0.0% に収束し、バッテリー消費プロファイルにおいて「低消費電力」が維持されていること。
  - **Fail**: タイマー実行によりメインスレッドのフレームドロップや過剰なエネルギー浪費が発生している。
- **確認手順 / 検証方法**:
  1. Instruments（Energy Log）を用いて、5分間のアイドル時電力消費を測定し、CPU ウェイクアップ頻度を確認する。

---

## 4. 【評価観点 2】設計・アーキテクチャ（Architecture & Design）

### レビューチェックリスト一覧

| ID | レビュー項目 | 対象ファイル・行番号 | 重要度 | 概要 |
| :--- | :--- | :--- | :--- | :--- |
| **A-1** | 責務分離と疎結合性（DIP / DI） | `CommaSwitcherApp.swift:18-67`<br>`KotoeriPreferences.swift:9-48`<br>`LoginItem.swift:5-17` | Critical | `MenuModel` が具象 static enum に直接依存せず、プロトコル抽象化によりテスト時にモック差し替え可能な設計になっているか。 |
| **A-2** | タイマーおよび通知リスナーのライフサイクル整合性 | `CommaSwitcherApp.swift:24-42` | Critical | `NotificationCenter` オブザーバートークンの保持・解除、および `Timer` の明示的な `invalidate()` の徹底。 |
| **A-3** | 外部プロセス制御と副作用の分離 | `KotoeriPreferences.swift:26-47` | Major | CFPreferences 永続化と SIGHUP プロセス停止の責務分離、プロセス抽出ロジックのカプセル化。 |
| **A-4** | ドメインモデルの型安全性と表現力 | `PunctuationStyle.swift:6-30` | Major | `PunctuationStyle` の Sendable, CaseIterable, rawValue の完全性および未知の値に対する耐障害性。 |

---

### 詳細レビュー仕様

#### A-1: 責務分離と疎結合性（DIP / DI）
- **対象ファイル・行番号**:
  - `CommaSwitcher/CommaSwitcherApp.swift:18-67` (`MenuModel`)
  - `CommaSwitcher/KotoeriPreferences.swift:9-48`
  - `CommaSwitcher/LoginItem.swift:5-17`
- **具体的なレビュー項目**:
  1. `MenuModel` が `KotoeriPreferences.current()` や `LoginItem.isEnabled` などの具象 static enum メソッドを直接呼び出しているため、依存関係逆転の原則（DIP）に反していないか。
  2. プロトコル（例: `PreferencesManaging`, `LoginItemManaging`）を導入し、`MenuModel` のイニシャライザで依存性注入（DI）を受け取れる構造になっているか。
  3. 単体テスト実行時に、実環境の macOS 設定を書き換えることなく `MenuModel` のロジックをテスト可能か。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: ViewModel 層と OS 依存層の間に抽象インターフェースが定義され、モックオブジェクトを用いた単体テストが容易に実装できる構造であること。
  - **Fail**: ViewModel と具象システムコールが強固に密結合しており、テスト実行時に実環境の Kotoeri プロセスが終了させられてしまう。
- **確認手順 / 検証方法**:
  1. `MenuModel` のコードを精査し、外部依存の差し替え可能性（Testability）を評価する。

#### A-2: タイマーおよび通知リスナーのライフサイクル整合性
- **対象ファイル・行番号**:
  - `CommaSwitcher/CommaSwitcherApp.swift:24-42` (`init`)
- **具体的なレビュー項目**:
  1. `NotificationCenter.default.addObserver(forName:object:queue:using:)` の戻り値（`NSObjectProtocol` トークン）がプロパティに保持されておらず、破棄時に `removeObserver` されていない問題の有無。
  2. `Timer` インスタンスがプロパティに保持されておらず、モデル破棄時に `invalidate()` できない状態になっていないか。
  3. Swift 6 の Concurrency モデルに基づき、非同期ループ（`for await _ in timerSequence` や `Task` + `ContinuousClock`）または明示的なクリーンアップ（`deinit`）への移行が検討されているか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: 登録したオブザーバーおよびタイマーがモデルのライフサイクルと厳密に連動し、モデル解放時に確実に破棄・登録解除される設計であること。
  - **Fail**: モデルが破棄された後も RunLoop や NotificationCenter にクロージャが残り続け、ゾンビ実行やメモリリークの原因となる。
- **確認手順 / 検証方法**:
  1. `MenuModel` を複数回初期化・破棄するテストコードを作成し、メモリグラフデバッガでリークを検出する。

#### A-3: 外部プロセス制御と副作用の分離
- **対象ファイル・行番号**:
  - `CommaSwitcher/KotoeriPreferences.swift:26-37` (`apply`), `39-47` (`restartInputMethods`)
- **具体的なレビュー項目**:
  1. `apply()` 内で `CFPreferencesSetValue`（永続化）と `restartInputMethods()`（プロセスシグナル送信）が不可分に同居しているため、単一責務の原則（SRP）に配慮して分離されているか。
  2. 対象プロセスの特定条件（`bundleIdentifier?.hasPrefix(inputMethodBundlePrefix)`）が安全にカプセル化されているか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: 設定値の保存処理とプロセス再起動処理が分離され、それぞれの処理が独立して検証および実行可能であること。
  - **Fail**: 副作用（シグナル送信）が暗黙的に発生し、テストやバッチ処理から分離できない。
- **確認手順 / 検証方法**:
  1. `KotoeriPreferences.swift` のメソッド構成と可視性をコード監査する。

#### A-4: ドメインモデルの型安全性と表現力
- **対象ファイル・行番号**:
  - `CommaSwitcher/PunctuationStyle.swift:6-30`
- **具体的なレビュー項目**:
  1. `enum PunctuationStyle: Int, CaseIterable, Identifiable, Sendable` のプロトコル適合が Swift 6 Concurrency に準拠しているか。
  2. システム設定の整数値（0〜3）と 1 対 1 に整合し、未知の整数に対するイニシャライザ（`PunctuationStyle(rawValue:)`）が安全に `nil` を返すか。
  3. `period`、`comma`、`label` の各プロパティが純粋関数的であり、副作用がないか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: ドメインモデルが完全に型安全であり、無効な状態を型システム上で排除できていること。
  - **Fail**: 未定義の rawValue を受け取った際に未定義動作や不正な文字列を生成する。
- **確認手順 / 検証方法**:
  1. `CommaSwitcherTests/PunctuationStyleTests.swift` のテスト実行結果を確認する。

---

## 5. 【評価観点 3】保守性（Maintainability）

### レビューチェックリスト一覧

| ID | レビュー項目 | 対象ファイル・行番号 | 重要度 | 概要 |
| :--- | :--- | :--- | :--- | :--- |
| **M-1** | 単体テスト網羅率（Coverage）向上 | `CommaSwitcherTests/`<br>全モジュール | Major | `MenuBarLabel`、`MenuModel` 等の未テスト領域に対するテスト追加と目標カバレッジ 80% 達成。 |
| **M-2** | ロギング・診断機能の近代化 | `CommaSwitcherApp.swift:63` | Major | レガシー `NSLog` の廃止、`os.Logger` 構造化ロギングの導入と適切なカテゴリ設計。 |
| **M-3** | CI/CD 自動化パイプラインの拡充 | `.github/workflows/ci.yml` | Major | Release ビルド成否、コードフォーマッタ（swift-format）、Linter（SwiftLint）の自動検証。 |
| **M-4** | コンパイラ警告ゼロ徹底・厳格並行性設定 | `CommaSwitcher.xcodeproj/project.pbxproj` | Major | Swift 6 Complete Concurrency 設定、`SWIFT_TREAT_WARNINGS_AS_ERRORS` の適用徹底。 |
| **M-5** | ドキュメントと実装の同期・保守 | `README.md`, 各ソースコメント | Minor | ビルド・配置手順（`/Applications`）や SIGHUP / CFPreferences 設計意図コメントの最新性維持。 |

---

### 詳細レビュー仕様

#### M-1: 単体テスト網羅率（Coverage）向上
- **対象ファイル・行番号**:
  - `CommaSwitcherTests/PunctuationStyleTests.swift:1-21`
  - 対象追加候補: `MenuBarLabelTests.swift`, `MenuModelTests.swift`
- **具体的なレビュー項目**:
  1. 現行テストが `PunctuationStyleTests`（3テストケース、21行）のみにとどまり、アプリ全体の主要ロジック（`MenuBarLabel` の寸法計算、`MenuModel` の状態遷移等）が未テストのまま放置されていないか。
  2. `MenuBarLabel.frameWidth`、`inkWidth`、フォントサイズ変更時の計算ロジックに対するユニットテストが存在するか。
  3. DI 導入後に `MenuModel` のモックテスト（外部設定変更時の反映、トグル切り替え）が実装されているか。
  4. 主要ロジックにおけるコードカバレッジが 80% 以上を維持しているか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: ロジックを持つ各コンポーネントに網羅的な単体テストが存在し、カバレッジが 80% 以上を達成していること。
  - **Fail**: ドメイン enum のみのテストにとどまり、計算ロジックや状態管理の回帰テストが自動化されていない。
- **確認手順 / 検証方法**:
  1. `xcodebuild -project CommaSwitcher.xcodeproj -scheme CommaSwitcher -enableCodeCoverage YES test` を実行し、カバレッジレポートを確認する。

#### M-2: ロギング・診断機能の近代化
- **対象ファイル・行番号**:
  - `CommaSwitcher/CommaSwitcherApp.swift:63` (`NSLog("ログイン項目の切り替えに失敗しました: \(error)")`)
- **具体的なレビュー項目**:
  1. レガシーな `NSLog` ではなく、Apple 推奨の Unified Logging System（`os.Logger(subsystem: "io.github.kuridanho.CommaSwitcher", category: "LoginItem")` 等）が採用されているか。
  2. 適切なログレベル（`.error`, `.info`, `.debug`）が指定され、プライバシー分類（`privacy: .public` / `.private`）が意識されているか。
  3. macOS の Console.app や `log stream` コマンドでサブシステム名による効率的なフィルタリングが可能か。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: すべてのログ出力が `os.Logger` を用いて構造化され、運用時の診断が容易に行えること。
  - **Fail**: レガシーな `NSLog` や `print` が散在し、ログレベルやカテゴリ分けが存在しない。
- **確認手順 / 検証方法**:
  1. `grep -rnE "(NSLog|print\()" CommaSwitcher/` を実行し、不適切なロギング箇所を特定する。
  2. Console.app において `subsystem:io.github.kuridanho.CommaSwitcher` でログを捕捉できるか確認する。

#### M-3: CI/CD 自動化パイプラインの拡充
- **対象ファイル・行番号**:
  - `.github/workflows/ci.yml:1-16`
- **具体的なレビュー項目**:
  1. 単なる Debug テスト実行だけでなく、配布用の Release ビルド（`configuration Release`）が成功することが CI 上で検証されているか。
  2. `swift format --lint` や `swiftlint` などの静的スタイル・品質検査ステップが組み込まれているか。
  3. macOS ランナー環境で Xcode バージョンが明示的に管理されているか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: PR 作成時に Debug テスト、Release ビルド、静的解析が自動実行され、品質ゲートとして機能していること。
  - **Fail**: CI ジョブが最小限のテストのみで、フォーマット違反や Release ビルドエラーを事前に検知できない。
- **確認手順 / 検証方法**:
  1. `.github/workflows/ci.yml` のワークフロー定義を精査し、追加ステップをレビュー提案する。

#### M-4: コンパイラ警告ゼロ徹底・厳格並行性設定
- **対象ファイル・行番号**:
  - `CommaSwitcher.xcodeproj/project.pbxproj`
- **具体的なレビュー項目**:
  1. `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` が設定され、コンパイル警告がリリースに混入しない仕組みになっているか。
  2. Swift 6 モードにおいて、Complete Concurrency チェックに関する警告が 0 件であるか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: ビルドログにおいてコンパイラ警告が一切出力されないこと。
  - **Fail**: 放置された警告が存在し、将来の言語バージョンアップでビルド破壊を引き起こす。
- **確認手順 / 検証方法**:
  1. `xcodebuild -project CommaSwitcher.xcodeproj -scheme CommaSwitcher build 2>&1 | grep -i "warning:"` を実行して検証する。

#### M-5: ドキュメントと実装の同期・保守
- **対象ファイル・行番号**:
  - `README.md:1-33`
  - 各 Swift ファイルのインラインドキュメント
- **具体的なレビュー項目**:
  1. README に記載されたビルドコマンド、配置要件（`/Applications` に配置しないと `SMAppService` が機能しない旨）が最新のコードと完全に一致しているか。
  2. SIGHUP IPC や CFPreferences 操作に関する特殊な設計意図が日本語コメントとして過不足なく明記されているか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: 新規参入した開発者が README の記載のみで迷いなく環境構築・ビルド・デバッグを行える状態であること。
  - **Fail**: 実装とドキュメントの記述に齟齬が存在する。
- **確認手順 / 検証方法**:
  1. README.md の手順に従い、クリーンな環境でビルドから動作確認までをトレースする。

---

## 6. 【評価観点 4】安全性・セキュリティ・信頼性（Security & Safety）

### レビューチェックリスト一覧

| カテゴリ | ID | レビュー項目 | 対象ファイル・行番号 | 重要度 | 概要 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **カテゴリ 1**<br>OS権限・境界 | **S-1** | App Sandbox 非使用の妥当性と攻撃面最小化 | `project.pbxproj:248,275`<br>`README.md:11` | Blocker | サンドボックス無効化の正当性検証とサードパーティ依存ゼロ方針の徹底。 |
| | **S-2** | Hardened Runtime と Developer ID 署名・公証準備 | `project.pbxproj:243,249,270,276` | Major | `ENABLE_HARDENED_RUNTIME = YES` の維持および公証時例外 Entitlements の最小化。 |
| | **S-3** | POSIX `kill(SIGHUP)` エラーハンドリングと安全性 | `KotoeriPreferences.swift:39-47` | Critical | シグナル送信結果検証、PID 検証（`!app.isTerminated`）、対象プロセスの厳格限定。 |
| | **S-4** | SMAppService 承認状態とログイン項目管理 | `LoginItem.swift:5-17`<br>`CommaSwitcherApp.swift:59-66` | Major | `.requiresApproval` 等のステータス網羅とシステム設定誘導 UX。 |
| **カテゴリ 2**<br>プライバシー | **S-5** | キー入力・キーストローク傍受の非介在性保証 (Zero Keylogging) | プロジェクト全体 | Blocker | 入力監視（`CGEventTap` 等）およびアクセシビリティ API の非使用保証。 |
| | **S-6** | CFPreferences スコープ局所化と権限逸脱防止 | `KotoeriPreferences.swift:10-37` | Critical | 設定書き換えを `JIMPrefPunctuationTypeKey`（0〜3）のみに厳格限定。 |
| | **S-7** | ログ出力における機密情報漏洩防止 | `CommaSwitcherApp.swift:63` | Major | ログへの個人情報・入力内容・システム機密情報の混入防止。 |
| **カテゴリ 3**<br>並行性・リソース | **S-8** | Swift 6 Concurrency と MainActor 隔離の完全性 | `CommaSwitcherApp.swift:18-67`<br>`PunctuationStyle.swift:6` | Critical | UI モデルのメインスレッド隔離と Sendable 適合性の保証。 |
| | **S-9** | NotificationCenter オブザーバートークン保持と解放 | `CommaSwitcherApp.swift:28-34` | Critical | メニュー追跡通知リスナーのトークン破棄防止と登録解除。 |
| | **S-10** | 2秒周期タイマーのライフサイクルとメインスレッド負荷 | `CommaSwitcherApp.swift:35-42` | Major | タイマーの明示的 `invalidate()` 保持と省電力性評価。 |
| | **S-11** | メニューバー画像生成のメモリ消費と描画キャッシュ | `MenuBarLabel.swift:35-63` | Major | CoreText オブジェクトの ARC メモリ管理と画像再利用性。 |
| **カテゴリ 4**<br>耐障害性 | **S-12** | POSIX / CF API の戻り値検証とエラー伝播 | `KotoeriPreferences.swift:16-37,40-47` | Critical | `CFPreferencesSynchronize` や `kill()` の失敗検知と復帰。 |
| | **S-13** | 未確定文字列入力中の SIGHUP 影響評価と対策 | `KotoeriPreferences.swift:40-47` | Blocker | 日本語変換中のシグナル送信による文字消失・IME 停止の評価と対策。 |
| | **S-14** | 強制アンラップ (`!`) の排除と堅牢性 | `MenuBarLabel.swift:18-20` | Blocker | 実行時クラッシュ要因のゼロ化とフォールバック保証。 |

---

### 詳細レビュー仕様

#### カテゴリ 1: OS権限・サンドボックス・プロセス境界

##### S-1: App Sandbox 非使用の妥当性と攻撃面最小化
- **対象ファイル・行番号**:
  - `CommaSwitcher.xcodeproj/project.pbxproj:248, 275` (`ENABLE_APP_SANDBOX = NO;`)
  - `README.md:11`
- **具体的なレビュー項目**:
  1. App Sandbox が無効化されている理由（他プロセス `com.apple.inputmethod.Kotoeri` の設定変更および SIGHUP 送信）が正当であり、現行 macOS のサンドボックス機構下で代替手段が存在しないことを確認する。
  2. サンドボックス外でフルユーザー権限で動作することに伴うセキュリティリスクを抑制するため、**外部パッケージ依存ゼロ（Pure Apple SDK）** の方針が厳格に守られているか。
  3. ネットワーク通信（`URLSession` 等）や任意のシェルコマンド実行（`Process` / `NSTask` 等）が一切含まれていないか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: サンドボックス非使用の必然性が説明され、攻撃対象領域（Attack Surface）が完全に最小化されていること。
  - **Fail**: 不要な外部ライブラリが導入されていたり、不要なネットワーク・プロセス実行 API が混入している。
- **確認手順 / 検証方法**:
  1. `grep -rnE "(URLSession|NWConnection|Process|NSTask|system\(|popen\()" CommaSwitcher/` を実行し、該当 API の不在を確認する。
  2. `project.pbxproj` 内に外部フレームワークや SPM パッケージの参照が存在しないことを確認する。

##### S-2: Hardened Runtime と将来の Developer ID 署名・公証準備
- **対象ファイル・行番号**:
  - `CommaSwitcher.xcodeproj/project.pbxproj:243, 249, 270, 276` (`ENABLE_HARDENED_RUNTIME = YES`, `CODE_SIGN_IDENTITY = "-"`)
- **具体的なレビュー項目**:
  1. `ENABLE_HARDENED_RUNTIME = YES` が Debug / Release 双方で設定されているか。
  2. 将来 Developer ID で署名して Apple 公証（Notarization）を通す際、過剰な例外 Entitlements（`com.apple.security.cs.allow-jit`、`disable-library-validation` 等）を付与しない計画になっているか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: Hardened Runtime が有効化されており、公証要件を満たすクリーンな署名構成が維持されていること。
  - **Fail**: Hardened Runtime が無効化されている、または過剰な権限緩和 Entitlements が含まれている。
- **確認手順 / 検証方法**:
  1. `project.pbxproj` の署名設定を確認する。
  2. 配布用ビルドにおいて `xcrun codesign -dv --entitlements - CommaSwitcher.app` を実行し、Hardened Runtime フラグの付与を確認する。

##### S-3: POSIX `kill(pid, SIGHUP)` によるプロセス終了の安全性とエラーハンドリング
- **対象ファイル・行番号**:
  - `CommaSwitcher/KotoeriPreferences.swift:39-47` (`restartInputMethods`)
- **具体的なレビュー項目**:
  1. `kill(app.processIdentifier, SIGHUP)` の戻り値を検査し、シグナル送信失敗（戻り値 `-1`）時に `errno`（`EPERM`, `ESRCH` 等）をチェックしてログまたは通知を行っているか。
  2. シグナル送信直前に `app.isTerminated == false` を確認し、プロセス終了直後の PID 再利用による他プロセスへの誤爆（Signal Confusion）を防いでいるか。
  3. 対象プロセスの特定条件（`$0.bundleIdentifier?.hasPrefix("com.apple.inputmethod.Kotoeri.") == true`）が厳密であり、サードパーティ製 IME（ATOK、Google 日本語入力等）を誤って終了させないか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: シグナル送信の成否が検証され、対象 PID の健全性チェックおよび対象バンドル ID の厳格なフィルタリングが行われていること。
  - **Fail**: `kill()` の結果が破棄され、既に終了したプロセスや無関係なプロセスへシグナルを送るリスクがある。
- **確認手順 / 検証方法**:
  1. `KotoeriPreferences.swift` の `restartInputMethods()` 実装を精査する。
  2. システム上に Kotoeri プロセスが存在しない状況（または他社 IME 利用環境）で例外が発生しないか確認する。

##### S-4: SMAppService によるログイン項目管理と権限状態ハンドリング
- **対象ファイル・行番号**:
  - `CommaSwitcher/LoginItem.swift:5-17`
  - `CommaSwitcher/CommaSwitcherApp.swift:59-66`
- **具体的なレビュー項目**:
  1. `SMAppService.mainApp.status` に存在する `.requiresApproval`（システム設定でのユーザー承認待ち）や `.notFound`（アプリパスが不正）の状態が適切にハンドリングされているか。
  2. 登録失敗時に `SMAppService.openSystemSettingsLoginItems()` への誘導などの親切な UX が提供されているか。
  3. アプリが `/Applications` 外で実行されている場合に、登録失敗となる仕様がユーザーに明示されているか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: ログイン項目の各状態が網羅され、ユーザーのシステム設定状況に応じた適切なガイダンスが提供されていること。
  - **Fail**: 失敗時に単にトグルが元に戻るだけで、ユーザーが原因を把握できない。
- **確認手順 / 検証方法**:
  1. macOS システム設定の「ログイン項目」でアプリを不許可にした状態でトグル操作を行い、挙動を検証する。

---

#### カテゴリ 2: プライバシー・データ保護

##### S-5: キー入力・キーストローク傍受の非介在性検証 (Zero Keylogging)
- **対象ファイル・行番号**:
  - プロジェクト全体（全 Swift ソース）
- **具体的なレビュー項目**:
  1. 句読点切り替え機能において、キーストロークの監視・傍受・キャプチャ（`CGEventTapCreate`, `NSEvent.addGlobalMonitorForEventsMatchingMask`, `IOHIDManager`, Accessibility API）が一切行われていないこと。
  2. 入力監視権限（Input Monitoring）やアクセシビリティ権限（Accessibility）を OS に要求しないアーキテクチャが厳格に遵守されていること。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: キーロガーに類する API がプロジェクト内に 1 行も存在せず、OS からの権限要求ダイアログも一切発生しないこと。
  - **Fail**: 入力イベントを直接監視・操作する API が含まれている。
- **確認手順 / 検証方法**:
  1. `grep -rnE "(CGEventTap|addGlobalMonitorForEvents|IOHID|AXUIElement|AXIsProcessTrusted)" CommaSwitcher/` を実行し、完全一致 0 件であることを確認する。
  2. 初回起動時にプライバシー権限ダイアログが表示されないことを確認する。

##### S-6: CFPreferences 設定変更スコープの局所化と権限逸脱防止
- **対象ファイル・行番号**:
  - `CommaSwitcher/KotoeriPreferences.swift:10-37`
- **具体的なレビュー項目**:
  1. 設定変更対象が `com.apple.inputmethod.Kotoeri` ドメインのキー `JIMPrefPunctuationTypeKey` のみに厳格に限定されているか。
  2. 他の日本語入力設定（入力モード、推測候補、変換学習データ等）を破壊・上書きするリスクがないか。
  3. 書き込む値が `PunctuationStyle` の `rawValue`（0〜3）に制限されており、不正な数値やオブジェクトが書き込まれないか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: 書き込み対象ドメイン、キー、値の型が最小限に局所化され、他設定に一切影響を与えないこと。
  - **Fail**: ドメイン全体の上書きや、不正な型・値の書き込みが行われる。
- **確認手順 / 検証方法**:
  1. `KotoeriPreferences.apply` の引数と設定値をコード精査する。
  2. 変更後に `defaults read com.apple.inputmethod.Kotoeri` を実行し、該当キー以外の plist 構造が変化していないことを検証する。

##### S-7: ログ出力における機密情報漏洩防止
- **対象ファイル・行番号**:
  - `CommaSwitcher/CommaSwitcherApp.swift:63`
- **具体的なレビュー項目**:
  1. ログ出力内容に、ユーザーの入力文字列、ファイルパス、個人識別情報が含まれていないか。
  2. 将来 `os.Logger` を導入した際にも、プライバシーマスク（`privacy: .public` / `.private`）が適切に適用されているか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: ログ出力がシステム運用に必要なエラー情報のみに限定され、ユーザー機密が漏洩しないこと。
  - **Fail**: 個人情報や入力セッション情報がログに平文で出力される。
- **確認手順 / 検証方法**:
  1. ソースコード内のすべてのログ出力文を監査する。

---

#### カテゴリ 3: 並行処理・スレッド安全性・リソース管理

##### S-8: Swift 6 Concurrency と MainActor 隔離の完全性
- **対象ファイル・行番号**:
  - `CommaSwitcher/CommaSwitcherApp.swift:18-67` (`MenuModel`)
  - `CommaSwitcher/PunctuationStyle.swift:6` (`Sendable`)
- **具体的なレビュー項目**:
  1. `MenuModel` が `@MainActor` に隔離され、UI 状態の更新が常にメインスレッドで行われることが保証されているか。
  2. NotificationCenter コールバックおよび Timer コールバック内で `MainActor.assumeIsolated` が使用されているが、これが安全にメインスレッド上で動作することが自明であるか（NotificationCenter の `queue: .main` 指定、Timer の `RunLoop.main` 登録）。
  3. `PunctuationStyle` が `Sendable` に適合し、スレッド境界を越えて安全に渡せるか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: Swift 6 の Strict Concurrency チェックにおいて警告・エラーがゼロであり、スレッドセーフティが言語レベルで証明されていること。
  - **Fail**: データ競合（Data Race）の可能性や未保護のスレッド横断アクセスが存在する。
- **確認手順 / 検証方法**:
  1. Xcode ビルドにおいて Swift 6 モードでのコンパイルログを確認する。

##### S-9: NotificationCenter オブザーバートークンの保持と解除
- **対象ファイル・行番号**:
  - `CommaSwitcher/CommaSwitcherApp.swift:28-34` (`init`)
- **具体的なレビュー項目**:
  1. `NotificationCenter.default.addObserver` の戻り値トークンが破棄されているため、モデル破棄時にオブザーバーが解除されずに残存するメモリリーク・多重登録リスクがないか。
  2. `MenuModel` のプロパティにトークンを保持し、`deinit` で `NotificationCenter.default.removeObserver(token)` を呼び出す改修を行う。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: 登録した通知オブザーバーが確実に追跡され、不要時に解除される設計であること。
  - **Fail**: 通知オブザーバートークンが捨てられ、解除不能なブロックが登録されたままになる。
- **確認手順 / 検証方法**:
  1. `CommaSwitcherApp.swift` のコードレビューにおいて、トークン保持と解放の必要性を指摘する。

##### S-10: 2秒周期タイマーのライフサイクルとメインスレッド負荷
- **対象ファイル・行番号**:
  - `CommaSwitcher/CommaSwitcherApp.swift:35-42`
- **具体的なレビュー項目**:
  1. `Timer` がローカル変数に代入されたのみでプロパティに保持されておらず、明示的な `invalidate()` が行えない問題。
  2. 弱参照 `[weak self]` により自己参照リークは回避されているものの、モデル破棄後も RunLoop 上で 2 秒ごとに空ループが回り続ける無駄なリソース消費がないか。
  3. タイマーインスタンスをプロパティ化し、`deinit` で確実に停止させる設計への改善。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: タイマーが適切に管理され、不要になった時点で直ちに RunLoop から登録解除されること。
  - **Fail**: 未保持のタイマーが永続的に RunLoop をウェイクアップし続ける。
- **確認手順 / 検証方法**:
  1. Instruments（Time Profiler / Leaks）でモデルの初期化・破棄サイクルにおけるタイマーの残存状況を確認する。

##### S-11: メニューバー画像生成のメモリ消費と描画キャッシュ
- **対象ファイル・行番号**:
  - `CommaSwitcher/MenuBarLabel.swift:35-63` (`image`)
- **具体的なレビュー項目**:
  1. `NSImage(size:flipped:drawingHandler:)` で生成される画像内部の `CTLine`、`NSBezierPath`、CoreGraphics コンテキストが ARC によりリークなく解放されているか。
  2. 4 種類の句読点画像をオンデマンドで毎回生成するのではなく、辞書等でキャッシュしてメモリ再利用を図る設計への移行余地があるか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: 描画処理において CoreText / AppKit オブジェクトのリークがなく、メモリフットプリントが安定（数MB以下）していること。
  - **Fail**: アイコンの再描画を繰り返すごとにメモリ割り当てが増加し続ける。
- **確認手順 / 検証方法**:
  1. Instruments（Allocations / Leaks）を実行し、メニューバー切り替えを 100 回繰り返した際のメモリ推移を計測する。

---

#### カテゴリ 4: エラーハンドリング・耐障害性

##### S-12: POSIX APIおよびCoreFoundation APIの戻り値検証とエラー伝播
- **対象ファイル・行番号**:
  - `CommaSwitcher/KotoeriPreferences.swift:16-37` (`apply`), `40-47` (`restartInputMethods`)
- **具体的なレビュー項目**:
  1. `CFPreferencesSynchronize` の成否（戻り値）をチェックし、同期失敗時にエラーログまたは例外を発生させているか。
  2. `kill()` の実行失敗時に `errno` に応じた適切な回復措置または診断ログが出力されるか。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: 低層 API の成否が確実に検証され、失敗時に上位層へ適切に伝播されること。
  - **Fail**: 低層 API の失敗を完全に無視して処理が正常終了したかのように振る舞う。
- **確認手順 / 検証方法**:
  1. `KotoeriPreferences.swift` の戻り値ハンドリングをコード監査する。

##### S-13: 未確定文字列入力中の SIGHUP シグナル送信による影響と対策
- **対象ファイル・行番号**:
  - `CommaSwitcher/KotoeriPreferences.swift:40-47` (`restartInputMethods`)
- **具体的なレビュー項目**:
  1. ユーザーが別アプリ（テキストエディタ、ブラウザ等）で日本語のインライン変換中（未確定文字列が存在する状態）に Comma Switcher で句読点を切り替えた場合、Kotoeri プロセスが SIGHUP で即死することにより、入力途中の文字列が消失したりエディタが一時フリーズするリスクの検証。
  2. このリスクに対する実機挙動の検証および、ドキュメント・UI 上での注意事項の記載。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: 未確定文字列入力中の挙動が実機で検証され、入力喪失やハングアップが発生しないこと、または明確な注意喚起が行われていること。
  - **Fail**: 切り替え操作によってユーザーの入力データが消失し、かつその挙動が認識・文書化されていない。
- **確認手順 / 検証方法**:
  1. テキストエディタ（TextEdit等）で日本語入力中に「とうきょう（未確定）」の状態で Comma Switcher からスタイルを切り替え、テキストが確定されるか破棄されるか実機検証する。

##### S-14: 強制アンラップ (`!`) の排除と堅牢性
- **対象ファイル・行番号**:
  - `CommaSwitcher/MenuBarLabel.swift:18-20`
- **具体的なレビュー項目**:
  1. `MenuBarLabel.frameWidth` の `.max()!` を安全なフォールバック（`?? 0` 等）へ置き換える。
  2. 今後追加されるコードにおいても強制アンラップを一切禁止するルール（SwiftLint の `force_unwrapping` 有効化）を導入する。
- **評価基準（Pass / Fail 判定基準）**:
  - **Pass**: コードベース内に強制アンラップが 0 件であり、予期せぬ実行時例外が発生しないこと。
  - **Fail**: 強制アンラップが残存している。
- **確認手順 / 検証方法**:
  1. `grep -rnE "[a-zA-Z0-9_\)]\!" CommaSwitcher/` の検索結果が 0 件であることを確認する。

---

## 7. レビュー実施手順および検証方法

レビュー担当者は、以下の 3 段階の手順に沿ってコードレビューおよび動作検証を実施します。

### 7.1 静的コード解析手順（Static Analysis Procedures）

ターミナルにて以下のコマンドを順次実行し、潜在的な欠陥・規約違反を機械的に検証します。

```bash
# 1. 不正な入力監視・イベントタップ・アクセシビリティ API の非使用検証 (Zero Keylogging)
grep -rnE "(CGEventTap|addGlobalMonitorForEvents|IOHID|AXUIElement|AXIsProcessTrusted)" CommaSwitcher/
# 【期待値】: ヒット 0 件 (何も出力されないこと)

# 2. 外部ネットワーク通信・シェルコマンド実行 API の非使用検証
grep -rnE "(URLSession|NWConnection|Process|NSTask|system\(|popen\()" CommaSwitcher/
# 【期待値】: ヒット 0 件 (何も出力されないこと)

# 3. 強制アンラップ (!) の使用箇所検索
grep -rnE "[a-zA-Z0-9_\)]\!" CommaSwitcher/
# 【期待値】: MenuBarLabel.swift:19 のみ (修正後は 0 件)

# 4. レガシーロギング (NSLog / print) の使用箇所検索
grep -rnE "(NSLog|print\()" CommaSwitcher/
# 【期待値】: CommaSwitcherApp.swift:63 のみ (os.Logger 移行後は 0 件)

# 5. App Sandbox および Hardened Runtime 設定の確認
grep -E "(ENABLE_APP_SANDBOX|ENABLE_HARDENED_RUNTIME|CODE_SIGN_IDENTITY)" CommaSwitcher.xcodeproj/project.pbxproj
# 【期待値】:
# ENABLE_APP_SANDBOX = NO;
# ENABLE_HARDENED_RUNTIME = YES;
# CODE_SIGN_IDENTITY = "-";
```

### 7.2 ビルドおよび単体テスト実行手順（Build & Test Procedures）

以下のコマンドにより、コンパイル、静的警告、テストスイートの成否を検証します。

```bash
# 1. Debug ビルドおよび単体テストの実行 (Swift Testing)
xcodebuild -project CommaSwitcher.xcodeproj -scheme CommaSwitcher -derivedDataPath build test
# 【期待値】: ** TEST SUCCEEDED ** (全 3 テストケース成功)

# 2. Release 構成でのビルド検証
xcodebuild -project CommaSwitcher.xcodeproj -scheme CommaSwitcher -configuration Release -derivedDataPath build build
# 【期待値】: ** BUILD SUCCEEDED **

# 3. コンパイル警告 (Warning) の検出
xcodebuild -project CommaSwitcher.xcodeproj -scheme CommaSwitcher build 2>&1 | grep -i "warning:"
# 【期待値】: 警告 0 件 (または ad-hoc 署名に関する note のみ)

# 4. カバレッジ情報の収集付きテスト実行
xcodebuild -project CommaSwitcher.xcodeproj -scheme CommaSwitcher -enableCodeCoverage YES -derivedDataPath build test
```

### 7.3 実機動作確認手順（Manual / GUI Verification Procedures）

実機（macOS 26.0+）において、以下の操作フローを実施し、正常動作および安全性を確認します。

1. **基本起動とメニューバー表示確認**:
   - アプリを起動し、メニューバーに現在の句読点（例: 角丸枠付きの「。、」）が鮮明に表示されることを確認する。
   - ダークモードとライトモードを切り替え、メニューバーアイコンの色が自動追従することを確認する。
2. **句読点切り替え機能の動作確認**:
   - メニューを開き、「。，」を選択する。
   - メニューバーの表示が即座に「。，」に切り替わることを確認する。
   - テキストエディタ等で日本語を入力し、句読点キーを押下した際に「。，」が入力されることを確認する。
   - 順次「．、」「．，」についても同様に切り替え確認を行う。
3. **macOS システム設定との双方向同期確認**:
   - 「システム設定 > キーボード > 日本語入力ソース」を開き、句読点設定を手動で変更する。
   - メニューバーを開かずに待機し、最大 2.5 秒以内にメニューバーのアイコンが変更後の句読点に追従することを確認する。
4. **ログイン時自動起動の動作確認**:
   - `/Applications` に配置した状態で「ログイン時に起動」のトグルを ON / OFF し、エラーなく切り替わることを確認する。
   - 「システム設定 > 一般 > ログイン項目と機能拡張」に Comma Switcher が登録・解除されることを確認する。
5. **未確定文字列入力時の耐障害性確認**:
   - テキストエディタ上で日本語を未確定（変換前）の状態で入力したまま、Comma Switcher で句読点スタイルを切り替える。
   - アプリがクラッシュしたり、システム入力がフリーズしないことを確認する。
6. **VoiceOver アクセシビリティ確認**:
   - `Cmd + F5` で VoiceOver を起動し、メニューバー要素をフォーカスして「。、、イメージ」等と正確にアナウンスされることを確認する。

---

## 8. レビュー後の改善推奨アクション・ロードマップ

本コードレビュー計画の実施後、検出された課題を計画的に是正するための改善ロードマップを提案します。

```
[Phase 1: 即時是正 (v1.0.1)] ───► [Phase 2: 堅牢化・保守性 (v1.1.0)] ───► [Phase 3: 配布・公証 (v1.2.0)]
  ・強制アンラップ排除 (Q-2)        ・プロトコル抽出と DI (A-1)         ・Developer ID 署名・公証 (S-2)
  ・os.Logger への移行 (M-2)        ・テストスイート拡充 (M-1)           ・画像描画キャッシュ (Q-3)
  ・ライフサイクル修正 (A-2)        ・CI パイプライン強化 (M-3)         ・SMAppService 誘導 UX (S-4)
  ・kill / CF 検証 (Q-1, S-3)       ・警告ゼロの厳格化 (M-4)           ・省電力イベント駆動検討 (Q-5)
```

### Phase 1: 即時是正（Immediate Remediation / v1.0.1）— 目標: 安定性と基本エラー処理の担保
- [ ] **強制アンラップの完全排除**: `MenuBarLabel.frameWidth` の `.max()!` を `?? 0` に改修 (Q-2, S-14)。
- [ ] **Unified Logging (`os.Logger`) への刷新**: レガシー `NSLog` を廃止し、サブシステム `io.github.kuridanho.CommaSwitcher` を持つ構造化ログを導入 (M-2, S-7)。
- [ ] **リソースライフサイクルの修正**: `MenuModel` における `NotificationCenter` オブザーバートークンの保持・解除、および `Timer` の保持・`invalidate()` を実装 (A-2, S-9, S-10)。
- [ ] **低層 API 戻り値のチェック**: `CFPreferencesSynchronize` の戻り値検証、および `kill()` の結果・`errno` 検証を追加 (Q-1, S-3, S-12)。

### Phase 2: 堅牢化・テスタビリティ向上（Hardening & Maintainability / v1.1.0）— 目標: テスト自動化と保守性確立
- [ ] **プロトコル抽象化と DI の導入**: `PreferencesManaging`、`LoginItemManaging` プロトコルを定義し、`MenuModel` の外部依存を注入可能にする (A-1)。
- [ ] **単体テストスイートの大幅拡充**: `MenuBarLabel`（寸法計算・字形幅）、`MenuModel`（状態同期・切り替えロジック）のテストを追加し、テスト網羅率 80% 以上を達成 (M-1)。
- [ ] **CI パイプラインの強化**: `.github/workflows/ci.yml` に Release ビルド検証、`swift-format` チェック、Warning 検知を追加 (M-3, M-4)。
- [ ] **`SWIFT_TREAT_WARNINGS_AS_ERRORS` の有効化**: コンパイラ警告ゼロを CI で強制 (M-4)。

### Phase 3: 配布準備と高度な最適化（Distribution & Optimization / v1.2.0）— 目標: 一般配布と UX 極大化
- [ ] **Developer ID 署名および `notarytool` 公証ワークフローの構築**: 配布用ワークフローの自動化 (S-2)。
- [ ] **画像描画キャッシュの導入**: 4 通りの句読点画像をメモリキャッシュし、不要な CoreText 解析を完全抑制 (Q-3, S-11)。
- [ ] **ログイン項目 UX の洗練**: `SMAppService.status == .requiresApproval` 時のシステム設定誘導ダイアログを実装 (Q-1, S-4)。
- [ ] **省電力性の更なる探求**: 定期ポーリング以外のイベント駆動通知（DistributedNotification 等）の実現性を Apple の内部仕様調査とともに継続検討 (Q-5)。
