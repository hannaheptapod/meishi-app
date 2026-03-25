# CLAUDE.md — 名刺管理アプリ（Meishi）

## プロジェクト概要

iPhoneで使える名刺管理アプリ。カメラ撮影・OCR読み取り・手動入力で名刺をデジタル管理し、
iPhoneの連絡先との連携やCSV/vCard出力に対応する。

---

## 技術スタック

| 項目 | 採用技術 |
|---|---|
| UI フレームワーク | SwiftUI |
| データ永続化 | CoreData（端末内のみ・オフライン完結） |
| OCR（文字認識） | Vision Framework（VNRecognizeTextRequest） |
| 意味分析 Tier 1 | Apple Foundation Models（FoundationModels framework） |
| 意味分析 Tier 2 | Qwen2.5-0.5B-Instruct CoreML（LocalLLMService / オプションダウンロード） |
| 意味分析 Tier 3 | 正規表現ベース分類（CardFieldClassifier・常時利用可能） |
| BPEトークナイザー | Qwen25Tokenizer（HuggingFace tokenizer.json を解析） |
| カメラ | AVFoundation |
| 連絡先連携 | CNContactStore（Contacts framework） |
| エクスポート | CSV・vCard（.vcf） |
| 設定永続化 | UserDefaults（SettingsStore） |
| バージョン管理 | Git / GitHub |

クラウド同期・外部APIへの通信は一切行わない。すべての処理を端末内で完結させる。
（モデルのダウンロードのみ初回のみ HuggingFace から取得する。）

### AI処理の3層構成

OCRと意味分析は役割が異なるフレームワークで分担する。

**層1 — OCR（Vision Framework）**
- `VNRecognizeTextRequest` で名刺画像からテキストを抽出する
- `.accurate` モードを使用し、`usesLanguageCorrection = true` を設定する
- `recognitionLanguages = ["ja-JP", "en-US"]` で日本語・英語に対応
- 出力：テキスト行の配列（`[String]`）

**層2 — 意味分析（3段階カスケード）**

ユーザーが `SettingsView` で読み取り方法を選択できる。

```
Tier 1: Apple Intelligence（iOS 18+ / iPhone 15 Pro以降）
         ↓ 利用不可 or 失敗
Tier 2: Qwen2.5-0.5B CoreML（LocalLLMService / ~275MB ダウンロード必須）
         ↓ 未ダウンロード or 失敗
Tier 3: CardFieldClassifier（正規表現・常時利用可能）
```

- **automatic**（デフォルト）：上記の順に自動で試みる
- **appleIntelligence**：Apple Intelligence のみ使用（利用不可時はエラー）
- **localLLM**：Qwen モデルのみ使用（未ダウンロード時はエラー）
- **classifier**：正規表現のみ使用

**Apple Intelligence（Tier 1）**
- `@Generable` マクロで定義した `ParsedCard` 型を使い、型安全な出力を得る
- `import FoundationModels` が必要。FoundationModels framework をリンクしてから有効化
- **現状：** FoundationModels framework 未リンクのためコメントアウト中。常に Tier 2/3 にフォールバック

```swift
@Generable
struct ParsedCard {
    @Guide("姓（ファミリーネーム）")  var lastName: String
    @Guide("名（ファーストネーム）")  var firstName: String
    @Guide("会社名")                  var company: String
    @Guide("役職")                    var title: String
    @Guide("電話番号")                var phone: String
    @Guide("メールアドレス")          var email: String
    @Guide("住所")                    var address: String
    @Guide("WebサイトURL")            var website: String
}
```

**Qwen2.5 CoreML（Tier 2）**
- モデル：`finnvoorhees/coreml-Qwen2.5-0.5B-Instruct-4bit`（HuggingFace）
- トークナイザー：`Qwen/Qwen2.5-0.5B-Instruct`（HuggingFace）
- 合計約 275MB。`LocalLLMService` がアプリ内 ApplicationSupport に保存・管理する
- ChatML 形式でプロンプトを構築し、JSON 出力をパースしてフィールドに変換
- iOS 18 以降：`MLState` による stateful KV キャッシュでトークン生成を高速化
- プリフィル（全入力トークン一括処理）→デコード（1トークンずつ生成）の2フェーズ推論
- `imEnd` トークン（151645）か最大 256 トークンで生成を停止

