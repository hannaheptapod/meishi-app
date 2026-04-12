# CLAUDE.md — eMeishi 開発ルール

> プロジェクト概要・技術スタック・ディレクトリ構成・実装済み機能・AI 処理の構成は [README.md](README.md) を参照。本ファイルは Claude Code 向けのルールのみを記載する。

## 🚫 ビルド・アップロード前チェックリスト（必須・違反禁止）

**アーカイブ・アップロードは事前精査なしに絶対実行しない。**

### Step 1: 事前チェックスクリプトを実行

```bash
./scripts/pre-build-check.sh
```

全項目 **PASS** になるまでアーカイブ禁止。スクリプトが exit 1 の場合は原因を修正してから再実行。

- ビルド番号は **`yyyymmddNNN`** 形式（NNN は 001 始まりの当日連番）
- 例：2026-04-09 の1本目 → `20260409001`、2本目 → `20260409002`

### Step 2: ユーザー承認（必須）

スクリプト結果をユーザーに提示し、**明示的な承認を得てから**アーカイブ・アップロードを実行する。ユーザーの承認なしにビルドを増やすことは**絶対禁止**。

---

## ⚠️ 作業開始前チェックリスト（必須）

1. `git branch --show-current` でブランチを確認
2. **規定外プレフィックス**（`claude/` `agent/` `temp/` 等）なら **即座にリネーム**（`git branch -m <旧名> feature/<新名>`）
3. `main` にいる場合は **絶対に禁止**。`develop` に切り替えてからブランチを切る
4. `develop` にいる場合は `feature/<機能名>` などのブランチを切ってから編集開始
5. `feature/*` / `fix/*` 等の規定ブランチにいる場合はそのまま作業継続

作業完了時：
6. 実装内容が CLAUDE.md と README.md の記述とズレていないか確認し、ズレがあれば同じ PR で更新する

<important>
## 必須スキル（hook で強制。違反時はユーザーが検知する）

ユーザーのプロンプトを受け取ったら、コード修正やファイル読み込みの**前に**、
以下の 2 つのスキルをこの順で実行せよ:

1. `/branch` — ブランチ確認・規定外プレフィックスなら即リネーム・main/develop なら作業ブランチを作成
2. `/translate` — ユーザーの指示を「ユーザー語→エンジニア語→リポジトリの具体箇所」に 2 段階翻訳

この 2 つを**スキップしてはならない**。hook の `<user-prompt-submit-hook>` メッセージでも同じ指示が届く。

**hook による自動ブロック（`.claude/hooks/guard-git.sh`）：**
- `main` / `develop` への直接コミット・マージ・push → **exit 2 でブロック**
- `feature/` `fix/` `release/` `hotfix/` `docs/` `chore/` 以外のプレフィックスでのブランチ作成 → **exit 2 でブロック**
</important>

---

## ブランチ・PR 戦略（Git Flow・厳守）

```
main       本番リリース済み。タグ（v1.0, v1.1）を打つ
develop    次リリースの統合ブランチ。常に動作する状態を保つ
feature/*  1 機能 1 ブランチ。develop から分岐し develop へ PR
fix/*      バグ修正。develop から分岐し develop へ PR
release/*  App Store 提出前の最終調整のみ。機能追加禁止
hotfix/*   本番緊急修正。main から分岐し main と develop 両方へマージ
docs/*     ドキュメント更新
chore/*    ビルド設定・依存関係等
```

- **ブランチ名プレフィックスは上記 6 種のみ許可。** 規定外（`claude/` 等）は `/branch` スキルで**即座にリネーム**する
- **main・develop への直接 push・commit は絶対禁止。** `.claude/hooks/guard-git.sh` が自動ブロック（exit 2）する
- **PR は機能単位でまとめる。** 無関係な変更を混在させない
- **本プロジェクトで使う skill は 5 個のみ**: `/branch`・`/translate`（hook 強制）、`asc-shots-pipeline`・`asc-whats-new-writer`・`asc-release-flow`（リリース手順）

### 役割分担

