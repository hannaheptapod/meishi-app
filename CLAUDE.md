# CLAUDE.md — 名刺管理アプリ（eMeishi）

## 🚫 ビルド・アップロード前チェックリスト（必須・違反禁止）

**アーカイブ・アップロードは事前精査なしに絶対実行しない。**

アーカイブ実行前に以下を**この順で必ず実施**する。

### Step 1: 事前チェックスクリプトを実行

```bash
./scripts/pre-build-check.sh
```

全項目 **PASS** になるまでアーカイブ禁止。スクリプトが exit 1 の場合は原因を修正してから再実行。

- ビルド番号は **`yyyymmddNNN`** 形式（NNN は 001 始まりの当日連番）
- 例：2026-04-09 の1本目 → `20260409001`、2本目 → `20260409002`

### Step 2: ユーザー承認（必須）

スクリプト結果をユーザーに提示し、**明示的な承認を得てから**アーカイブ・アップロードを実行する。

ユーザーの承認なしにビルドを増やすことは**絶対禁止**

---

## ⚠️ 作業開始前チェックリスト（必須）

---

## ⚠️ 作業開始前チェックリスト（必須）

コードを変更する前に必ず実行すること：

1. `git branch --show-current` でブランチを確認
2. **規定外プレフィックス**（`claude/` `agent/` `temp/` 等）なら **即座にリネーム**（`git branch -m <旧名> feature/<新名>`）
3. `main` にいる場合は **絶対に禁止**。`develop` に切り替えてからブランチを切る
4. `develop` にいる場合は `feature/<機能名>` などのブランチを切ってから編集開始
5. `feature/*` / `fix/*` 等の規定ブランチにいる場合はそのまま作業継続

作業完了時：
6. 実装内容が CLAUDE.md の「CoreData スキーマ」「ディレクトリ構成」「実装済み機能」に反映されているか確認し、ズレがあれば同じPRで更新する

<important>
## 必須スキル（hookで強制。違反時はユーザーが検知する）

ユーザーのプロンプトを受け取ったら、コード修正やファイル読み込みの**前に**、
以下の2つのスキルをこの順で実行せよ:

1. `/branch` — ブランチ確認・規定外プレフィックスなら即リネーム・main/developなら作業ブランチを作成
2. `/translate` — ユーザーの指示を「ユーザー語→エンジニア語→リポジトリの具体箇所」に2段階翻訳

この2つを**スキップしてはならない**。
hookの `<user-prompt-submit-hook>` メッセージでも同じ指示が届く。

**hookによる自動ブロック（`.claude/hooks/guard-git.sh`）：**
- `main` / `develop` への直接コミット・マージ・push → **exit 2 でブロック**
- `feature/` `fix/` `release/` `hotfix/` `docs/` `chore/` 以外のプレフィックスでのブランチ作成 → **exit 2 でブロック**
</important>

---

## ブランチ・PR 戦略（Git Flow・厳守）

### ブランチ構成

```
main          本番リリース済みコード（App Store にリリースされたもの）。タグ（v1.0, v1.1）を打つ
develop       次のリリースに向けた統合ブランチ。常に動作する状態を保つ
feature/*     1機能1ブランチ。develop から分岐し develop へ PR でマージ
release/*     App Store 提出前の最終確認・軽微バグ修正のみ。機能追加禁止
hotfix/*      本番の緊急バグ修正。main から分岐し main と develop の両方へマージ
```

### ルール

