# eMeishi

iPhoneで名刺をスマートに管理するアプリ。カメラで撮影するだけで、AIが名前・会社名・連絡先を自動で読み取り、整理して保存します。

## 主な機能

- **カメラ／写真ライブラリ + AI自動読み取り** — OCR + オンデバイスAI（Apple Intelligence / Qwen3-0.6B）で名刺のフィールドを自動分類。連続撮影と写真の最大10枚取込みに対応
- **バックグラウンド読み取り** — 処理段階・推定残り時間を表示し、Dynamic Island／システムLive Activityから進捗を確認可能
- **ふりがな自動生成** — 名前・会社名のふりがなを自動取得。名前順・会社名順ソートに使用
- **連絡先連携** — iPhoneの連絡先へワンタップ保存、連絡先からのインポート
- **CSV / vCard エクスポート** — Excel対応のCSV（UTF-8 BOM付き）、vCard 3.0/4.0
- **重複検出 + マージ** — Levenshtein距離ベースの類似度判定 + AIによるボーダーライン二次判定
- **タグ管理** — ユーザー定義タグ（名前・色・並べ替え）で自由にグループ分け
- **AI自然言語検索** — 「先月会った渋谷のエンジニア」のような自然文で名刺を検索
- **人脈インサイト** — 会社別・エリア別・職種別・月別の統計
- **セキュリティ** — Face ID / Touch ID によるアプリロック、App Switcherでのコンテンツ隠蔽
- **iCloud同期**（オプション） — 同じApple IDのデバイス間で名刺・タグを自動同期

## プライバシー

すべてのAI処理はデバイス上で実行されます。開発者が運営する外部サーバーへのデータ送信は一切ありません。iCloud同期はオプトイン方式で、CloudKit Private Databaseに保存されたデータは開発者を含む第三者が閲覧できません。

## 技術スタック

| 項目 | 技術 |
|------|------|
| UI | SwiftUI |
| データ永続化 | CoreData + NSPersistentCloudKitContainer |
| OCR | Vision Framework（RecognizeTextRequest / DetectRectanglesRequest） |
| AI分析（Apple Intelligence対応端末） | Foundation Models（iOS 26+） |
| AI分析（非対応端末） | Qwen3-0.6B Anemll CoreML（Embed+FFN+LMHead 3モデル・ANE対応） |
| カメラ | UIKit UIImagePickerController（標準カメラUI + オーバーレイ） |
| 写真取込み | PhotosUI PhotosPicker（順序付き・最大10枚） |
| バックグラウンド処理 | BackgroundTasks BGContinuedProcessingTask |
| 連絡先 | Contacts Framework |
| 生体認証 | LocalAuthentication |
| モデル配布 | CloudKit Public Database |

## アーキテクチャ（AI 処理の流れ）

```mermaid
flowchart TD
  A[カメラ撮影 / 写真ライブラリ] --> B[OCR<br/>Vision Framework<br/>RecognizeTextRequest / .accurate<br/>textDirection<br/>ja-JP, en-US]
  B --> C[ハイブリッド前段処理 常時・LLM 不使用<br/>CardFieldClassifier.classifyStructuredFields]
  C --> C1[Pass1: 正規表現で email・phone・URL・住所・会社・部署・役職を抽出]
  C --> C2[Pass2: 座標ベース名前スコアリング<br/>フリガナ近接・フォントサイズ・位置]
  C2 --> D{未分類行あり?}
  D -- Yes --> E[LLM 分類 排他選択]
  E --> E1[Apple Intelligence 端末<br/>Foundation Models<br/>@Generable + @Guide で ParsedCard 構造化]
  E --> E2[非対応端末<br/>Qwen3-0.6B Anemll CoreML<br/>Embed + FFN + LMHead 3モデル<br/>stateful KV cache / LUT6 / ANE<br/>1行1回の単一パス分類]
  D -- No --> F
  E1 --> F[ハイブリッド後段処理<br/>残余行から会社・役職を補完]
  E2 --> F
```

ルールベースの抽出結果が常に LLM より優先されます。LLM エンジンは排他利用（フォールバック連鎖なし）です。

## ディレクトリ構成

