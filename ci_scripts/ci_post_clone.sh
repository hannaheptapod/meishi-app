#!/usr/bin/env bash
# Xcode Cloud: リポジトリクローン後に実行
# ビルド番号を YYYYMMDDNNN 形式で自動生成し project.pbxproj を更新する

set -euo pipefail

echo "=== ci_post_clone ==="

# --- ビルド番号生成: YYYYMMDDNNN ---
# CI_BUILD_NUMBER: Xcode Cloud の自動連番（プロダクト単位で一意）
# NNN: CI_BUILD_NUMBER mod 999 + 1（日付プレフィックスで実質一意）
DATE_PREFIX=$(date -u +"%Y%m%d")
SEQ=$(printf "%03d" $(( (CI_BUILD_NUMBER % 999) + 1 )))
NEW_BUILD_NUMBER="${DATE_PREFIX}${SEQ}"

echo "  CI_BUILD_NUMBER: $CI_BUILD_NUMBER"
echo "  生成ビルド番号:  $NEW_BUILD_NUMBER"

# project.pbxproj の CURRENT_PROJECT_VERSION を一括置換
cd "$CI_PRIMARY_REPOSITORY_PATH"
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*/CURRENT_PROJECT_VERSION = ${NEW_BUILD_NUMBER}/" \
    eMeishi.xcodeproj/project.pbxproj

echo "  CURRENT_PROJECT_VERSION → $NEW_BUILD_NUMBER に更新完了"