- **ブランチ名は必ず規定のプレフィックスを使うこと。** `feature/` `fix/` `release/` `hotfix/` `docs/` `chore/` 以外のプレフィックス（`claude/` など外部ツール・AIエージェントが自動生成するものを含む）は使用禁止。外部から指定されたブランチ名であっても規定外なら `/branch` スキルで**即座にリネーム**する。
- **main・develop への直接 push・commit は絶対禁止。** 必ずブランチを切り PR を通す。違反は `.claude/hooks/guard-git.sh` が自動ブロック（exit 2）する
- **日常の開発フロー：** `develop` から `feature/<機能名>` を切る → PR → `develop` へマージ
- **リリースフロー：** `develop` から `release/<バージョン>` を切る → `main` と `develop` の両方にマージ → `main` にタグ付け
  1. `git checkout develop && git checkout -b release/<x.y.z>`
  2. `Info.plist` のバージョン・ビルド番号を更新（ビルド番号は `yyyymmddxyz` 形式、既存より大きいか `asc builds list` で確認）
  3. ビルド・アップロード：CLAUDE.md 冒頭の「ビルド・アップロード前チェックリスト」を必ず実施し**ユーザー承認を得てから**実行
  4. スクリーンショット撮影が必要な場合：開発者メモの手順に従い撮影・ASC アップロード（`asc-shots-pipeline` スキル参照）
  5. What's New 更新：`asc-whats-new-writer` スキルを使う
  6. 審査提出：`asc-release-flow` スキルを使う（提出前ヘルスチェック → Submit）
  7. 提出後：`release/<x.y.z>` → `main`（PR）、`release/<x.y.z>` → `develop`（PR）、`main` に `vX.Y.Z` タグ、ブランチ削除
- **緊急修正フロー：** `main` から `hotfix/<内容>` を切る → `main` と `develop` の両方にマージ
- ブランチ命名：`feature/<機能名>`・`fix/<修正内容>`・`release/<x.y>`・`hotfix/<内容>`・`docs/<内容>`・`chore/<内容>`
- マージ後は作業ブランチをローカル・リモートともに削除する
- PR は機能単位でまとめる。無関係な変更を混在させない

---

## プロジェクト概要

iPhoneで使える名刺管理アプリ。カメラ撮影・OCR読み取り・手動入力で名刺をデジタル管理し、
iPhoneの連絡先との連携やCSV/vCard出力に対応する。モデルファイル配布に CloudKit Public Database を使用（iCloudアカウント不要で読み取り可能）。

---

## 技術スタック

| 項目 | 採用技術 |
|---|---|
| UI フレームワーク | SwiftUI |
| データ永続化 | CoreData（端末内のみ・オフライン完結） |
| OCR（文字認識） | Vision Framework（VNRecognizeTextRequest） |
| 意味分析（Apple Intelligence端末） | Apple Foundation Models（FoundationModels framework・`#if canImport` で条件付きコンパイル・iOS 26+） |
| 意味分析（非対応端末） | Qwen3-0.6B Anemll ANE対応 CoreML（LocalLLMService / CloudKit経由 or ローカル配置）Embed+FFN+LMHead 3モデル構成・stateful KV cache・LUT6量子化・`.cpuAndNeuralEngine` |
| 意味分析（前後段処理・常時） | 正規表現ベース分類（CardFieldClassifier・常時利用可能） |
| BPEトークナイザー | Qwen25Tokenizer（HuggingFace tokenizer.json を解析） |
| カメラ | AVFoundation |
| 連絡先連携 | CNContactStore（Contacts framework） |
| エクスポート | CSV・vCard（.vcf） |
| モデル配布 | CloudKit Public Database（CloudKitModelService・CKAsset / weight.bin チャンク分割）+ Documents/LocalLLM/ ローカル配置（開発用） |
| 生体認証 | LocalAuthentication（LAContext・Face ID / Touch ID） |
| iCloud 同期 | NSPersistentCloudKitContainer（CloudKit Private Database・設定でON/OFF切替） |
| 設定永続化 | UserDefaults（SettingsStore） |

---

## AI処理の構成

**OCR（Vision Framework）**
- `VNRecognizeTextRequest`・`.accurate` モード・`recognitionLanguages = ["ja-JP", "en-US"]`
- 出力：テキスト行の配列（`[String]`）

**意味分析（デバイス分岐モデル）**

```
【Apple Intelligence 対応端末】      【非対応端末】
iOS 26+ / iPhone 15 Pro以降          それ以外のデバイス
        ↓                                    ↓
Foundation Models のみ使用          Qwen3-0.6B CoreML のみ使用
（両エンジンは排他利用・フォールバック連鎖なし）

【両端末共通】
前段処理: CardFieldClassifier（正規表現）→ 確定フィールドを抽出
後段処理: CardFieldClassifier（正規表現）→ 残余行から会社・役職を補完
```