**CardFieldClassifier（Tier 3）**
- 2パス方式：
  - パス1：メール・電話・URL・住所・会社名・役職をキーワード／正規表現で抽出
  - パス2：未分類の残り行から氏名を推定し、スペース（全角・半角）で姓・名に分割

---

## ディレクトリ構成

```
Meishi/
├── CLAUDE.md                  # このファイル
├── Meishi/
│   ├── App/
│   │   ├── MeishiApp.swift
│   │   └── PersistenceController.swift      # CoreData スタック管理
│   ├── Models/
│   │   ├── BusinessCard+CoreDataClass.swift
│   │   └── BusinessCard+CoreDataProperties.swift
│   ├── Views/
│   │   ├── CardListView.swift
│   │   ├── CardDetailView.swift
│   │   ├── CardFormView.swift
│   │   ├── CameraView.swift
│   │   ├── DuplicateListView.swift          # 重複候補一覧
│   │   ├── DuplicateMergeView.swift         # マージUI
│   │   ├── SettingsView.swift               # 設定画面（読み取り方法・エクスポート設定等）
│   │   └── ContentView.swift
│   ├── ViewModels/
│   │   ├── CardListViewModel.swift
│   │   ├── CardFormViewModel.swift
│   │   └── SettingsStore.swift              # UserDefaults ラッパー・ReadingMethod enum
│   ├── Services/
│   │   ├── OCRService.swift
│   │   ├── ContactsService.swift
│   │   ├── ExportService.swift
│   │   ├── LocalLLMService.swift            # Qwen2.5 CoreML 推論・モデル管理
│   │   └── Qwen25Tokenizer.swift            # BPE トークナイザー
│   ├── Utilities/
│   │   ├── DuplicateChecker.swift
│   │   └── CardFieldClassifier.swift
│   └── Resources/
│       └── BusinessCard.xcdatamodeld
├── MeishiTests/
│   └── MeishiTests.swift
└── MeishiUITests/
    ├── MeishiUITests.swift
    └── MeishiUITestsLaunchTests.swift
```

---

## CoreData スキーマ

エンティティ名：`BusinessCard`

| 属性名 | 型 | 備考 |
|---|---|---|
| id | UUID | 主キー |
| lastName | String | 姓 |
| firstName | String | 名 |
| company | String | 会社名 |
| title | String | 役職 |
| email | String | メールアドレス |
| phone | String | 電話番号 |
| address | String | 住所 |
| website | String | WebサイトURL |
| notes | String | メモ |
| imageData | Binary Data | 名刺写真（任意保存） |
| createdAt | Date | 登録日時 |
| updatedAt | Date | 更新日時 |

---

## 開発フェーズ

### フェーズ 1（MVP）— 基本CRUD ✅ 実装完了
- 名刺一覧画面（CardListView）
- 名刺詳細画面（CardDetailView）
- 手動入力フォーム（CardFormView）
- CoreData による保存・編集・削除

### フェーズ 2 — カメラ + OCR + AI意味分析 ✅ 実装完了
- AVFoundation でカメラ起動（CameraView）
- Vision Framework で文字認識（OCRService）
- Foundation Models で生テキストを `ParsedCard` 型に構造化（CardFormViewModel）
- Foundation Models 利用不可の場合は CardFieldClassifier（正規表現）でフォールバック
- 認識後フォームで内容を確認・修正してから保存

### フェーズ 3 — 連絡先連携 ✅ 実装完了
- iPhoneの連絡先へのエクスポート（CNContactStore）
- iPhoneの連絡先からのインポート（ContactsService に実装済み・UI未公開）
- CSV・vCard（.vcf）エクスポート（ExportService）

### フェーズ 4 — 重複チェック・名寄せ ✅ 実装完了
- 名前・会社名の類似度判定（Levenshtein距離）
- 重複候補の提示UI
- マージ機能

### フェーズ 5 — Qwen2.5 CoreML 推論・設定画面 ✅ 実装完了
- Qwen2.5-0.5B-Instruct（4bit量子化 CoreML）によるオンデバイス推論（LocalLLMService）
- HuggingFace BPE トークナイザー（Qwen25Tokenizer）
- stateful KV キャッシュによる高速デコード（iOS 18+・MLState）
- 読み取り方法の選択UI（SettingsView）：automatic / Apple Intelligence / LocalLLM / Classifier
- 設定の永続化（SettingsStore / UserDefaults）
- モデルのダウンロード・削除・進捗表示（SettingsView）

---

## ブランチ命名規則

