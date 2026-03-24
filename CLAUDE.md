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
| 意味分析（フィールド分類） | Apple Foundation Models（FoundationModels framework） |
| 意味分析（フォールバック） | 正規表現ベース分類（Foundation Modelsが利用不可の場合） |
| カメラ | AVFoundation |
| 連絡先連携 | CNContactStore（Contacts framework） |
| エクスポート | CSV・vCard（.vcf） |
| バージョン管理 | Git / GitHub |

クラウド同期・外部APIへの通信は一切行わない。すべての処理を端末内で完結させる。

### AI処理の2層構成

OCRと意味分析は役割が異なるフレームワークで分担する。

**層1 — OCR（Vision Framework）**
- `VNRecognizeTextRequest` で名刺画像からテキストを抽出する
- `.accurate` モードを使用し、`usesLanguageCorrection = true` を設定する
- `recognitionLanguages = ["ja-JP", "en-US"]` で日本語・英語に対応
- 出力：テキスト行の配列（`[String]`）

**層2 — 意味分析（Foundation Models）**
- Vision が抽出したテキスト行を受け取り、フィールドに構造化する
- `@Generable` マクロで定義した `ParsedCard` 型を使い、型安全な出力を得る（FoundationModels framework リンク後に有効化）
- Apple Intelligence が有効な端末（iPhone 15 Pro以降）でのみ利用可能
- **現状：** FoundationModels framework 未リンクのため、Foundation Models 呼び出し部分はコメントアウト中。`#available(iOS 18.0, *)` の分岐は存在するが、常に CardFieldClassifier にフォールバックしている

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

**フォールバック（CardFieldClassifier）**
- `#available(iOS 18.0, *)` で分岐し、Foundation Models 利用不可の場合（または未リンク時）は `CardFieldClassifier`（正規表現ベース）で分類する
- **2パス方式：**
  - パス1：メール・電話・URL・住所・会社名・役職をキーワード／正規表現で抽出
  - パス2：未分類の残り行から氏名を推定し、スペース（全角・半角）で姓・名に分割

---

## ディレクトリ構成方針

```
Meishi/
├── CLAUDE.md                  # このファイル
├── Meishi/
│   ├── App/
│   │   ├── MeishiApp.swift
│   │   └── PersistenceController.swift  # CoreData スタック管理
│   ├── Models/
│   │   ├── BusinessCard+CoreDataClass.swift
│   │   └── BusinessCard+CoreDataProperties.swift
│   ├── Views/
│   │   ├── CardListView.swift
│   │   ├── CardDetailView.swift
│   │   ├── CardFormView.swift
│   │   ├── CameraView.swift
│   │   ├── DuplicateListView.swift      # フェーズ4: 重複候補一覧
│   │   └── DuplicateMergeView.swift     # フェーズ4: マージUI
│   ├── ViewModels/
│   │   ├── CardListViewModel.swift
│   │   └── CardFormViewModel.swift
│   ├── Services/
│   │   ├── OCRService.swift
│   │   ├── ContactsService.swift
│   │   └── ExportService.swift
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
- **現状：** Foundation Models 呼び出しはコメントアウト中。常に CardFieldClassifier にフォールバックしている
- 認識後フォームで内容を確認・修正してから保存

### フェーズ 3 — 連絡先連携 ✅ 実装完了
- iPhoneの連絡先へのエクスポート（CNContactStore）
- iPhoneの連絡先からのインポート（ContactsService に実装済み・UI未公開）
- CSV・vCard（.vcf）エクスポート（ExportService）

### フェーズ 4 — 重複チェック・名寄せ ✅ 実装完了
- 名前・会社名の類似度判定（Levenshtein距離）
- 重複候補の提示UI
- マージ機能

---

## ブランチ命名規則

- 機能ベースで命名する：`feature/<機能名>`
- 例：`feature/basic-crud`、`feature/camera-ocr`、`feature/contacts-export`、`feature/duplicate-check`
- フェーズ完了後は main にマージしてから次のブランチを切る

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
- Foundation Models はシミュレータで動作しない。実機（iPhone 15 Pro以降）でテストする
- Foundation Models の組み込みは `CardFormViewModel` の `populateFromOCR(image:)` 内にコメントアウトで残してある（行96〜128付近）
  → FoundationModels framework をリンクしてからコメントを外す
  → 利用可否は `SystemLanguageModel.default.availability` で確認し、`.available` 以外は CardFieldClassifier にフォールバックする
- `@Generable` / `@Guide` は FoundationModels framework のマクロ。`import FoundationModels` が必要
- `ContactsService.importContacts()` は実装済みだが、CardListView に取り込みボタンが未追加。追加する場合は CardListView のメニューに項目を足す

---

## 現在の状態

全4フェーズの実装が完了し、main ブランチにマージ済み。

### 実装済み（動作確認可能）
- 基本CRUD（一覧・詳細・手動入力フォーム・CoreData永続化）
- カメラ撮影 → OCR → CardFieldClassifier（正規表現）によるフィールド自動分類
- iPhoneの連絡先へのエクスポート
- CSV（UTF-8 BOM付き）・vCard 3.0 エクスポート
- Levenshtein距離による重複検出（閾値0.75）・マージUI

### 未完了 / 保留中
- **Foundation Models 統合：** `CardFormViewModel` にコメントアウトで残存。FoundationModels framework をリンクすれば有効化できる
- **連絡先インポートのUI：** `ContactsService.importContacts()` は実装済みだが CardListView のメニューに未追加
- **テスト：** `MeishiTests.swift` / `MeishiUITests.swift` はプレースホルダーのみ。実テストは未実装

### 技術的な注意点
- Foundation Models はシミュレータで動作しない（実機 iPhone 15 Pro以降 + Apple Intelligence有効が必要）
- OCR認識言語：`["ja-JP", "en-US"]`。他言語は非対応
- 重複判定は名前70%・会社名30%の重み付きスコア
- CSV は Excel での文字化けを防ぐため UTF-8 BOM を付与
- vCard は 3.0 形式（4.0ではない）
- `Item.swift` はXcodeテンプレートの残骸（未使用）