- `appleIntelligence` / `localLLM` / `classifier` を SettingsView で選択
- **両LLMエンジン共通の前後段処理（ハイブリッド方式）**：`CardFieldClassifier.classifyStructuredFields` で Pass1（正規表現：email・phone・URL・住所・会社・部署・役職を抽出）+ Pass2（OCR座標情報を使った名前スコアリング：フリガナ近接・フォントサイズ・位置情報で確信度判定、>0.4 で名前確定）を実行。未分類行のみを各LLMエンジンに送り、結果をマージする。ルールベース確定結果を常に優先
- **Apple Intelligence 対応端末**：ハイブリッド前段処理 → 未分類行のみ `@Generable`+`@Guide` マクロで `ParsedCard` 型を構造化出力。既知フィールドをプロンプトコンテキストとして渡し幻覚を防止。email/phone/address/website はルールベース結果を常に優先
- **非対応端末**：ハイブリッド前段処理 → 未分類行のみ LLM で**単一パス分類**（1行1回の forward pass でカテゴリ判定：name/title/department/company）。自動回帰生成を完全廃止。Anemll Qwen3-0.6B-ctx512（Embed→FFN Prefill→LM Head 3モデル）・stateful KV cache（iOS 18+ MLState）・LUT6量子化・`computeUnits = .cpuAndNeuralEngine`（ANE 有効）・バッチサイズ64・コンテキスト512トークン・LM Head 16チャンク分割。10秒タイムアウト
- **前後段処理（常時）**：`classify(lines:)` による全フィールド分類（Pass1 + Pass2 + 残り行から会社・役職補完）。LLM不使用・常時利用可能

---

## ディレクトリ構成

```
meishi-app/
├── CLAUDE.md
├── eMeishi/
│   ├── App/
│   │   ├── eMeishiApp.swift
│   │   └── PersistenceController.swift          # CoreData スタック・軽量マイグレーション設定
│   ├── Models/
│   │   ├── BusinessCard+CoreDataClass.swift
│   │   ├── BusinessCard+CoreDataProperties.swift
│   │   ├── Tag+CoreDataClass.swift
│   │   └── Tag+CoreDataProperties.swift
│   ├── ContentView.swift                        # ルートレベルに配置
│   ├── Views/
│   │   ├── CardListView.swift
│   │   ├── CardDetailView.swift
│   │   ├── CardFormView.swift
│   │   ├── CameraView.swift                    # 連続撮影カメラ（CameraBatchCapture・純UIKit管理・標準カメラUI+オーバーレイ）
│   │   ├── BatchReviewView.swift               # 連続撮影後の一括確認（CardFormViewを順番に表示）
│   │   ├── DuplicateListView.swift              # 重複候補一覧
│   │   ├── DuplicateMergeView.swift             # マージUI
│   │   ├── BulkTagAssignView.swift             # 一括タグ付けシート（選択モード用）
│   │   ├── TagManagementView.swift             # タグ管理（作成・削除・色変更・並べ替え）
│   │   ├── LockScreenView.swift                # 生体認証ロック画面
│   │   ├── PrivacyOverlayView.swift            # App Switcher プライバシーオーバーレイ
│   │   ├── InsightsView.swift                  # 人脈インサイト（会社別・エリア別・職種別・月別統計）
│   │   └── SettingsView.swift                  # 読み取り方法・エクスポート設定・セキュリティ・モデル管理・プライバシーポリシー/サポートリンク
│   ├── ViewModels/
│   │   ├── CardListViewModel.swift
│   │   ├── CardFormViewModel.swift
│   │   └── SettingsStore.swift                 # UserDefaults ラッパー・ReadingMethod enum
│   ├── Services/
│   │   ├── AuthenticationService.swift         # 生体認証（Face ID / Touch ID）ラッパー
│   │   ├── OCRService.swift
│   │   ├── ContactsService.swift
│   │   ├── ExportService.swift
│   │   ├── CloudKitModelService.swift          # CloudKit Public DB からモデルDL・Embed/FFN/LMHead 3モデル対応・weight チャンク結合
│   │   ├── LocalLLMService.swift               # Anemll Qwen3-0.6B ANE対応 CoreML 推論（Embed+FFN+LMHead）・stateful KV cache・Documents/AppSupport 二重パス
│   │   ├── SearchQueryClassifier.swift         # AI自然言語検索のクエリ意図分類（時間表現+フィールド分類）
│   │   ├── AutoTagService.swift                # AI自動タグ提案（既存タグからカード内容に該当するものを提案）
│   │   ├── InsightsService.swift               # 人脈インサイト集計（会社別・エリア別・職種別・月別）
│   │   └── Qwen25Tokenizer.swift               # BPE トークナイザー（Qwen3互換）
│   ├── Utilities/
│   │   ├── DuplicateChecker.swift
│   │   ├── CardFieldClassifier.swift
│   │   └── LegalEntityTerms.swift              # 法人格リスト一元管理（漢字・読み・英語・略称）
│   ├── Resources/
│   │   └── BusinessCard.xcdatamodeld           # v1（初期）・v2（department追加）・v3（reading追加）・v4（isFavorite+Tag追加）・v5（Tag.sortOrder追加）の5バージョン
│   ├── AppIcon.icon/                           # アプリアイコン
│   └── Assets.xcassets                         # アクセントカラー
├── eMeishiTests/
│   └── eMeishiTests.swift                      # 機能テスト網羅的に実装済み
└── eMeishiUITests/
    ├── eMeishiUITests.swift                  # UIテスト（コンテキストメニュー・選択モード・検索・ナビゲーション）
    └── eMeishiUITestsLaunchTests.swift       # 起動テスト
```