```text
meishi-app/
├── CLAUDE.md
├── README.md
├── eMeishi/
│   ├── Info.plist                              # Release 用（UIFileSharingEnabled=false）
│   ├── Info-Debug.plist                        # Debug 用（UIFileSharingEnabled=true・開発用モデル転送）
│   ├── eMeishi.entitlements                    # CloudKit・iCloud 同期・アプリグループ等
│   ├── Config/
│   │   ├── Debug.xcconfig                      # INFOPLIST_FILE=Info-Debug.plist・SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG
│   │   └── Release.xcconfig                    # INFOPLIST_FILE=Info.plist・DEBUG 条件コード除外
│   ├── App/
│   │   ├── eMeishiApp.swift
│   │   └── PersistenceController.swift          # CoreData スタック・軽量マイグレーション設定
│   ├── Models/
│   │   ├── AppNavigationState.swift              # 一覧・めくる・インサイト・設定のNavigationPathと中央追加要求
│   │   ├── BusinessCard+CoreDataClass.swift
│   │   ├── BusinessCard+CoreDataProperties.swift
│   │   ├── Tag+CoreDataClass.swift
│   │   ├── Tag+CoreDataProperties.swift
│   │   ├── CardImageInput.swift                  # カメラ・写真取込み共通のSendable画像DTO
│   │   └── OCRProcessingState.swift              # OCR段階・進捗・ETA状態
│   ├── ContentView.swift                        # 標準TabViewによる一覧・めくる・中央追加・インサイト・設定
│   ├── Views/
│   │   ├── CardListView.swift
│   │   ├── CardBrowseView.swift                # 名刺画像を左右にめくるリッチ閲覧モード
│   │   ├── CardDetailView.swift
│   │   ├── CardFormView.swift
│   │   ├── CameraView.swift                    # 連続撮影カメラ（CameraBatchCapture・純UIKit管理・標準カメラUI+オーバーレイ）
│   │   ├── BatchReviewView.swift               # 連続撮影後の一括確認（CardFormViewを順番に表示）
│   │   ├── AISearchChatView.swift              # AI自然言語検索のチャットUI
│   │   ├── Billing/
│   │   │   ├── PaywallView.swift               # Pro 購入・復元・機能紹介シート（コンテキスト別）
│   │   │   ├── PaywallFeatureListView.swift    # Pro 機能一覧（現在コンテキストを先頭表示）
│   │   │   └── ManageSubscriptionButton.swift  # App Store サブスクリプション管理画面を開くボタン
│   │   ├── DuplicateListView.swift              # 重複候補一覧
│   │   ├── DuplicateMergeView.swift             # マージUI
│   │   ├── BulkTagAssignView.swift             # 一括タグ付けシート（選択モード用）
│   │   ├── TagManagementView.swift             # タグ管理（作成・削除・色変更・並べ替え）
│   │   ├── LockScreenView.swift                # 生体認証ロック画面
│   │   ├── PrivacyOverlayView.swift            # App Switcher プライバシーオーバーレイ
│   │   ├── InsightsView.swift                  # 人脈インサイト（会社別・エリア別・職種別・月別統計）
│   │   ├── SettingsView.swift                  # 読み取り方法・エクスポート設定・セキュリティ・モデル管理・プライバシーポリシー/サポートリンク
│   │   └── Components/
│   │       ├── CardRowView.swift               # 一覧行セル
│   │       ├── CardThumbnailView.swift          # 中央配置・非クロップの名刺画像
│   │       ├── DesignSystemComponents.swift    # 共通サーフェス・情報行・画像・OCR進捗・メトリクス
│   │       ├── CardPeekView.swift              # コンテキストメニュー専用の読み取り専用プレビュー
│   │       └── SectionIndexView.swift          # 50音セクションインデックス
│   ├── ViewModels/
│   │   ├── CardListViewModel.swift
│   │   ├── CardFormViewModel.swift
│   │   └── SettingsStore.swift                 # UserDefaults ラッパー・ReadingMethod enum
│   ├── Services/
│   │   ├── Billing/
│   │   │   ├── StoreService.swift              # StoreKit 2 商品取得・購入・復元・Transaction 監視
│   │   │   ├── EntitlementStore.swift          # hasPro / isGrandfathered / hasAccess を @Published 管理
│   │   │   ├── GrandfatherStore.swift          # Pro リリース前ユーザーへの永続無料アクセス判定（AppTransaction + ローカル痕跡フォールバック）
│   │   │   ├── AppTransactionProviding.swift   # AppTransaction / iCloud KVS の Protocol 抽象化（テスト用差替え対応）
│   │   │   ├── ExistingUserDetector.swift      # 既存ユーザー痕跡（CoreData 名刺有無 / SettingsStore 書き込みキー）の判定
│   │   │   ├── ProductIdentifier.swift         # SKU 定数（proMonthly / proYearly）
│   │   │   └── PaywallContext.swift            # Paywall 表示コンテキスト（aiSearch / bulkRetag / insightsNarrative / duplicateAI）
│   │   ├── AuthenticationService.swift         # 生体認証（Face ID / Touch ID）ラッパー
│   │   ├── OCRService.swift
│   │   ├── PhotoImportService.swift             # PhotosPicker画像の順次ロード・正規化
│   │   ├── OCRProcessingCoordinator.swift       # OCR進捗・実測ETA・中断画像管理
│   │   ├── OCRBackgroundTaskManager.swift       # BGContinuedProcessingTask連携
│   │   ├── PendingOCRStore.swift                 # OCR再開キューの原子的な保存・復元
│   │   ├── CardThumbnailService.swift           # 64pt長辺基準の表示寸法計算
│   │   ├── ContactsService.swift
│   │   ├── ExportService.swift
│   │   ├── CloudKitModelService.swift          # CloudKit Public DB からモデルDL・Embed/FFN/LMHead 3モデル対応・weight チャンク結合
│   │   ├── CloudKitModelUploader.swift         # #if DEBUG 限定のモデルアップローダ（開発者向け）
│   │   ├── CloudKitEntitlementChecker.swift    # 署名entitlementとテスト環境のCloudKit利用可否判定
│   │   ├── ModelInstallService.swift            # 検証済みモデルの原子的置換・ロールバック
│   │   ├── LocalLLMService.swift               # Anemll Qwen3-0.6B ANE対応 CoreML 推論（Embed+FFN+LMHead）・stateful KV cache・Documents/AppSupport 二重パス
│   │   ├── LocalLLMInferenceWorker.swift        # Core MLモデル状態と推論を直列化するactor
│   │   ├── AISearchService.swift               # AI自然言語検索（時間表現抽出 + フィールド分類）
│   │   ├── AutoTagService.swift                # AI自動タグ提案（既存タグからカード内容に該当するものを提案）
│   │   ├── InsightsService.swift               # 人脈インサイト集計（会社別・エリア別・職種別・月別）
│   │   └── Qwen25Tokenizer.swift               # BPE トークナイザー（Qwen3互換）
│   ├── Utilities/
│   │   ├── AppLogger.swift                     # os.Logger ラッパー
│   │   ├── AppTheme.swift                      # ブランド色と非オレンジのグラフ配色
│   │   ├── CardFieldClassifier.swift           # 正規表現ベースのフィールド分類（ハイブリッド前段処理）
│   │   ├── CardGroupingService.swift           # 50音セクション分割
│   │   ├── ContactPatternExtractor.swift       # email/phone/URL/住所の正規表現抽出
│   │   ├── DuplicateChecker.swift              # Levenshtein 距離による重複判定
│   │   ├── ExternalURLNormalizer.swift          # WebサイトURLのhttps補完・許可スキーム判定
│   │   ├── FieldDetector.swift                 # OCR 行からフィールド種別の初期判定
│   │   ├── FlowLayout.swift                    # SwiftUI タグ折返しレイアウト
│   │   ├── LegalEntityTerms.swift              # 法人格リスト一元管理（漢字・読み・英語・略称）
│   │   ├── NameProcessor.swift                 # 名前の分割・正規化
│   │   ├── NameReadingGenerator.swift          # ふりがな自動生成（CFStringTokenizer）
│   │   └── ShareSheet.swift                    # UIActivityViewController ラッパー
│   ├── Resources/
│   │   └── BusinessCard.xcdatamodeld           # v1（初期）・v2（department追加）・v3（reading追加）・v4（isFavorite+Tag追加）・v5（Tag.sortOrder追加）の5バージョン
│   ├── AppIcon.icon/                           # アプリアイコン
│   └── Assets.xcassets                         # アクセントカラー
├── eMeishiTests/
│   ├── eMeishiTests.swift                      # 機能テスト（OCR・DuplicateChecker・ExportService・AutoTagService 等）
│   ├── CardListViewModelTests.swift            # CardListViewModel の検索・ソート・一括操作ロジック
│   ├── CardFormViewModelTests.swift            # CardFormViewModel の init・タグ操作・save() 正規化・OCR画像保存・キャンセル終了
│   ├── OCRServiceTests.swift                   # OCR 行結合（横書き・縦書き）の後処理テスト
│   ├── CardThumbnailServiceTests.swift         # 横長・縦長サムネイル寸法テスト
│   ├── CardGroupingServiceTests.swift          # CardGroupingService のセクション分割・グループ化
│   ├── ContactPatternExtractorTests.swift      # email/phone/URL 抽出の正規表現ロジック
│   ├── FieldDetectorTests.swift                # 会社/部署/役職/建物/住所/英語人名の判定
│   ├── InsightsServiceTests.swift              # InsightsService の会社別・エリア別・職種別・月別集計
│   ├── CloudKitModelUploadTests.swift          # CloudKit モデルアップロード（CI では自動スキップ）
│   └── Billing/
│       └── BillingTests.swift                  # GrandfatherStore・EntitlementStore・ProductIdentifier・PaywallContext
├── eMeishiUITests/
│   ├── eMeishiUITests.swift                    # UIテスト（コンテキストメニュー・選択モード・検索・ナビゲーション）
│   ├── eMeishiUITestsLaunchTests.swift         # 起動テスト
│   └── ScreenshotRunner.swift                  # App Store スクリーンショット撮影（CI では除外）
├── eMeishi-CI.xctestplan                           # CI 用テストプラン（ScreenshotRunner 除外）
├── eMeishi-Unit.xctestplan                         # PR Validation 用 Unit テストプラン（Unit テストのみ）
├── Configuration.storekit                          # StoreKit Configuration（Xcode テスト用・proMonthly/proYearly・Family Sharing 有効）
├── scripts/
│   ├── pre-build-check.sh                      # ビルド前検証（ビルド番号・Info.plist 整合性・権限）
│   ├── cloudkit-models.sh                      # 10MiB分割・再開・stable/rollback CLI
│   └── tests/cloudkit-models-test.sh           # CLIマニフェスト・チャンク検証
├── docs/                                       # GitHub Pages（プライバシーポリシー・サポート・ランディング）
├── metadata/                                   # App Store Connect メタデータ
│   ├── app_info.yaml                           # アプリ基本情報（カテゴリ・URL 等）
│   └── version/<x.y.z>/ja.json                 # バージョンごとの description・keywords・whatsNew
├── .asc/                                       # ASC 向け設定（screenshots.json・shots.settings.json）
├── screenshots/raw/{iphone69,ipad13}/          # App Store スクリーンショット（必要サイズのみ追跡）
└── ExportOptions.plist                         # xcodebuild 手動 export 用
```

