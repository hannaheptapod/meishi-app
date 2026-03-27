# /branch — ブランチ管理スキル

ユーザーのプロンプトを受け取ったら、コード修正の**前に**このスキルを実行する。

## 手順

### 1. 現在のブランチを確認

```bash
git rev-parse --abbrev-ref HEAD
```

### 2. 未コミット変更を確認

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

### 3. ブランチ判定

- **main 以外の場合**：「ブランチ: {ブランチ名}」と報告して終了
- **main の場合**：
  1. ユーザーのプロンプト原文から作業内容を把握
  2. 英語の slug を生成（例：`feature/add-tag-filter`、`fix/ocr-reading-error`）
  3. `git checkout -b {slug}` でブランチを作成
  4. 「ブランチ作成: {slug}」と報告

## 出力フォーマット

```
🔀 ブランチ: feature/xxx（確認済み）
```
または
```
🔀 ブランチ作成: feature/xxx ← main から分岐
```