---

## CoreData スキーマ（v5 現在）

### エンティティ：`BusinessCard`

| 属性名 | 型 | 備考 |
|---|---|---|
| id | UUID | 主キー |
| lastName | String | 姓 |
| lastNameReading | String | **姓ふりがな（v3で追加）** |
| firstName | String | 名 |
| firstNameReading | String | **名ふりがな（v3で追加）** |
| company | String | 会社名 |
| companyReading | String | **会社名ふりがな（v3で追加）・法人格を含まない** |
| department | String | **部署（v2で追加）** |
| title | String | 役職 |
| email | String | メールアドレス |
| phone | String | 電話番号 |
| address | String | 住所 |
| website | String | WebサイトURL |
| notes | String | メモ |
| imageData | Binary Data | 名刺写真（任意保存） |
| isFavorite | Boolean | **お気に入りフラグ（v4で追加）・デフォルト NO** |
| createdAt | Date | 登録日時 |
| updatedAt | Date | 更新日時 |
| tags | Relationship | **Tag への多対多リレーション（v4で追加）** |

### エンティティ：`Tag`（v4で追加）

| 属性名 | 型 | 備考 |
|---|---|---|
| id | UUID | 主キー |
| name | String | タグ名 |
| colorHex | String | 表示色（16進数・デフォルト #007AFF） |
| sortOrder | Int16 | **表示順（v5で追加）・デフォルト 0** |
| createdAt | Date | 作成日時 |
| cards | Relationship | BusinessCard への多対多リレーション（inverse: tags） |

- スキーマは `BusinessCard 5.xcdatamodel`（v5）が現在のモデル。軽量マイグレーション（`NSMigratePersistentStoresAutomaticallyOption` + `NSInferMappingModelAutomaticallyOption`）で v1 → v2 → v3 → v4 → v5 を自動対応
- **スキーマを変更する場合：** `.xcdatamodeld` に新バージョンを追加し、軽量マイグレーション可能な変更（属性追加・省略可能化など）にとどめる。破壊的変更は Custom Migration が必要

---

## 実装済み機能