## 要件

- iOS 26.0 以降
- Xcode 26.0 以降
- **Swift 6.0 言語モード**（`SWIFT_VERSION = 6.0` / `SWIFT_STRICT_CONCURRENCY = complete`）
- iPhone（実機推奨。シミュレータではAI機能が制限されます）

## ビルド

```bash
git clone https://github.com/hannaheptapod/meishi-app.git
cd meishi-app
open eMeishi.xcodeproj
```

Xcode でビルドターゲットを選択し、実機またはシミュレータで実行してください。

> **Note:** Foundation Models は iPhone 15 Pro 以降 + Apple Intelligence 有効の実機でのみ動作します。Qwen3-0.6B CoreML はシミュレータでも動作しますが低速です。

## CI/CD（Xcode Cloud）

| ワークフロー | トリガー | アクション | テストプラン |
|---|---|---|---|
| PR Validation | PR → `develop` | Build + **Test** | `eMeishi-Unit`（Unit テストのみ） |
| Develop Integration | push → `develop` | Build + **Test** | `eMeishi-CI`（Unit + UI テスト、ScreenshotRunner 除外） |
| Release Build | push → `release/*` | **Archive → TestFlight** | なし |

- Xcode Cloud の初期セットアップ済み（GitHub 連携・署名・App 確認）
- `ci_scripts/` にビルド番号自動生成・バリデーション・ログのスクリプト配置済み

