# リリースフロー

App Store 提出までの各フェーズの手順。日常の開発ルール・ブランチ戦略は [AGENTS.md](../AGENTS.md)、Xcode Cloud のワークフロー定義は [README.md](../README.md) の「CI/CD（Xcode Cloud）」を参照。

## フェーズ 1: 日常開発フロー

```
develop
  └─[エージェント] feature/<機能名> ブランチ作成
       ├─[エージェント] 実装・コミット・push
       ├─[エージェント] PR 作成（base: develop）
       ├─[Xcode Cloud] PR Validation 自動起動（Build + Test）
       ├─[ユーザー] CI 結果確認 → PR マージ
       ├─[Xcode Cloud] Develop Integration 自動起動（Build + Test）
       └─[ユーザー] ブランチ削除（ローカル・リモート）
```

## フェーズ 2: リリース準備（TestFlight 検証ループ）

```
develop
  └─[エージェント]  1. release/<x.y.z> ブランチ作成（develop から分岐）
  └─[ユーザー]      2. MARKETING_VERSION を手動更新（Xcode → Target → General → Version）
  └─[エージェント]  3. ./scripts/pre-build-check.sh 実行・全 PASS を確認
  └─[エージェント]  4. 結果をユーザーに提示し、明示的な承認を得る
  └─[エージェント]  5. commit → push（`guard-git.sh` が sentinel 確認: pre-build-check.sh PASS 後の HEAD と一致必須）
  └─[Xcode Cloud]   6. Release Build 自動起動（Archive → TestFlight 配信）
  └─[ユーザー]      7. TestFlight で動作確認
  └─[両者]          8. 問題あり → 修正 commit → push（手順 5 に戻る）
                       ※合格ビルドが決まるまで 5〜7 を繰り返す。
                         push のたびに Archive が走り、ビルド番号が進む。
```

> **release/\* への push は「ASC 提出前」なら何回でも可。** TestFlight 検証で bug が見つかったら普通に修正 commit を積んで push する。合格ビルドが決まった時点（= ASC 提出開始時点）が境界線。**提出後は取り下げない限り push 禁止**（詳細はフェーズ 5）。

## フェーズ 3: メタデータ準備（Xcode Cloud は動かない）

```
develop
  └─[エージェント]  1. chore/release-<x.y.z>-metadata ブランチ作成
  └─[エージェント]  2. metadata/version/<x.y.z>/ja.json に What's New を記載
  └─[エージェント]  3. （UI 変更があれば）./scripts/shots-preflight.sh → スクリーンショット撮影
  └─[エージェント]  4. commit → push → PR（base: develop）
  └─[Xcode Cloud]   5. PR Validation 自動起動
  └─[ユーザー]      6. CI 確認 → マージ
  └─[Xcode Cloud]   7. Develop Integration 自動起動
```

> **メタデータは build に無関係なので `release/*` に載せない。** develop 側で管理することで `release/*` の Archive に影響させない。

## フェーズ 4: ストア提出（Xcode Cloud は動かない）

```
  └─[エージェント] 1. asc release stage --copy-metadata-from <前バージョン> --exclude-fields whatsNew --build <合格ビルドID> --confirm
  └─[エージェント] 2. asc localizations update --version <id> --locale ja --whats-new "..."
  └─[エージェント] 3. （UI 変更があれば）スクリーンショットを ASC にアップロード
  └─[エージェント] 4. asc validate --app <id> --version <x.y.z> で readiness 確認
  └─[エージェント] 5. asc review submissions-create → items-add → submissions-submit --confirm
```

> **ここから release/<x.y.z> へは絶対 push しない。** 提出済みバージョンには差し替えできないため、新ビルドが生まれても宙に浮く。

## フェーズ 5: 審査中の修正（Reject 対応・提出後のバグ発見）

```
  └─[エージェント]  1. asc review submissions-update --canceled=true で提出取り下げ
  └─[エージェント]  2. 修正 commit → release/<x.y.z> に push
  └─[Xcode Cloud]   3. Release Build 自動起動（新ビルド生成）
  └─[ユーザー]      4. TestFlight で再検証
  └─[両者]          5. フェーズ 3〜4 をやり直し
```

> **提出後の push は必ず「取り下げ → push → 再提出」のセットで行う。** 取り下げずに push すると宙ぶらりんのビルドが生まれるだけ。

## フェーズ 6: 後片付け（審査通過後）

```
  └─[エージェント]  1. release/<x.y.z> → main に PR 作成
  └─[ユーザー]      2. PR マージ
  └─[エージェント]  3. release/<x.y.z> → develop に PR 作成
  └─[ユーザー]      4. PR マージ
  └─[Xcode Cloud]   5. Develop Integration 自動起動
  └─[エージェント]  6. GitHub Releases 作成（gh release create vX.Y.Z --generate-notes --target main）
                       ※ タグは gh release create が自動作成するため git tag 不要
  └─[ユーザー]      7. release ブランチ削除（ローカル・リモート）
```

> **バージョン番号（MARKETING_VERSION）のみ手動更新。** Xcode → Target → General → Version フィールドで変更する（`project.pbxproj` をエージェントが直接編集しないため）。ビルド番号（CURRENT_PROJECT_VERSION）は Xcode Cloud が `CI_BUILD_NUMBER`（連番）を自動注入するため、手動変更不要。

## フェーズ 7: 緊急修正フロー（hotfix・本番障害対応）

```
main
  └─[エージェント]  1. hotfix/<内容> ブランチ作成（main から分岐）
  └─[ユーザー]      2. MARKETING_VERSION をパッチ更新（例: 1.0.4 → 1.0.5）
  └─[エージェント]  3. 修正 commit → push → PR（base: main）
                       ※ PR Validation は main 向け PR では自動起動しない
  └─[ユーザー]      4. PR マージ → main へ取り込み
  └─[ユーザー]      5. hotfix → release/<x.y.z> として扱うか別途 release/ 分岐して Archive を起動
  └─[両者]          6. フェーズ 3〜6 と同じ流れで提出・公開
  └─[エージェント]  7. hotfix/<内容> → develop への PR 作成
  └─[ユーザー]      8. PR マージ
  └─[ユーザー]      9. ブランチ削除（ローカル・リモート）
```