- 基本CRUD（一覧・詳細・手動入力・CoreData永続化）
- ふりがなフィールド（lastNameReading / firstNameReading / companyReading）：OCR時に自動生成（CFStringTokenizer）・手動入力可・名前順/会社名順ソートに使用・検索対象に追加
- カメラ撮影 → OCR → ハイブリッド意味分析（ルールベース前段 + LLM後段）によるフィールド自動分類（両LLMエンジン共通のclassifyStructuredFields前段処理）
- 連続撮影（バッチ撮影）：標準カメラUIで複数枚連続撮影し、撮影完了後にまとめて確認・保存。CameraBatchCapture（純UIKit・シングルトン）がカメラ表示を管理し、SwiftUIモーダルとの競合を回避。cameraOverlayViewで撮影枚数カウンター＋「完了」ボタンを標準UIに重ねる。BatchReviewViewでCardFormViewを順番に表示
- Anemll Qwen3-0.6B-ctx512 ANE対応推論（ハイブリッド方式: ルールベース前段抽出 + 座標ベース名前スコアリング + LLM**単一パス分類**（1行1回・3段 forward pass）・Embed+FFN+LMHead 3モデル・stateful KV cache・`.cpuAndNeuralEngine`・コンテキスト512トークン・10秒タイムアウト・BPEトークナイザー）
- モデルファイル二重パス: Documents/LocalLLM/（開発用・Finder/iTunes で転送）→ Application Support/LocalLLM/（CloudKit ダウンロード）の優先順で検索
- CloudKit Public Database 経由のモデル配布（Embed/FFN/LMHead 3モデル + 共有 weight チャンク分割・CKAsset・iCloudアカウント不要）
- iTunes ファイル共有（UIFileSharingEnabled）で Documents ディレクトリへの開発用モデル配置に対応
- 設定画面（読み取り方法選択・モデルダウンロード管理・重複閾値・エクスポート設定）
- iPhoneの連絡先へのエクスポート（CNContactStore）
- 連絡先からインポート（`ellipsisMenu` 経由・確認ダイアログ付き・空エントリスキップ）
- CSV（UTF-8 BOM付き）・vCard 3.0 エクスポート（ExportServiceで部署も出力）
- Levenshtein距離による重複検出（デフォルト閾値0.75・設定変更可）・マージUI
- アプリアイコン・アクセントカラー
- 閉じるボタン・検索UI改善
- ふりがなフィールド（姓読み・名読み）：OCR時に名刺上のフリガナ行があれば自動取得、なければ CFStringTokenizer で自動生成。フォームで手動修正可能。名前順ソート・検索でも利用
- お気に入り機能：スワイプ操作 or 詳細画面の★ボタンでトグル。一覧でお気に入りのみフィルタ可能。★アイコンで視覚表示
- タグ機能：ユーザー定義タグ（名前・色）を作成し名刺に複数紐づけ。タグ管理画面で追加・削除・ドラッグ＆ドロップ並べ替え（sortOrder）。一覧画面でタグフィルタ（AND条件）。フォーム画面でタグ選択。詳細画面でタグ表示
- 長押しコンテキストメニュー（ピークメニュー）：一覧画面でカードを長押しするとプレビュー付きメニュー表示（お気に入り・編集・vCard共有・連絡先保存・削除）
- 選択モード：一覧画面左上の「選択」ボタンで複数選択モード。一括削除・CSV/vCardエクスポート・一括タグ付けに対応。全選択/全解除・件数表示あり
- 触覚フィードバック：お気に入り切替時に UIImpactFeedbackGenerator で振動フィードバック
- フィルタ時カウント表示：フィルタや検索適用中にナビゲーションタイトルに件数表示
- UIテスト：`-UITestMode` 起動引数でインメモリ＋サンプルデータを使用。コンテキストメニュー・選択モード・検索・ナビゲーション等のUIテストを網羅的に実装
- セキュリティ：Face ID / Touch ID によるアプリロック（パスコードフォールバック付き）。ロック有効/無効の切替時にも認証要求。猶予時間設定（即時/15秒/1分/5分）。App Switcher でのコンテンツ隠蔽（PrivacyOverlay）。CoreData ストアに NSFileProtectionComplete を適用（デバイスロック時にデータベース暗号化）
- iCloud 同期：NSPersistentCloudKitContainer による CloudKit Private Database 同期。設定画面でON/OFF切替（デフォルトOFF）。変更後はアプリ再起動で反映。同一 Apple ID のデバイス間で名刺・タグデータを自動同期。オフライン時はローカルのみで動作し、オンライン復帰時に自動同期。競合解決は NSMergeByPropertyObjectTrumpMergePolicy（最後の書き込みが勝つ）
- AI自然言語検索：「先月会った渋谷のエンジニア」のような自然言語クエリで名刺を検索。時間表現は正規表現で抽出（LLM不要）、キーワードはPrefillモデルで1回forward passしフィールド分類（name/company/title/department/address）。分類結果からCoreDataフィルタを動的生成。テキスト検索で0件時に「AI検索で探す」ボタン表示。モデル未DL時はテキスト検索にフォールバック
- AI自動タグ提案：名刺スキャン後、既存タグから該当するものをAIが提案。各タグについて1回forward passで yes/no 分類。CardFormView のタグセクションに「AI提案」チップとして表示。タップで適用。タグ20個まで対応
- 人脈インサイト：名刺データの自動集計（会社別・エリア別・職種別・月別推移）。CoreData集約クエリのみでLLM不使用。メニューの「インサイト」から遷移
- AI重複検出強化：Levenshtein閾値未満（0.5〜閾値）のボーダーライン候補をAIで二次判定。会社名形式差異（「株式会社ABC」vs「ABC」）や転職ケース（同一人物・異なる会社/役職）を捕捉。「AI検出」バッジで表示
- アプリ内リンク：設定画面にプライバシーポリシー・サポートページへの Link を配置（GitHub Pages でホスト）
- CoreData エラーハンドリング：ストア読み込み失敗時に fatalError ではなくアラートで通知（loadError プロパティ）

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
- `NSFaceIDUsageDescription`：アプリのロック解除に使用
- `NSPhotoLibraryUsageDescription`：名刺画像を保存するために使用
- `UIFileSharingEnabled`：`true`（デバッグビルド・開発用モデル転送に使用）／`false`（本番ビルド前に必ず戻す）
- `LSSupportsOpeningDocumentsInPlace`：`false`（本番ビルド）
- CloudKit Capability + Background Modes（Remote notifications）：iCloud 同期に必要（Xcode で手動設定）