| 担当 | 範囲 |
|---|---|
| **Claude** | ブランチ作成・実装・コミット・push・PR 作成・CI 失敗時の修正 |
| **ユーザー** | CI 確認・PR マージ・ブランチ削除・タグ打ち・App Store 提出最終判断 |
| **Xcode Cloud** | PR Validation / Develop Integration / Release Build を自動実行 |

**Claude は PR を作成したらそこで手を止める。マージは絶対に自律実行しない。**

---

### フェーズ 1: 日常開発フロー

```
develop
  └─[Claude] feature/<機能名> ブランチ作成
       ├─[Claude] 実装・コミット・push
       ├─[Claude] PR 作成（base: develop）
       ├─[Xcode Cloud] PR Validation 自動起動（Build）
       ├─[ユーザー] CI 結果確認 → PR マージ
       ├─[Xcode Cloud] Develop Integration 自動起動（Build）
       └─[ユーザー] ブランチ削除（ローカル・リモート）
```

---

### フェーズ 2: リリースフロー

```
develop
  └─[Claude]    1. release/<x.y.z> ブランチ作成
  └─[Claude]    2. Info.plist バージョン・ビルド番号更新
  └─[Claude]    3. ./scripts/pre-build-check.sh 実行・全 PASS を確認
  └─[Claude]    4. 結果をユーザーに提示し、明示的な承認を得る
  └─[Claude]    5. push → PR 作成（base: develop）
  └─[Xcode Cloud] 6. Release Build 自動起動（Archive → TestFlight）
  └─[ユーザー]  7. Archive 成功・TestFlight 配信を確認
  └─[Claude]    8. スクリーンショット撮影（shots-preflight.sh → asc-shots-pipeline）
  └─[Claude]    9. What's New 更新（asc-whats-new-writer スキル）
  └─[Claude]   10. 提出前ヘルスチェック → 審査提出（asc-release-flow スキル）
  └─[ユーザー] 11. release/<x.y.z> → main への PR 作成・マージ
  └─[ユーザー] 12. release/<x.y.z> → develop への PR 作成・マージ
  └─[ユーザー] 13. main に vX.Y.Z タグを打つ
  └─[Claude]   14. GitHub Releases 作成（gh release create vX.Y.Z --generate-notes）
  └─[ユーザー] 15. release ブランチ削除（ローカル・リモート）
```

> ビルド番号は `yyyymmddNNN`（001 始まりの当日連番）。`ci_scripts/ci_post_clone.sh` が Xcode Cloud で自動設定。手動更新は `Info.plist` の `CURRENT_PROJECT_VERSION` を直接編集。

---

### フェーズ 3: 緊急修正フロー（hotfix）

```
main
  └─[Claude]    1. hotfix/<内容> ブランチ作成（main から分岐）
  └─[Claude]    2. 修正・コミット・push → PR 作成（base: main）
  └─[Xcode Cloud] 3. PR Validation 自動起動
  └─[ユーザー]  4. CI 確認 → main への PR マージ・タグ
  └─[ユーザー]  5. hotfix/<内容> → develop への PR 作成・マージ
  └─[ユーザー]  6. ブランチ削除（ローカル・リモート）
```

---

### Xcode Cloud ワークフロー早見表

| ワークフロー | トリガー | アクション | Claude の対応 |
|---|---|---|---|
| PR Validation | PR → `develop` | Build | PR 作成で自動起動。CI 失敗なら修正して再 push |
| Develop Integration | push → `develop` | Build | マージ後に自動起動。失敗はユーザーに報告 |
| Release Build | push → `release/*` | Archive | push で自動起動。失敗なら原因調査・修正 |

---

## CoreData スキーマ変更時の注意

- 現在のモデルは `BusinessCard 5.xcdatamodel`（v5）。属性詳細は `.xcdatamodeld` を直接参照
- 軽量マイグレーション（`NSMigratePersistentStoresAutomaticallyOption` + `NSInferMappingModelAutomaticallyOption`）で v1 → v5 を自動対応
- スキーマ変更時は `.xcdatamodeld` に新バージョンを追加し、軽量マイグレーション可能な変更（属性追加・省略可能化など）に留める。破壊的変更は Custom Migration が必要

