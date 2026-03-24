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
- 出力：生のテキスト文字列

**層2 — 意味分析（Foundation Models）**
- Vision が抽出した生テキストを受け取り、フィールドに構造化する
- `@Generable` マクロで定義した `ParsedCard` 型を使い、型安全な出力を得る
- Apple Intelligence が有効な端末（iPhone 15 Pro以降）でのみ利用可能

```swift
@Generable
struct ParsedCard {
    @Guide("氏名")      var name: String
    @Guide("会社名")    var company: String
    @Guide("役職")      var title: String
    @Guide("電話番号")  var phone: String
    @Guide("メールアドレス") var email: String
    @Guide("住所")      var address: String
    @Guide("WebサイトURL")  var website: String
}
```

**フォールバック（Foundation Models利用不可の場合）**
- `SystemLanguageModel.availability` を起動時に確認する
- 利用不可の場合は `CardFieldClassifier`（正規表現ベース）で分類する
- 電話番号・メール・URLは正規表現で高精度に判定できる
- 氏名・会社・役職は行順ヒューリスティック（1行目=氏名、2行目=会社 等）で推定する

---

## ディレクトリ構成方針

```
Meishi/
├── CLAUDE.md                  # このファイル
├── Meishi/
│   ├── App/
│   │   └── MeishiApp.swift
│   ├── Models/
│   │   ├── BusinessCard+CoreDataClass.swift
│   │   └── BusinessCard+CoreDataProperties.swift
│   ├── Views/
│   │   ├── CardListView.swift
│   │   ├── CardDetailView.swift
│   │   ├── CardFormView.swift
│   │   └── CameraView.swift
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
└── MeishiTests/
```

---

## CoreData スキーマ

エンティティ名：`BusinessCard`

| 属性名 | 型 | 備考 |
|---|---|---|
| id | UUID | 主キー |
| name | String | 氏名 |
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

### フェーズ 1（MVP）— 基本CRUD ✅ 着手前
- 名刺一覧画面（CardListView）
- 名刺詳細画面（CardDetailView）
- 手動入力フォーム（CardFormView）
- CoreData による保存・編集・削除

### フェーズ 2 — カメラ + OCR + AI意味分析 ✅ 着手前
- AVFoundation でカメラ起動（CameraView）
- Vision Framework で文字認識（OCRService）
- Foundation Models で生テキストを `ParsedCard` 型に構造化（CardFormViewModel）
- Foundation Models 利用不可の場合は CardFieldClassifier（正規表現）でフォールバック
- `SystemLanguageModel.availability` で起動時に利用可否を判定する
- 認識後フォームで内容を確認・修正してから保存

### フェーズ 3 — 連絡先連携 ✅ 着手前
- iPhoneの連絡先へのエクスポート（CNContactStore）
- iPhoneの連絡先からのインポート
- CSV・vCard（.vcf）エクスポート（ExportService）

### フェーズ 4 — 重複チェック・名寄せ ✅ 着手前
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
- Foundation Models はシミュレータで動作しない。フェーズ2以降は実機（iPhone 15 Pro以降）でテストする
- Foundation Models の利用可否は `SystemLanguageModel.default.availability` で確認する
  → `.available` 以外の場合は必ず CardFieldClassifier にフォールバックすること
- `@Generable` / `@Guide` は FoundationModels framework のマクロ。import FoundationModels が必要

---

## 現在の状態

- [ ] GitHubリポジトリ作成済み
- [ ] Xcodeプロジェクト作成済み
- [ ] フェーズ1 実装完了
- [ ] フェーズ2 実装完了
- [ ] フェーズ3 実装完了
- [ ] フェーズ4 実装完了
