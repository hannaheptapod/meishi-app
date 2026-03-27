# /translate — 翻訳スキル（ユーザー語 → エンジニア語 → リポジトリ箇所）

ユーザーのプロンプトを受け取ったら、`/branch` の**後に**このスキルを実行する。
コードを読む・修正する**前に**、ユーザーの指示を構造化する。

## Step 0: 論点の抽出

ユーザーの発言から**全ての指示を漏れなく列挙**する。

- 「ついでに」「あと」「それと」の後ろも**独立した論点**として扱う
- 感情表現（「イライラする」「めっちゃ困る」）は**優先度・重大度の手がかり**
- **省略・統合・要約はしない。3つ言ったら3つ出す**

### 出力フォーマット

```
📋 論点:
1. ○○○
2. △△△
3. □□□
```

## Step 1: エンジニア語への変換

各論点を技術的な問題定義に変換する。

### eMeishi 固有の変換例

| ユーザー語 | エンジニア語 |
|---|---|
| 名刺の表示がおかしい | CardDetailView / CardListView のデータバインディング問題 |
| OCRが読み取れない | OCRService の VNRecognizeTextRequest 設定 or CardFieldClassifier の分類ロジック |
| タグが消える | CoreData の Tag リレーション保存処理 or CardFormViewModel のタグ更新ロジック |
| 名前が逆になる | CardFieldClassifier の名前スコアリング or OCRService の行順序処理 |
| 重複判定がゆるい/きつい | DuplicateChecker の Levenshtein 閾値 or 重み付けロジック |
| 連絡先に出ない | ContactsService の CNContactStore 保存処理 |
| CSVが文字化けする | ExportService の UTF-8 BOM 付与処理 |
| 設定が保存されない | SettingsStore の UserDefaults 読み書き |
| ふりがなが出ない | CFStringTokenizer の読み生成 or CardFieldClassifier のフリガナ行検出 |
| LLMが遅い | LocalLLMService のタイムアウト設定 or Qwen25Tokenizer のトークン化処理 |

### 出力フォーマット

```
🔧 エンジニア語:
1. ○○○ → △△△（技術的な問題定義）
2. ...
```

## Step 2: リポジトリの具体箇所に紐付け

エンジニア語の各論点を、実際のファイルと処理に対応付ける。

### eMeishi ファイル対応表

| 領域 | ファイル |
|---|---|
| 一覧表示 | Views/CardListView.swift, ViewModels/CardListViewModel.swift |
| 詳細表示 | Views/CardDetailView.swift |
| 入力フォーム | Views/CardFormView.swift, ViewModels/CardFormViewModel.swift |
| カメラ・OCR | Views/CameraView.swift, Services/OCRService.swift |
| フィールド分類 | Utilities/CardFieldClassifier.swift |
| LLM推論 | Services/LocalLLMService.swift, Services/Qwen25Tokenizer.swift |
| 連絡先 | Services/ContactsService.swift |
| エクスポート | Services/ExportService.swift |
| 重複検出 | Utilities/DuplicateChecker.swift, Views/DuplicateListView.swift |
| 設定 | Views/SettingsView.swift, ViewModels/SettingsStore.swift |
| タグ管理 | Views/TagManagementView.swift |
| CoreData モデル | Models/BusinessCard+CoreDataProperties.swift, Models/Tag+CoreDataProperties.swift |
| データ基盤 | App/PersistenceController.swift |
| ルートView | ContentView.swift |

### 出力フォーマット

```
📍 対象ファイル:
1. ○○○
   → eMeishi/Views/CardListView.swift（該当処理の説明）
   → eMeishi/ViewModels/CardListViewModel.swift（該当処理の説明）
2. ...
```

## 最終出力

Step 0 → Step 1 → Step 2 の順で出力し、全体像を見せてからコード作業に入る。
