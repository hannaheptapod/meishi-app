# CLAUDE.md — 名刺管理アプリ（Meishi）

## ⚠️ 作業開始前チェックリスト（必須）

コードを変更する前に必ず実行すること：

1. `git branch --show-current` でブランチを確認
2. `main` なら先にブランチを切る（例：`feature/<機能名>`・`fix/<修正内容>`・`docs/<内容>`）
3. ブランチを切ってから編集開始

作業完了時：
4. 実装内容が CLAUDE.md の「CoreData スキーマ」「ディレクトリ構成」「実装済み機能」に反映されているか確認し、ズレがあれば同じPRで更新する

---

## ブランチ・PR 戦略（厳守）

- **main への直接 push・commit は絶対禁止。** 必ず feature ブランチを切り、PR を通してマージする
- ブランチ命名：`feature/<機能名>`・`fix/<修正内容>`・`docs/<内容>`
- main にマージ後は作業ブランチをローカル・リモートともに削除する
- PR は機能単位でまとめる。無関係な変更を混在させない

---

## プロジェクト概要

iPhoneで使える名刺管理アプリ。カメラ撮影・OCR読み取り・手動入力で名刺をデジタル管理し、
iPhoneの連絡先との連携やCSV/vCard出力に対応する。クラウド同期・外部API通信は行わない。

---

## 技術スタック

| 項目 | 採用技術 |
|---|---|
| UI フレームワーク | SwiftUI |
| データ永続化 | CoreData（端末内のみ・オフライン完結） |
| OCR（文字認識） | Vision Framework（VNRecognizeTextRequest） |
| 意味分析 Tier 1 | Apple Foundation Models（FoundationModels framework・現在コメントアウト中） |
| 意味分析 Tier 2 | Qwen2.5-0.5B-Instruct CoreML（LocalLLMService / オプションダウンロード） |
| 意味分析 Tier 3 | 正規表現ベース分類（CardFieldClassifier・常時利用可能） |
| BPEトークナイザー | Qwen25Tokenizer（HuggingFace tokenizer.json を解析） |
| カメラ | AVFoundation |
| 連絡先連携 | CNContactStore（Contacts framework） |
| エクスポート | CSV・vCard（.vcf） |
| 設定永続化 | UserDefaults（SettingsStore） |

---

## AI処理の3層構成

**OCR（Vision Framework）**
- `VNRecognizeTextRequest`・`.accurate` モード・`recognitionLanguages = ["ja-JP", "en-US"]`
- 出力：テキスト行の配列（`[String]`）

**意味分析（3段階カスケード）**

```
Tier 1: Apple Intelligence（iOS 18+ / iPhone 15 Pro以降）
         ↓ 利用不可 or 失敗
Tier 2: Qwen2.5-0.5B CoreML（LocalLLMService / ~275MB ダウンロード必須）
         ↓ 未ダウンロード or 失敗
Tier 3: CardFieldClassifier（正規表現・常時利用可能）
```

- `automatic`（デフォルト）/ `appleIntelligence` / `localLLM` / `classifier` を SettingsView で選択
- **Tier 1**：`@Generable`+`@Guide` マクロで `ParsedCard` 型を構造化出力。FoundationModels framework 未リンクのためコメントアウト中（`CardFormViewModel.populateFromOCR` 内）。リンク後 `import FoundationModels` を追加して有効化
- **Tier 2**：ChatML プロンプト → JSON パース。`isInferencing` フラグで二重実行を防止。JSON括弧カウントによる早期終了・途中打ち切り時の補完を実装。iOS 18+ は `MLState` による stateful KV キャッシュで高速化
- **Tier 3**：2パス方式（パス1：メール・電話・URL・住所・会社名・役職を正規表現抽出。パス2：残り行から氏名推定・姓名分割）

---

## ディレクトリ構成

```
meishi-app/
├── CLAUDE.md
├── Meishi/
│   ├── App/
│   │   ├── MeishiApp.swift
│   │   └── PersistenceController.swift          # CoreData スタック・軽量マイグレーション設定
│   ├── Models/
│   │   ├── BusinessCard+CoreDataClass.swift
│   │   └── BusinessCard+CoreDataProperties.swift
│   ├── Views/
│   │   ├── ContentView.swift
│   │   ├── CardListView.swift
│   │   ├── CardDetailView.swift
│   │   ├── CardFormView.swift
│   │   ├── CameraView.swift
│   │   ├── DuplicateListView.swift              # 重複候補一覧
│   │   ├── DuplicateMergeView.swift             # マージUI
│   │   └── SettingsView.swift                  # 読み取り方法・エクスポート設定・モデル管理
│   ├── ViewModels/
│   │   ├── CardListViewModel.swift
│   │   ├── CardFormViewModel.swift
│   │   └── SettingsStore.swift                 # UserDefaults ラッパー・ReadingMethod enum
│   ├── Services/
│   │   ├── OCRService.swift
│   │   ├── ContactsService.swift
│   │   ├── ExportService.swift
│   │   ├── LocalLLMService.swift               # Qwen2.5 CoreML 推論・モデル管理
│   │   └── Qwen25Tokenizer.swift               # BPE トークナイザー
│   ├── Utilities/
│   │   ├── DuplicateChecker.swift
│   │   └── CardFieldClassifier.swift
│   ├── Resources/
│   │   └── BusinessCard.xcdatamodeld           # v1（初期）・v2（department追加）・v3（reading追加）の3バージョン
│   └── Assets.xcassets                         # アプリアイコン・アクセントカラー含む
├── MeishiTests/
│   └── MeishiTests.swift                       # プレースホルダーのみ
└── MeishiUITests/
    ├── MeishiUITests.swift
    └── MeishiUITestsLaunchTests.swift
```