### CI スクリプト構成

```
ci_scripts/
├── ci_post_clone.sh        # クローン後ログ（特別な処理なし）
├── ci_pre_xcodebuild.sh    # ビルド前バリデーション（Info.plist 整合性・xcconfig 等）
└── ci_post_xcodebuild.sh   # ビルド後ログ出力
```

- ビルド番号（`CURRENT_PROJECT_VERSION`）は Xcode Cloud が `CI_BUILD_NUMBER`（連番）を自動注入する。カスタム形式は使わない
- TestFlight 配信は Xcode Cloud の Release Build ワークフローの Distribution Preparation（App Store Connect）+ Post-Action（Internal Testing）で行う
- `ci_pre_xcodebuild.sh` は `scripts/pre-build-check.sh` の CI 版。asc CLI 依存の 3 項目（ビルド番号比較・証明書・プロファイル）はスキップ
- テストプラン `eMeishi-CI.xctestplan` は ScreenshotRunnerTests を除外（App Store スクリーンショット専用のため CI では不要）
- **`release/*` への push は必ず Archive + TestFlight 配信を起動する。** ASC 提出後は `asc review submissions-update --canceled=true` で取り下げない限り push 禁止
- **メタデータ（What's New・スクリーンショット等）の変更は `release/*` に載せず、`chore/release-*-metadata` ブランチで develop に流す**（build に無関係なため）

## ライセンス

[MIT License](LICENSE)
