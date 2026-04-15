#!/usr/bin/env bash
# Xcode Cloud: xcodebuild 実行後の処理
#
# ビルド番号は Xcode Cloud が CI_BUILD_NUMBER（連番整数）を
# CURRENT_PROJECT_VERSION に自動注入する標準挙動に委ねる。
# TestFlight アップロードも Xcode Cloud の Distribution Preparation
# （App Store Connect）+ Post-Action（Internal Testing）で行うため、
# このスクリプトではログ出力のみ。

set -euo pipefail

echo "=== ci_post_xcodebuild ($CI_XCODEBUILD_ACTION) ==="
echo "  Branch:   ${CI_BRANCH:-?}"
echo "  Commit:   ${CI_COMMIT:-?}"
echo "  Workflow: ${CI_WORKFLOW:-?}"
echo "  Build #:  ${CI_BUILD_NUMBER:-?}"

if [[ "$CI_XCODEBUILD_ACTION" != "archive" ]]; then
  echo "  [SKIP] archive 以外は処理なし"
  exit 0
fi

APP_PLIST="${CI_ARCHIVE_PATH:-}/Products/Applications/eMeishi.app/Info.plist"
if [[ -f "$APP_PLIST" ]]; then
  CFBV=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PLIST" 2>/dev/null || echo "?")
  MV=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PLIST" 2>/dev/null || echo "?")
  echo "  Archive MARKETING_VERSION: $MV"
  echo "  Archive CFBundleVersion:   $CFBV"
fi