- 機能ベースで命名する：`feature/<機能名>`
- 例：`feature/basic-crud`、`feature/camera-ocr`、`feature/contacts-export`、`feature/duplicate-check`、`feature/qwen-inference`
- フェーズ完了後は main にマージしてから次のブランチを切る
- **main への直接 push は絶対禁止。** 必ず feature ブランチを切り、PR を通してマージすること

---

## コーディング規約

- Swift の命名規則に従う（型はUpperCamelCase・変数はlowerCamelCase）
- SwiftUI の View は単一責任の原則に従い、1ファイル1View を基本とする
- ViewModelはObservableObjectに準拠し、@Publishedでプロパティを公開する
- CoreDataの操作はViewModelに閉じ込め、Viewから直接操作しない
- エラーハンドリングはdo-catch で明示的に行う
- 日本語コメントで処理内容を記述してよい

---

## 権限・Info.plist

以下のUsage Descriptionキーが必要：

- `NSCameraUsageDescription`：名刺を撮影するために使用
- `NSContactsUsageDescription`：連絡先への読み書きに使用
- `NSPhotoLibraryUsageDescription`：名刺画像を保存するために使用

---

## 開発者メモ

- Xcodeのプロジェクトファイル（.xcodeproj）は Claude Code が直接編集しない
  → 新規Swiftファイルを追加した場合はXcodeのナビゲータに手動で追加する
- ビルドエラーはそのままコピーして Claude Code に渡せばOK
- フェーズが完了したら `git commit` してから次フェーズに進む
- `.gitignore` はSwift公式テンプレートを使用すること
- Foundation Models はシミュレータで動作しない。実機（iPhone 15 Pro以降 + Apple Intelligence有効）でテストする
- Foundation Models の組み込みは `CardFormViewModel` の `populateFromOCR(image:)` 内にコメントアウトで残してある
  → FoundationModels framework をリンクし、`import FoundationModels` を追加してからコメントを外す
  → 利用可否は `SystemLanguageModel.default.availability` で確認し、`.available` 以外は次の Tier にフォールバック
- `@Generable` / `@Guide` は FoundationModels framework のマクロ
- Qwen2.5 モデルはシミュレータでも動作するが Neural Engine は使えない（CPU推論にフォールバック）
- `LocalLLMService` はモデルを `~/Library/Application Support/LocalLLM/` に保存する
- `ContactsService.importContacts()` は実装済みだが、CardListView に取り込みボタンが未追加。追加する場合は CardListView のメニューに項目を足す
- `Item.swift` はXcodeテンプレートの残骸（未使用）

---

## 現在の状態

全5フェーズの実装が完了し、main ブランチにマージ済み。

### 実装済み（動作確認可能）
- 基本CRUD（一覧・詳細・手動入力フォーム・CoreData永続化）
- カメラ撮影 → OCR → AI意味分析（3段階カスケード）によるフィールド自動分類
- Qwen2.5-0.5B CoreML 推論（stateful KV キャッシュ・BPEトークナイザー）
- 設定画面（読み取り方法選択・モデルダウンロード管理・重複閾値・エクスポート設定）
- iPhoneの連絡先へのエクスポート
- CSV（UTF-8 BOM付き）・vCard 3.0 エクスポート
- Levenshtein距離による重複検出（デフォルト閾値0.75・設定変更可）・マージUI

### 未完了 / 保留中
- **Foundation Models 統合（Tier 1）：** `CardFormViewModel` にコメントアウトで残存。FoundationModels framework をリンクすれば有効化できる
- **連絡先インポートのUI：** `ContactsService.importContacts()` は実装済みだが CardListView のメニューに未追加
- **テスト：** `MeishiTests.swift` / `MeishiUITests.swift` はプレースホルダーのみ。実テストは未実装

### 技術的な注意点
- Foundation Models はシミュレータで動作しない（実機 iPhone 15 Pro以降 + Apple Intelligence有効が必要）
- Qwen2.5 CoreML はシミュレータでも動作するが低速（CPU推論）
- OCR認識言語：`["ja-JP", "en-US"]`。他言語は非対応
- 重複判定は名前70%・会社名30%の重み付きスコア（SettingsView でスライダー変更可）
- CSV は Excel での文字化けを防ぐため UTF-8 BOM を付与（設定で無効化可能）
- vCard は 3.0 形式（設定で 4.0 に変更可能）
- Qwen モデルのダウンロードサイズ：約 275MB（weights/weight.bin が約 268MB）
