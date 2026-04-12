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
release/*  App Store 提出前の最終確認のみ。機能追加禁止
hotfix/*   本番緊急修正。main から分岐し main と develop 両方へマージ
```

- **ブランチ名プレフィックスは `feature/` `fix/` `release/` `hotfix/` `docs/` `chore/` のみ許可。** 外部ツール・AI エージェントが自動生成した `claude/` 等を含め、規定外は `/branch` スキルで**即座にリネーム**する
- **main・develop への直接 push・commit は絶対禁止。** 必ずブランチを切り PR を通す。違反は `.claude/hooks/guard-git.sh` が自動ブロック（exit 2）する
- **日常フロー：** `develop` → `feature/<機能名>` → PR 作成 → **Xcode Cloud PR Validation 通過をユーザーが確認** → `develop` へマージ（ユーザー操作）
- **PR 作成後の Claude の役割はそこで終了。** Xcode Cloud の CI 結果確認・マージ・ブランチ削除はユーザーが行う。Claude が自律的にマージすることは**絶対禁止**
- **本プロジェクトで使う skill は 5 個のみ**: `/branch`・`/translate`（hook 強制）、`asc-shots-pipeline`・`asc-whats-new-writer`・`asc-release-flow`（リリース手順）。`.claude/skills/asc-*/` には Blitz が 22 個の未使用 skill を同期してくるが、gitignore 済みなので無視して良い
- **リリースフロー：**
  1. `git checkout develop && git checkout -b release/<x.y.z>`
  2. `Info.plist` のバージョン・ビルド番号を更新（冒頭の「ビルド・アップロード前チェックリスト」を参照）
  3. ビルド・アップロードはユーザー承認を得てから実行
  4. スクリーンショット撮影が必要な場合：`asc-shots-pipeline` スキル参照
  5. What's New 更新：`asc-whats-new-writer` スキル
  6. 審査提出：`asc-release-flow` スキル（提出前ヘルスチェック → Submit）
  7. 提出後：`release/<x.y.z>` → `main`（PR）、`release/<x.y.z>` → `develop`（PR）、`main` に `vX.Y.Z` タグ、ブランチ削除
  8. リリースノート公開：`gh release create vX.Y.Z --title "vX.Y.Z" --generate-notes` でマージ済み PR から GitHub Releases を自動生成（手書き CHANGELOG.md は管理しない方針）
- **緊急修正フロー：** `main` から `hotfix/<内容>` を切る → `main` と `develop` の両方にマージ
- マージ後は作業ブランチをローカル・リモートともに削除する（ユーザー操作）
- PR は機能単位でまとめる。無関係な変更を混在させない

### Xcode Cloud ワークフロー（PR マージ条件）

| ワークフロー | トリガー | 必須確認 |
|---|---|---|
| PR Validation | PR → `develop` | **Build PASS 後にユーザーがマージ** |
| Develop Integration | push → `develop` | Build 結果を確認（自動） |
| Release Build | push → `release/*` | Archive 成功後にユーザーが TestFlight 確認 |

- **PR を作成したら Claude はそれ以上手を出さない。** Xcode Cloud が PR Validation を自動実行するため、その結果をユーザーが確認してからマージする
- CI が失敗した場合は原因を調査・修正して再 push し、ユーザーに報告する

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
