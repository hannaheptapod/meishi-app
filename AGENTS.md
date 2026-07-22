# AGENTS.md — eMeishi 開発ルール

> プロジェクト概要・技術スタック・ディレクトリ構成・実装済み機能・AI 処理の構成は [README.md](README.md) を参照。本ファイルは Codex 向けのルールのみを記載する。

## 🚫 ビルド・アップロード前チェックリスト（必須・違反禁止）

**アーカイブ・アップロードは事前精査なしに絶対実行しない。**

### Step 1: 事前チェックスクリプトを実行

```bash
./scripts/pre-build-check.sh
```

全項目 **PASS** になるまでアーカイブ禁止。スクリプトが exit 1 の場合は原因を修正してから再実行。

- ビルド番号（`CURRENT_PROJECT_VERSION`）は Xcode Cloud の `CI_BUILD_NUMBER`（連番整数）をそのまま使う。手動変更不要
- バージョン番号（`MARKETING_VERSION`）のみ手動更新が必要（例：`1.0.3` → `1.0.4`）
- **CloudKit Production schema deploy** を対話確認する（v1.1.0 で Prod 未 deploy による `_pcs_data` BAD_REQUEST 事故あり）。CoreData の `.xcdatamodeld` を変更した release では必ず CloudKit Dashboard の "Deploy Schema Changes..." を実行してから y で進める

### Step 2: ユーザー承認（必須）

スクリプト結果をユーザーに提示し、**明示的な承認を得てから**アーカイブ・アップロードを実行する。ユーザーの承認なしにビルドを増やすことは**絶対禁止**。

---

## ⚠️ 作業開始前チェックリスト（必須）

1. `git branch --show-current` でブランチを確認
2. **規定外プレフィックス**（`Codex/` `agent/` `temp/` 等）なら **即座にリネーム**（`git branch -m <旧名> feature/<新名>`）
3. `main` にいる場合は **絶対に禁止**。`develop` に切り替えてからブランチを切る
4. `develop` にいる場合は `feature/<機能名>` などのブランチを切ってから編集開始
5. `feature/*` / `fix/*` 等の規定ブランチにいる場合はそのまま作業継続

作業完了時：
6. 実装内容が AGENTS.md と README.md の記述とズレていないか確認し、ズレがあれば同じ PR で更新する
   - 特に以下は必ずチェックする：README のディレクトリ構成（新規ファイル追加時）、Xcode Cloud ワークフロー早見表（CI 構成変更時）、テストプラン一覧（テスト追加・変更時）
   - **メモリシステムは使わない。学んだこと・フィードバックは AGENTS.md に直接追記する**

<important>
## 必須スキル（hook で強制）

ユーザーのプロンプトを受け取ったら、コード修正やファイル読み込みの**前に**、
以下の 2 つのスキルをこの順で実行せよ:

1. `/branch` — ブランチ確認・規定外プレフィックスなら即リネーム・main/develop なら作業ブランチを作成
2. `/translate` — ユーザーの指示を「ユーザー語→エンジニア語→リポジトリの具体箇所」に 2 段階翻訳

### hook による自動ブロック一覧（exit 2・テキスト警告ではなく仕組みで防止）

