# CloudKit モデルアップロード手順

本アプリの LLM モデル（Anemll Qwen3-0.6B-ctx512）は CloudKit Public Database
経由でユーザーに配布される。モデルを差し替えるときは以下の手順で再アップロードする。

本手順は **開発用の Settings 画面ボタン方式**を前提にしている。ターミナル完結の
アップロードツール（CloudKit Web Services API / Swift CLI）は Issue で追跡中。

## 前提

- macOS で Xcode を開き、DEBUG ビルドが通る状態
- 配布元の Apple ID で iCloud にサインインしたシミュレータ or 実機
- 新しいモデルファイル一式（3 モデル + tokenizer）がローカルにある

## モデルファイルの構成

`Documents/LocalLLM/` 配下に以下の構造で配置する。

```
LocalLLM/
├── qwen_embeddings.mlmodelc/
│   ├── coremldata.bin
│   ├── metadata.json
│   ├── model.mil
│   └── weights/weight.bin
├── qwen_FFN_PF_lut6_chunk_01of01.mlmodelc/
│   ├── coremldata.bin
│   ├── metadata.json
│   ├── model.mil
│   └── weights/weight.bin
├── qwen_lm_head_lut6.mlmodelc/
│   ├── coremldata.bin
│   ├── metadata.json
│   ├── model.mil
│   └── weights/weight.bin
└── tokenizer.json
```

## 手順

1. **シミュレータ Documents へモデルを配置**
   - Xcode で eMeishi を DEBUG ビルドし一度起動（シミュレータ側に app コンテナを作らせる）
   - Finder で `Simulator > File > Open Simulator Device Directories` を開き、
     該当デバイスの `data/Containers/Data/Application/<APP_UUID>/Documents/` を開く
   - `LocalLLM/` ディレクトリを上記構造のまま丸ごとコピー
2. **アプリで Settings > 開発者向け > "CloudKit モデルを正しいバージョンに更新" をタップ**
3. **ログを確認** — Xcode の Console で `CloudKitUpload:` で始まる行を見る
   - アップロード前に 3 モデル分の `size=<MB>MB sha256=<hex>` が出る
   - 保存中は「合計 N チャンク / embed=...MB ffn=...MB lmhead=...MB」が出る
   - 保存後に「✅ 検証 OK」が出れば成功
4. **アプリの画面表示**で `✅ CloudKit 更新・検証完了（N チャンク）` を確認

## 保存されるレコードフィールド

| フィールド | 型 | 用途 |
|---|---|---|
| `coremlDataAsset` / `metadataAsset` / `modelMilAsset` | CKAsset | embed モデルの小ファイル |
| `prefillCoremlDataAsset` / `prefillMetadataAsset` / `prefillModelMilAsset` | CKAsset | ffn モデルの小ファイル |
| `decodeCoremlDataAsset` / `decodeMetadataAsset` / `decodeModelMilAsset` | CKAsset | lmhead モデルの小ファイル |
| `tokenizerAsset` | CKAsset | tokenizer.json |
| `weightChunk0` 〜 `weightChunk4` | CKAsset | weight.bin チャンク（各 200MB 以内） |
| `weightChunkCount` | Int64 | チャンク総数（現在は 5） |
| `embedWeightSHA256` | String | embed weight.bin の SHA256（ダウンロード側の整合性検証用） |
| `ffnWeightSHA256` | String | ffn weight.bin の SHA256 |
| `lmheadWeightSHA256` | String | lmhead weight.bin の SHA256 |

ダウンロード側（`CloudKitModelService`）は各モデルの最終チャンクを書き終えた
タイミングで SHA256 を再計算し、上記フィールドと一致するか検証する。古い
レコード（SHA256 フィールドが存在しない）は検証をスキップして従来通り動く。

## トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| "Documents/LocalLLM が見つかりません" | ファイルを Containers 配下に配置していない / アプリを一度も起動していない | 手順 1 をやり直す |
| "`<path>` が見つかりません" | ディレクトリ構造が崩れている | 上記「モデルファイルの構成」と一致させる |
| アップロード途中でネットワークエラー | CloudKit save は atomic なので最初からやり直し | 安定した回線で再実行。失敗時の再開は未対応（follow-up 課題） |
| "保存は成功したが検証失敗" | レコードには書かれたが CloudKit 側が値を受け取っていない | 数分待って再度タップ（レプリケーション遅延の可能性） |
| ダウンロード側で "weight.bin が破損しています" | 配布中のレコードと SHA256 が不整合 | 再アップロードする。旧レコードを dashboard で消さない（ロールバック用） |

## 今後の改善

このフロー自体の刷新は GitHub Issue でトラッキング:
- (A) CloudKit Web Services API 経由のシェルスクリプト化
- (B) Swift 製 CLI ターゲット化
