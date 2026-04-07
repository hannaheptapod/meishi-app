# eMeishi

iPhoneで名刺をスマートに管理するアプリ。カメラで撮影するだけで、AIが名前・会社名・連絡先を自動で読み取り、整理して保存します。

## 主な機能

- **カメラ撮影 + AI自動読み取り** — OCR + オンデバイスAI（Apple Intelligence / Qwen3-0.6B）で名刺のフィールドを自動分類。連続撮影にも対応
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
| OCR | Vision Framework（VNRecognizeTextRequest） |
| AI分析（Apple Intelligence対応端末） | Foundation Models（iOS 26+） |
| AI分析（非対応端末） | Qwen3-0.6B CoreML（Prefill/Decode分割） |
| カメラ | AVFoundation |
| 連絡先 | Contacts Framework |
| 生体認証 | LocalAuthentication |
| モデル配布 | CloudKit Public Database |

## 要件

- iOS 26.0 以降
- Xcode 26.0 以降
- iPhone（実機推奨。シミュレータではAI機能が制限されます）

## ビルド

```bash
git clone https://github.com/hannaheptapod/meishi-app.git
cd meishi-app
open eMeishi.xcodeproj
```

Xcode でビルドターゲットを選択し、実機またはシミュレータで実行してください。

> **Note:** Foundation Models は iPhone 15 Pro 以降 + Apple Intelligence 有効の実機でのみ動作します。Qwen3-0.6B CoreML はシミュレータでも動作しますが低速です。

## ライセンス

[MIT License](LICENSE)