---

## コーディング規約

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

---

## 権限・Info.plist

- Debug ビルドは `eMeishi/Info-Debug.plist`（`UIFileSharingEnabled=true`・開発用モデル転送）、Release ビルドは `eMeishi/Info.plist`（`false`）。`Config/Debug.xcconfig`・`Config/Release.xcconfig` の `INFOPLIST_FILE` でビルド構成ごとに自動切替されるため、手動で戻す必要はない
- 必須の使用目的説明：`NSCameraUsageDescription`・`NSContactsUsageDescription`・`NSFaceIDUsageDescription`・`NSPhotoLibraryUsageDescription`
- `LSSupportsOpeningDocumentsInPlace`：`false`（本番ビルド）
- CloudKit Capability + Background Modes（Remote notifications）は Xcode で手動設定

---

## 開発者メモ（罠・注意点）

- **Xcode プロジェクトファイル（.xcodeproj）は Claude Code が直接編集しない。** Xcode 16 の File System Synchronized Groups により、`eMeishi/` 配下に Swift ファイルを追加すれば自動的にビルド対象になる
- **Blitz が `.claude/rules/blitz.md`・`.claude/rules/teenybase.md`・`.claude/agents/reviewer.md`・`.claude/skills/asc-*/`・`.agents/`・`backend/` を起動ごとに上書き再生成する。** いずれも `.gitignore` で透明化してあるため `git status` に出なければ正常。Teenybase は本アプリで不使用（`backend/` のコードを一切 import していない）なので再生成されても放置して良い
- Foundation Models はシミュレータで動作しない（実機 iPhone 15 Pro 以降 + Apple Intelligence 有効が必要）
- Anemll Qwen3-0.6B-ctx512 はシミュレータでも動作するが低速（ANE 不使用・CPU 推論）
- `LocalLLMService` のモデル検索パス: ① `Documents/LocalLLM/`（開発用・Finder/iTunes 転送）→ ② `Application Support/LocalLLM/`（CloudKit DL）。Documents 優先
- モデル構成: `qwen_embeddings.mlmodelc/` + `qwen_FFN_PF_lut6.mlmodelc/` + `qwen_lm_head_lut6.mlmodelc/` + `tokenizer.json`（合計約 300MB）。3 モデルは同一 weight.bin を共有（CloudKit 配布時は 1 セットのチャンクを 3 モデルの `weights/` にコピー）
- モデルは CloudKit Public Database から配布。weight.bin は CKAsset 上限（250MB）超の場合チャンク分割保存
- 開発時のモデル差し替え: Finder → iPhone → eMeishi の `Documents/LocalLLM/` にフォルダごと配置
- CloudKit Container の設定・レコード作成・ファイルアップロードは Xcode / CloudKit Dashboard で手動実施
- CSV は Excel での文字化けを防ぐため UTF-8 BOM を付与（設定で無効化可能）・vCard は 3.0 形式（設定で 4.0 に変更可能）・重複判定は名前 70%・会社名 30% の重み付きスコア
- **HIG（Human Interface Guidelines）を参照する際は、まず sosumi MCP サーバーを使う。** `searchAppleDocumentation` で検索 → `fetchAppleDocumentation` で詳細取得（パス例：`design/human-interface-guidelines/foundations/color`）。必要に応じて `fetchAppleVideoTranscript` で関連 WWDC セッションも参照
- **App Store スクリーンショット撮影前に必ず `./scripts/shots-preflight.sh` を実行する。** シミュレータ shutdown → Dynamic Island 抑制（`SBSuppressDynamicIslandCompletely=true`）→ boot → ステータスバー固定（9:41・満充電・Wi-Fi 最大）を一括で行う。対象デバイスを絞る場合は `./scripts/shots-preflight.sh iphone` / `./scripts/shots-preflight.sh ipad`。UDID は `.asc/shots.settings.json` の `devices` から読む。撮影は `xcrun simctl io $UDID screenshot --mask=ignored` で取得すること