---

## 開発者メモ

- **Xcodeプロジェクトファイル（.xcodeproj）は Claude Code が直接編集しない。** Xcode 16 の File System Synchronized Groups により、eMeishi/ 配下に Swift ファイルを追加すれば自動的にビルド対象になる
- Foundation Models はシミュレータで動作しない（実機 iPhone 15 Pro以降 + Apple Intelligence有効が必要）
- Anemll Qwen3-0.6B-ctx512 はシミュレータでも動作するが低速（ANE 不使用・CPU推論）
- `LocalLLMService` のモデル検索パス: ① Documents/LocalLLM/（開発用・Finder/iTunes 転送）→ ② Application Support/LocalLLM/（CloudKit DL）。Documents 優先
- モデル構成: `qwen_embeddings.mlmodelc/` + `qwen_FFN_PF_lut6.mlmodelc/` + `qwen_lm_head_lut6.mlmodelc/` + `tokenizer.json`（合計約 300MB）
- 3モデルは同一 weight.bin を共有（CloudKit 配布時は1セットのチャンクを3モデルの weights/ にコピー）
- モデルは CloudKit Public Database から配布。weight.bin は CKAsset 上限（250MB）超の場合チャンク分割保存
- 開発時のモデル差し替え: Finder → iPhone → eMeishi の Documents/LocalLLM/ にフォルダごと配置
- CloudKit Container の設定・レコード作成・ファイルアップロードは Xcode / CloudKit Dashboard で手動実施
- CSV は Excel での文字化けを防ぐため UTF-8 BOM を付与（設定で無効化可能）
- vCard は 3.0 形式（設定で 4.0 に変更可能）
- 重複判定は名前70%・会社名30%の重み付きスコア
- **HIG（Human Interface Guidelines）を参照する際は、まず sosumi MCPサーバーを使う。** `searchAppleDocumentation` で検索 → `fetchAppleDocumentation` で詳細取得（パス例：`design/human-interface-guidelines/foundations/color`）。必要に応じて `fetchAppleVideoTranscript` で関連WWDCセッションも参照
- **App Store スクリーンショット撮影前に必ず `./scripts/shots-preflight.sh` を実行する。** シミュレータ shutdown → Dynamic Island 抑制（`SBSuppressDynamicIslandCompletely=true`）→ boot → ステータスバー固定（9:41・満充電・Wi-Fi 最大）を一括で行う。対象デバイスを絞る場合は `./scripts/shots-preflight.sh iphone` / `./scripts/shots-preflight.sh ipad`。UDID は `.asc/shots.settings.json` の `devices` から読む。撮影は `xcrun simctl io $UDID screenshot --mask=ignored` で取得すること
