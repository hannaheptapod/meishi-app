# /branch — ブランチ管理スキル（Git Flow）

ユーザーのプロンプトを受け取ったら、コード修正の**前に**このスキルを実行する。

## ブランチ構成（Git Flow）

```
main       本番リリース済み。直接コミット禁止
develop    次リリースの統合ブランチ。直接コミット禁止
feature/*  日常の機能開発（develop から分岐・develop へ戻す）
fix/*      バグ修正（develop から分岐・develop へ戻す）
refactor/* 挙動変更なしのコード構造改善（develop から分岐・develop へ戻す）
release/*  App Store 提出前の最終調整（develop から分岐）
hotfix/*   本番緊急修正（main から分岐・main と develop へ戻す）
docs/*     ドキュメント更新
chore/*    ビルド設定・依存関係等
```

**禁止プレフィックス（即座にリネーム）：** `claude/` `agent/` `temp/` `test/` `wip/` 等、上記以外のプレフィックスはすべて禁止。外部ツール・AI エージェントが自動生成したブランチ名も例外なし。

---

## 手順

### Step 0: 規定外プレフィックス検出（最優先）

```bash
git rev-parse --abbrev-ref HEAD
```

現在のブランチ名を確認し、**許可プレフィックス以外**（`feature/` `fix/` `refactor/` `release/` `hotfix/` `docs/` `chore/`）かつ `main` / `develop` でもない場合：

1. ユーザーに警告を出す：「⚠️ ブランチ名 `{現在名}` は規定外プレフィックスです」
2. ユーザーのプロンプト内容から適切な新ブランチ名を提案（例：`feature/enforce-branch-strategy`）
3. ローカルをリネーム：
   ```bash
   git branch -m {現在名} {新ブランチ名}
   ```
4. リモートに旧ブランチが存在する場合は移行：
   ```bash
   git push origin {新ブランチ名}
   git push origin --delete {現在名}
   git branch --set-upstream-to=origin/{新ブランチ名} {新ブランチ名}
   ```
5. リネーム完了を報告してから Step 1 へ進む

### Step 1. 現在のブランチを確認

（Step 0 でリネーム済みの場合は新ブランチ名で継続）

```bash
git rev-parse --abbrev-ref HEAD
```

### Step 1.5. リモートの最新状態を取得（必須）

```bash
git fetch origin
git log --oneline -5 origin/develop
```

- **必ずここで `origin/develop` の直近コミットを確認する**
- ローカルの develop がリモートより古い場合は `git pull origin develop` を実行してから分岐する
- 直近のコミット内容（機能追加・Swift バージョン更新等）を把握し、実装に影響する変更がないか確認する

### Step 2. 未コミット変更を確認

```bash
git status
```

変更がある場合：
- **以下のファイルが含まれていないか確認**（含まれていたらユーザーに警告）：
  - `.env`、秘密情報ファイル
  - `.xcodeproj` 内のファイル
  - `.xcdatamodeld` 内のファイル
- ファイル名を**個別に指定**して `git add`（`git add .` や `git add -A` は禁止）
- 現在ブランチにコミットする

### Step 3. ブランチ判定

- **feature/* / fix/* / refactor/* / release/* / hotfix/* / docs/* / chore/* の場合**：「ブランチ: {ブランチ名}」と報告して終了
- **develop の場合**：
  1. ユーザーのプロンプト原文から作業内容と適切なプレフィックスを判断
  2. 英語の slug を生成（例：`feature/add-tag-filter`、`fix/ocr-reading-error`）
  3. `git checkout -b {slug}` でブランチを作成
  4. 「ブランチ作成: {slug} ← develop から分岐」と報告
- **main の場合**：
  1. 緊急修正（hotfix）かどうか判断
  2. hotfix なら `git checkout -b hotfix/<内容>`
  3. それ以外なら **警告を出して develop に切り替えてからブランチを切る**：
     `git checkout develop && git checkout -b {slug}`
  4. 「⚠️ main から分岐は原則禁止。develop 経由でブランチを作成: {slug}」と報告

---

## PR 作成後のルール（厳守）

実装・コミット・push が完了し PR を作成したら、**Claude の作業はそこで終了**。

1. **マージは絶対に自律実行しない** — Xcode Cloud が PR Validation ワークフローを自動起動する
2. **ユーザーに結果確認を委ねる** — CI の Pass/Fail を確認してからマージするのはユーザーの判断
3. **ブランチ削除もユーザーが行う** — マージ後のローカル・リモートブランチ削除はユーザー操作

PR 作成後の報告フォーマット：

```
✅ PR 作成: #{番号} — {タイトル}
   Xcode Cloud が PR Validation を自動実行します。
   CI の結果を確認してからマージしてください（Claude はマージしません）。
```

---

## 出力フォーマット

```
🔀 ブランチ: feature/xxx（確認済み）
```
または
```
🔀 ブランチ作成: feature/xxx ← develop から分岐
```
または
```
⚠️ 規定外ブランチを検出。claude/xxx → feature/xxx にリネームしました
```
または
```
⚠️ main への直接コミットは禁止。develop 経由でブランチを作成: feature/xxx
```