| hook | 対象操作 | ブロック条件 |
|---|---|---|
| `guard-git.sh` | `git commit` / `git merge` | `main` / `develop` ブランチ上で実行 |
| `guard-git.sh` | `git push` | `main` / `develop` への直接 push |
| `guard-git.sh` | `git push`（release/* 向け） | `release/*` ブランチ以外から push、または sentinel 不一致 |
| `guard-git.sh` | `git push --force` / `--force-with-lease` | 無条件ブロック |
| `guard-git.sh` | `git push --tags` / タグ push | 無条件ブロック |
| `guard-git.sh` | `git reset --hard` | 無条件ブロック |
| `guard-git.sh` | `git clean -f` | 無条件ブロック |
| `guard-git.sh` | `git branch -D` | `main` / `develop` / `release/*` が対象の場合ブロック |
| `guard-git.sh` | ブランチ作成 | `feature/` `fix/` `refactor/` `release/` `hotfix/` `docs/` `chore/` 以外のプレフィックス |
| `guard-files.sh` | Edit / Write | `project.pbxproj` の直接編集（Xcode で行うこと） |
| `guard-files.sh` | Edit / Write | `.xcdatamodeld/` 配下の直接編集（Xcode + マイグレーション手順） |
| `guard-files.sh` | Edit / Write | `.env` / `.p8` / `secrets/` / `private/` への書き込み |
</important>

---

## ブランチ・PR 戦略（Git Flow・厳守）

```
main       本番リリース済み。gh release create でタグ・GitHub Release を作成
develop    次リリースの統合ブランチ。常に動作する状態を保つ
feature/*  1 機能 1 ブランチ。develop から分岐し develop へ PR
fix/*      バグ修正。develop から分岐し develop へ PR
refactor/* 挙動変更なしのコード構造改善。develop から分岐し develop へ PR
release/*  App Store 提出前の最終調整のみ。機能追加禁止
hotfix/*   本番緊急修正。main から分岐し main と develop 両方へマージ
docs/*     ドキュメント更新
chore/*    ビルド設定・依存関係等
```

- **ブランチ名プレフィックスは上記 7 種のみ許可。** 規定外（`Codex/` 等）は `/branch` スキルで**即座にリネーム**する
- **main・develop への直接 push・commit は絶対禁止。** `.Codex/hooks/guard-git.sh` が自動ブロック（exit 2）する
- **PR は機能単位でまとめる。** 無関係な変更を混在させない
- **本プロジェクトで使う skill は 5 個のみ**: `/branch`・`/translate`（hook 強制）、`asc-shots-pipeline`・`asc-whats-new-writer`・`asc-release-flow`（リリース手順）

### 役割分担

| 担当 | 範囲 |
|---|---|
| **Codex** | ブランチ作成・実装・コミット・push・PR 作成・CI 失敗時の修正 |
| **ユーザー** | CI 確認・PR マージ・ブランチ削除・App Store 提出最終判断 |
| **Xcode Cloud** | PR Validation / Develop Integration / Release Build を自動実行 |

**Codex は PR を作成したらそこで手を止める。マージは絶対に自律実行しない。**

**PR の作成・クローズ・再作成は、ユーザーの明示的な指示があるまで実行しない。** 自分のミスを修正する目的であっても、PR 操作の前に必ずユーザーに確認する。

---

### フェーズ 1: 日常開発フロー

```
develop
  └─[Codex] feature/<機能名> ブランチ作成
       ├─[Codex] 実装・コミット・push
       ├─[Codex] PR 作成（base: develop）
       ├─[Xcode Cloud] PR Validation 自動起動（Build + Test）
       ├─[ユーザー] CI 結果確認 → PR マージ
       ├─[Xcode Cloud] Develop Integration 自動起動（Build + Test）
       └─[ユーザー] ブランチ削除（ローカル・リモート）
```

---

### フェーズ 2: リリース準備（TestFlight 検証ループ）

```
develop
  └─[Codex]     1. release/<x.y.z> ブランチ作成（develop から分岐）
  └─[ユーザー]   2. MARKETING_VERSION を手動更新（Xcode → Target → General → Version）
  └─[Codex]     3. ./scripts/pre-build-check.sh 実行・全 PASS を確認
  └─[Codex]     4. 結果をユーザーに提示し、明示的な承認を得る
  └─[Codex]     5. commit → push（`guard-git.sh` が sentinel 確認: pre-build-check.sh PASS 後の HEAD と一致必須）
  └─[Xcode Cloud] 6. Release Build 自動起動（Archive → TestFlight 配信）
  └─[ユーザー]   7. TestFlight で動作確認
  └─[両者]       8. 問題あり → 修正 commit → push（手順 5 に戻る）
                    ※合格ビルドが決まるまで 5〜7 を繰り返す。
                      push のたびに Archive が走り、ビルド番号が進む。
```

> **release/\* への push は「ASC 提出前」なら何回でも可。** TestFlight 検証で bug が見つかったら普通に修正 commit を積んで push する。合格ビルドが決まった時点（= ASC 提出開始時点）が境界線。**提出後は取り下げない限り push 禁止**（詳細はフェーズ 5）。

### フェーズ 3: メタデータ準備（Xcode Cloud は動かない）

```
develop
  └─[Codex]    1. chore/release-<x.y.z>-metadata ブランチ作成
  └─[Codex]    2. metadata/version/<x.y.z>/ja.json に What's New を記載
  └─[Codex]    3. （UI 変更があれば）./scripts/shots-preflight.sh → スクリーンショット撮影
  └─[Codex]    4. commit → push → PR（base: develop）
  └─[Xcode Cloud] 5. PR Validation 自動起動
  └─[ユーザー]  6. CI 確認 → マージ
  └─[Xcode Cloud] 7. Develop Integration 自動起動
```

> **メタデータは build に無関係なので `release/*` に載せない。** develop 側で管理することで `release/*` の Archive に影響させない。

### フェーズ 4: ストア提出（Xcode Cloud は動かない）

```
  └─[Codex] 1. asc release stage --copy-metadata-from <前バージョン> --exclude-fields whatsNew --build <合格ビルドID> --confirm
  └─[Codex] 2. asc localizations update --version <id> --locale ja --whats-new "..."
  └─[Codex] 3. （UI 変更があれば）スクリーンショットを ASC にアップロード
  └─[Codex] 4. asc validate --app <id> --version <x.y.z> で readiness 確認
  └─[Codex] 5. asc review submissions-create → items-add → submissions-submit --confirm
```

> **ここから release/<x.y.z> へは絶対 push しない。** 提出済みバージョンには差し替えできないため、新ビルドが生まれても宙に浮く。

### フェーズ 5: 審査中の修正（Reject 対応・提出後のバグ発見）

```
  └─[Codex]   1. asc review submissions-update --canceled=true で提出取り下げ
  └─[Codex]   2. 修正 commit → release/<x.y.z> に push
  └─[Xcode Cloud] 3. Release Build 自動起動（新ビルド生成）
  └─[ユーザー] 4. TestFlight で再検証
  └─[両者]     5. フェーズ 3〜4 をやり直し
```

> **提出後の push は必ず「取り下げ → push → 再提出」のセットで行う。** 取り下げずに push すると宙ぶらりんのビルドが生まれるだけ。

### フェーズ 6: 後片付け（審査通過後）

```
  └─[Codex]   1. release/<x.y.z> → main に PR 作成
  └─[ユーザー] 2. PR マージ
  └─[Codex]   3. release/<x.y.z> → develop に PR 作成
  └─[ユーザー] 4. PR マージ
  └─[Xcode Cloud] 5. Develop Integration 自動起動
  └─[Codex]   6. GitHub Releases 作成（gh release create vX.Y.Z --generate-notes --target main）
               ※ タグは gh release create が自動作成するため git tag 不要
  └─[ユーザー] 7. release ブランチ削除（ローカル・リモート）
```

> **バージョン番号（MARKETING_VERSION）のみ手動更新。** Xcode → Target → General → Version フィールドで変更する（`project.pbxproj` を Codex が直接編集しないため）。ビルド番号（CURRENT_PROJECT_VERSION）は Xcode Cloud が `CI_BUILD_NUMBER`（連番）を自動注入するため、手動変更不要。

---

### フェーズ 7: 緊急修正フロー（hotfix・本番障害対応）

```
main
  └─[Codex]    1. hotfix/<内容> ブランチ作成（main から分岐）
  └─[ユーザー]  2. MARKETING_VERSION をパッチ更新（例: 1.0.4 → 1.0.5）
  └─[Codex]    3. 修正 commit → push → PR（base: main）
               ※ PR Validation は main 向け PR では自動起動しない
  └─[ユーザー]  4. PR マージ → main へ取り込み
  └─[ユーザー]  5. hotfix → release/<x.y.z> として扱うか別途 release/ 分岐して Archive を起動
  └─[両者]      6. フェーズ 3〜6 と同じ流れで提出・公開
  └─[Codex]    7. hotfix/<内容> → develop への PR 作成
  └─[ユーザー]  8. PR マージ
  └─[ユーザー]  9. ブランチ削除（ローカル・リモート）
```

---

### Xcode Cloud ワークフロー早見表

| ワークフロー | トリガー | アクション | Codex の対応 |
|---|---|---|---|
| PR Validation | PR → `develop` | Build + Test | PR 作成で自動起動。CI 失敗なら修正して再 push |
| Develop Integration | push → `develop` | Build + Test | マージ後に自動起動。失敗はユーザーに報告 |
| Release Build | push → `release/*` | Archive + TestFlight 配信 | push で自動起動。**ASC 提出後は禁止** |

### 絶対ルール

1. **`release/*` への push は Archive + TestFlight 配信を必ず起動する。** ASC 提出前は何回 push してもよいが、提出後は `asc review submissions-update --canceled=true` で取り下げない限り push 禁止
2. **メタデータのみの変更は `release/*` に載せない。** build に無関係なので `chore/release-*-metadata` ブランチで develop に流す
3. **main・develop への直接 commit/push は hook がブロック。** 例外なし

---

## CoreData スキーマ変更時の注意

- 現在のモデルは `BusinessCard 5.xcdatamodel`（v5）。属性詳細は `.xcdatamodeld` を直接参照
- 軽量マイグレーション（`NSMigratePersistentStoresAutomaticallyOption` + `NSInferMappingModelAutomaticallyOption`）で v1 → v5 を自動対応
- スキーマ変更時は `.xcdatamodeld` に新バージョンを追加し、軽量マイグレーション可能な変更（属性追加・省略可能化など）に留める。破壊的変更は Custom Migration が必要

---

## コーディング規約

### 個人情報・テストデータ

- ユーザーが提示した名刺画像、スクリーンショット、ログ、OCR結果、連絡先から得た氏名・読み・会社・部署・役職・住所・電話番号・メールアドレス・URLを、回答例、ソースコード、テスト、fixture、スナップショット、文書、コメント、コミットメッセージへ転用しない
- 不具合の再現テストは、実データそのものではなく問題の構造だけを抽出し、予約済みドメインと明示的な架空値から新しく作った合成データを使う
- ユーザー提供の画像・PDF・vCard・CSVをリポジトリへ追加しない。画像が必要なテストはテスト内で図形と架空文字から生成する
- `./scripts/check-test-fixture-privacy.sh` を変更完了時に実行する。`pre-build-check.sh`でも同じ検査を強制する
- 個人情報を含む入力は、その場の不具合解析以外の目的で再利用・引用しない

- Swift 命名規則：型は UpperCamelCase・変数は lowerCamelCase
- SwiftUI View は単一責任・1 ファイル 1 View を基本
- ViewModel は `ObservableObject` に準拠し `@Published` でプロパティを公開
- CoreData の操作は ViewModel に閉じ込め、View から直接操作しない
- エラーハンドリングは `do-catch` で明示的に行う
- サービスクラス（`ExportService`・`ContactsService`・`LocalLLMService` など）は `static let shared` シングルトンパターンを使用
- `CardListViewModel` は `NavigationStack` レベルで `.environmentObject(viewModel)` を注入し、子 View は `@EnvironmentObject` で受け取る
- ViewModel のエラーは `@Published var errorMessage: String?` に集約し、View 側で Alert として表示する
- 検索フィルタ・エクスポート・一括削除などのビジネスロジックは View ではなく ViewModel に置く
- 日本語コメントで処理内容を記述してよい

### Swift 6 / actor isolation ルール（Issue #147 Phase 6/7 で確定）

- **`SWIFT_VERSION = 6.0` / `SWIFT_STRICT_CONCURRENCY = complete` は `pre-build-check.sh` で強制**（ダウングレード禁止）
- **サービス・ViewModel は `@MainActor` を型レベルで明示**する（例：`@MainActor final class ExportService: ObservableObject`）。メソッド単位の `@MainActor` は避ける
- **並行ワーカーは `actor`** を使う（`OCRService` など）。MainActor 外の計算で UI 更新が必要な場合は呼び出し側で `await MainActor.run` を書かず、戻り値を `@MainActor` 側の caller で受け取る形にする
- **`static let shared` は `@MainActor static let shared`** に統一（クラス全体が `@MainActor` なら省略可）
- **`await MainActor.run {}` / `DispatchQueue.main.async {}` は原則禁止**。actor isolation で表現する
- **`nonisolated(unsafe)` は最終手段**。使う場合はコメントで理由を必ず残す（例：`AppLogger` は iOS 26 SDK の `Logger.init @MainActor` 推論回避のため）
- **`@preconcurrency import` は最小限**。現状は `LocalLLMService` の `CoreML` のみ（`MLModel.prediction(from:)` の sending 警告回避・Apple が Sendable 化したら除去予定）
- **`NotificationCenter` の observer クロージャは `@Sendable`**（[PersistenceController.swift:194,207](eMeishi/App/PersistenceController.swift:194) 参照）。UI 更新が必要なら内部で `Task { @MainActor in ... }` を使う
- **Sendable DTO**: View / ViewModel / Service 境界を越えるデータは `struct` で `Sendable` 準拠にする（[BusinessCardSnapshot](eMeishi/Models/BusinessCardSnapshot.swift) などを参照）。`NSManagedObject` を直接渡さない

---

## 権限・Info.plist

- Debug ビルドは `eMeishi/Info-Debug.plist`（`UIFileSharingEnabled=true`・開発用モデル転送）、Release ビルドは `eMeishi/Info.plist`（`false`）。`Config/Debug.xcconfig`・`Config/Release.xcconfig` の `INFOPLIST_FILE` でビルド構成ごとに自動切替されるため、手動で戻す必要はない
- 必須の使用目的説明：`NSCameraUsageDescription`・`NSContactsUsageDescription`・`NSFaceIDUsageDescription`・`NSPhotoLibraryUsageDescription`
- `LSSupportsOpeningDocumentsInPlace`：`false`（本番ビルド）
- CloudKit Capability + Background Modes（Remote notifications）は Xcode で手動設定

---

## 開発者メモ（罠・注意点）

- **Xcode プロジェクトファイル（.xcodeproj）は Codex が直接編集しない（`project.pbxproj` は `guard-files.sh` がブロック）。** Xcode 16 の File System Synchronized Groups により、`eMeishi/` 配下に Swift ファイルを追加すれば自動的にビルド対象になる
- **Blitz が `.Codex/rules/blitz.md`・`.Codex/rules/teenybase.md`・`.Codex/agents/reviewer.md`・`.Codex/skills/asc-*/`・`.agents/`・`backend/` を起動ごとに上書き再生成する。** いずれも `.gitignore` で透明化してあるため `git status` に出なければ正常。Teenybase は本アプリで不使用（`backend/` のコードを一切 import していない）なので再生成されても放置して良い
- Foundation Models はシミュレータで動作しない（実機 iPhone 15 Pro 以降 + Apple Intelligence 有効が必要）
- Anemll Qwen3-0.6B-ctx512 はシミュレータでも動作するが低速（ANE 不使用・CPU 推論）
- `LocalLLMService` のモデル検索パス: ① `Documents/LocalLLM/`（開発用・Finder/iTunes 転送）→ ② `Application Support/LocalLLM/`（CloudKit DL）。Documents 優先
- モデル構成: `qwen_embeddings.mlmodelc/` + `qwen_FFN_PF_lut6.mlmodelc/` + `qwen_lm_head_lut6.mlmodelc/` + `tokenizer.json`（合計約 300MB）。3 モデルは同一 weight.bin を共有（CloudKit 配布時は 1 セットのチャンクを 3 モデルの `weights/` にコピー）
- モデルは CloudKit Public Database から配布。weight.bin は CKAsset 上限（250MB）超の場合チャンク分割保存
- 開発時のモデル差し替え: Finder → iPhone → eMeishi の `Documents/LocalLLM/` にフォルダごと配置
- CloudKit Container の設定・レコード作成・ファイルアップロードは Xcode / CloudKit Dashboard で手動実施
- CSV は Excel での文字化けを防ぐため UTF-8 BOM を付与（設定で無効化可能）・vCard は 3.0 形式（設定で 4.0 に変更可能）・重複判定は名前 70%・会社名 30% の重み付きスコア
- **HIG（Human Interface Guidelines）を参照する際は、まず sosumi MCP サーバーを使う。** `searchAppleDocumentation` で検索 → `fetchAppleDocumentation` で詳細取得（パス例：`design/human-interface-guidelines/foundations/color`）。必要に応じて `fetchAppleVideoTranscript` で関連 WWDC セッションも参照
- **回答前に必ず一次情報を確認する。** スクリーンショット・ファイル・ログが提示されている場合はまず読む。カットオフ（2025年8月）以降の情報が含まれる可能性がある場合は WebSearch で確認してから答える。確認手段があるのに使わずに記憶だけで断言することは絶対禁止。
- **App Store スクリーンショット撮影前に必ず `./scripts/shots-preflight.sh` を実行する。** シミュレータ shutdown → Dynamic Island 抑制（`SBSuppressDynamicIslandCompletely=true`）→ boot → ステータスバー固定（9:41・満充電・Wi-Fi 最大）を一括で行う。対象デバイスを絞る場合は `./scripts/shots-preflight.sh iphone` / `./scripts/shots-preflight.sh ipad`。UDID は `.asc/shots.settings.json` の `devices` から読む。撮影は `xcrun simctl io $UDID screenshot --mask=ignored` で取得すること

## Billing / StoreKit 2 運用ルール

- **Billing モジュール構成**: `Services/Billing/`（StoreService / EntitlementStore / GrandfatherStore / AppTransactionProviding / ExistingUserDetector / ProductIdentifier / PaywallContext）・`Views/Billing/`（PaywallView / PaywallFeatureListView / ManageSubscriptionButton）
- **Product ID**: `com.emeishi.pro.monthly`（¥500/月）・`com.emeishi.pro.yearly`（¥3,200/年・7日間無料トライアル付）。変更時は `ProductIdentifier.swift` と `Configuration.storekit` を同時更新する
- **EntitlementStore.hasAccess**: `hasPro || isGrandfathered` で Pro ゲートを判定する。View から直接 `hasPro` を参照しない
- **GrandfatherStore**: Pro リリース前から使っていたユーザーに永続無料アクセスを付与。1.0.x には記録コードが存在しない前提のもと、優先度順に①UserDefaults pin → ②iCloud KVS pin → ③`AppTransaction.originalAppVersion` → ④CoreData/UserDefaults 痕跡（ExistingUserDetector）→ ⑤現バージョン pin（新規扱い）の 5 段で判定する。pin は UserDefaults + iCloud KVS の両方に書き込む
- **ローカルテスト**: `Configuration.storekit` を Xcode Scheme の StoreKit Configuration に設定して Sandbox 不要でテストできる。Simulator で購入フローを通す場合はこのファイルを必ず使う
- **Transaction 監視**: `StoreService.startTransactionListener()` は `eMeishiApp.init` ではなく `.task {}` 内から起動する（MainActor 制約）
- **Paywall から遷移する画面は `EntitlementStore` を `.environmentObject()` で渡す**こと。`@EnvironmentObject` でないと実行時クラッシュになる
- **Pro ゲート対象**: AI 自然言語検索（`CardListView.openAISearch`）／AI 重複検出（`CardListViewModel.detectDuplicates` の AI 二次判定）／AI 一括リタグ（`BulkTagAssignView` + `CardListViewModel.bulkAutoTag`）／Insights AI 解釈（`InsightsView` + `InsightsService.generateNarrative`）。いずれも `EntitlementStore.shared.hasAccess` で判定し、未加入時は `PaywallView` シートで案内する
- **PR 作成前にローカルテストを実行すること**（`xcodebuild test -scheme eMeishi -destination 'platform=iOS Simulator,name=iPhone 17'`）

### バージョン境界・ブートストラップ問題の教訓（v1.1.0 Grandfather 欠陥）

- **過去バージョンのユーザーを特別扱いするロジックは、境界の両側のコードを読んで「過去バージョンに何が書かれていたか／書かれていなかったか」を必ず `git show` / 旧タグ checkout で確認する**
  - Why: 1.1.0 の `GrandfatherStore` で、1.0.x 側に `firstLaunchMarketingVersion` を書き込むコードが存在しないことを見落とし、結果として 1.0.x → 1.1.0 アップデート時に既存ユーザー全員が Grandfather から外れる欠陥を本番直前まで通した
  - How to apply: `firstLaunch*` / `installVersion` / `migrationVersion` などの「永続化された境界マーカー」を参照する実装は、必ずマーカーが書き込まれる経路（誰がいつ書くか）を旧コードで grep してから書く
- **サブエージェントの "コード一致確認" 報告は鵜呑みにしない。Critical パス（課金・認証・判定ロジック）は必ずメインエージェントが実ファイルを Read する**
  - Why: Explore subagent の「`proReleaseVersion = "1.1.0"` で OK ✓」の報告だけを信用し、`evaluate()` 本体に欠陥があったことを見抜けなかった
  - How to apply: 課金・認証・グランドファザー判定など金銭・アクセス制御に直結するコードは、subagent の要約だけで判断せず、必ず該当ファイルを Read してロジック全体を読む
- **CloudKit schema は Dev → Production の deploy が手動。リリース前に Dashboard で deploy する**
  - Why: 1.1.0 で Production に mirroring 用 Record Type（CDMR / CD_BusinessCard / CD_Tag / GrandfatherMark）が未 deploy のまま TestFlight 配信し、全ユーザーで `_pcs_data BAD_REQUEST` → iCloud 同期完全停止となった。ローカル CoreData 変更や `.xcdatamodeld` の新版追加だけでは Production には反映されず、アプリ再インストールでも解消しない
  - How to apply: `./scripts/pre-build-check.sh` の "CloudKit Production schema deploy" ステップで対話確認する。CoreData スキーマを変更した release では必ず CloudKit Dashboard → Development → "Deploy Schema Changes..." を実行し、Production 側 Record Types タブに反映されたことを確認してから y で進める