---

## CoreData スキーマ（v3 現在）

エンティティ名：`BusinessCard`

| 属性名 | 型 | 備考 |
|---|---|---|
| id | UUID | 主キー |
| lastName | String | 姓 |
| lastNameReading | String | **姓ふりがな（v3で追加）** |
| firstName | String | 名 |
| firstNameReading | String | **名ふりがな（v3で追加）** |
| company | String | 会社名 |
| department | String | **部署（v2で追加）** |
| title | String | 役職 |
| email | String | メールアドレス |
| phone | String | 電話番号 |
| address | String | 住所 |
| website | String | WebサイトURL |
| notes | String | メモ |
| imageData | Binary Data | 名刺写真（任意保存） |
| createdAt | Date | 登録日時 |
| updatedAt | Date | 更新日時 |

- スキーマは `BusinessCard 3.xcdatamodel`（v3）が現在のモデル。軽量マイグレーション（`NSMigratePersistentStoresAutomaticallyOption` + `NSInferMappingModelAutomaticallyOption`）で v1 → v2 → v3 を自動対応
- **スキーマを変更する場合：** `.xcdatamodeld` に新バージョンを追加し、軽量マイグレーション可能な変更（属性追加・省略可能化など）にとどめる。破壊的変更は Custom Migration が必要

---

## 実装済み機能

- 基本CRUD（一覧・詳細・手動入力・CoreData永続化）
- カメラ撮影 → OCR → AI意味分析（3段階カスケード）によるフィールド自動分類
- Qwen2.5-0.5B CoreML 推論（stateful KV キャッシュ・BPEトークナイザー・早期終了ロジック）
- 設定画面（読み取り方法選択・モデルダウンロード管理・重複閾値・エクスポート設定）
- iPhoneの連絡先へのエクスポート（CNContactStore）
- 連絡先からインポート（`ellipsisMenu` 経由・確認ダイアログ付き・空エントリスキップ）
- CSV（UTF-8 BOM付き）・vCard 3.0 エクスポート（ExportServiceで部署も出力）
- Levenshtein距離による重複検出（デフォルト閾値0.75・設定変更可）・マージUI
- アプリアイコン・アクセントカラー
- 閉じるボタン・検索UI改善
- ふりがなフィールド（姓読み・名読み）：OCR時に名刺上のフリガナ行があれば自動取得、なければ CFStringTokenizer で自動生成。フォームで手動修正可能。名前順ソート・検索でも利用

## 未完了 / 保留中

- **Foundation Models 統合（Tier 1）：** `CardFormViewModel.populateFromOCR` にコメントアウトで残存。FoundationModels framework をリンクすれば有効化可能
- **テスト：** `MeishiTests.swift` は機能テストを網羅的に実装済み（`BusinessCard` プロパティ・`DuplicateChecker`・`ExportService`・`CardFieldClassifier`・`LocalLLMService` 関連）。`MeishiUITests.swift` / `MeishiUITestsLaunchTests.swift` は現時点で不要なためコメントアウト済み

---

## コーディング規約

- Swift 命名規則：型は UpperCamelCase・変数は lowerCamelCase
- SwiftUI View は単一責任・1ファイル1View を基本
- ViewModel は `ObservableObject` に準拠し `@Published` でプロパティを公開
- CoreData の操作は ViewModel に閉じ込め、View から直接操作しない
- エラーハンドリングは `do-catch` で明示的に行う
- 日本語コメントで処理内容を記述してよい
- サービスクラス（`ExportService`・`ContactsService`・`LocalLLMService` など）は `static let shared` シングルトンパターンを使用
- `CardListViewModel` は `NavigationStack` レベルで `.environmentObject(viewModel)` を注入し、子 View は `@EnvironmentObject` で受け取る
- ViewModel のエラーは `@Published var errorMessage: String?` に集約し、View 側で Alert として表示する
- 検索フィルタ・エクスポート・一括削除などのビジネスロジックは View ではなく ViewModel に置く

---

## 権限・Info.plist

- `NSCameraUsageDescription`：名刺を撮影するために使用
- `NSContactsUsageDescription`：連絡先への読み書きに使用
- `NSPhotoLibraryUsageDescription`：名刺画像を保存するために使用

---

## 開発者メモ

- **Xcodeプロジェクトファイル（.xcodeproj）は Claude Code が直接編集しない。** 新規 Swift ファイルを追加した場合は Xcode のナビゲータに手動で追加すること
- Foundation Models はシミュレータで動作しない（実機 iPhone 15 Pro以降 + Apple Intelligence有効が必要）
- Qwen2.5 CoreML はシミュレータでも動作するが低速（CPU推論・Neural Engine 不使用）
- `LocalLLMService` はモデルを `~/Library/Application Support/LocalLLM/` に保存する（合計約 275MB）
- CSV は Excel での文字化けを防ぐため UTF-8 BOM を付与（設定で無効化可能）
- vCard は 3.0 形式（設定で 4.0 に変更可能）
- 重複判定は名前70%・会社名30%の重み付きスコア
- `Item.swift` は Xcode テンプレートの残骸（未使用）
