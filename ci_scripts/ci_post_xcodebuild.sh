#!/usr/bin/env bash
# Xcode Cloud: xcodebuild 実行後の処理
# Archive 完了後・Xcode Cloud の再署名（エクスポート）前に実行される
# CI_ARCHIVE_PATH のアーカイブ内 Info.plist を直接書き換えてビルド番号を上書きする

set -euo pipefail

echo "=== ci_post_xcodebuild ($CI_XCODEBUILD_ACTION) ==="

if [[ "$CI_XCODEBUILD_ACTION" == "archive" ]]; then
  echo "  Branch:  $CI_BRANCH"
  echo "  Commit:  $CI_COMMIT"
  echo "  Build:   $CI_BUILD_NUMBER"
  echo "  Workflow: $CI_WORKFLOW"
  echo "  Archive: ${CI_ARCHIVE_PATH:-未設定}"

  if [[ -n "${CI_BUILD_NUMBER:-}" ]] && [[ -n "${CI_ARCHIVE_PATH:-}" ]]; then
    DATE_PREFIX=$(date -u +"%Y%m%d")
    SEQ=$(printf "%03d" $(( (CI_BUILD_NUMBER % 999) + 1 )))
    NEW_BUILD_NUMBER="${DATE_PREFIX}${SEQ}"

    echo ""
    echo "=== ビルド番号設定 ==="
    echo "  CI_BUILD_NUMBER: $CI_BUILD_NUMBER"
    echo "  設定値: $NEW_BUILD_NUMBER"

    # アーカイブ内 App Bundle の Info.plist を更新
    APP_PLIST="${CI_ARCHIVE_PATH}/Products/Applications/eMeishi.app/Info.plist"
    if [[ -f "$APP_PLIST" ]]; then
      BEFORE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PLIST")
      /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD_NUMBER" "$APP_PLIST"
      AFTER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PLIST")
      echo "  [OK] CFBundleVersion: $BEFORE → $AFTER"
    else
      echo "  [WARN] $APP_PLIST が見つかりません。フォールバック検索..."
      find "${CI_ARCHIVE_PATH}/Products" -name "Info.plist" 2>/dev/null | while read -r plist; do
        echo "  検索結果: $plist"
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD_NUMBER" "$plist" && \
          echo "  [OK] CFBundleVersion → $NEW_BUILD_NUMBER ($plist)"
      done
    fi

    # アーカイブメタデータ（Info.plist）も更新
    ARCHIVE_META="${CI_ARCHIVE_PATH}/Info.plist"
    if [[ -f "$ARCHIVE_META" ]]; then
      /usr/libexec/PlistBuddy -c "Set :ApplicationProperties:CFBundleVersion $NEW_BUILD_NUMBER" \
        "$ARCHIVE_META" 2>/dev/null && \
        echo "  [OK] Archive metadata CFBundleVersion → $NEW_BUILD_NUMBER" || \
        echo "  [SKIP] Archive metadata 更新スキップ（キーなし）"
    fi
  else
    echo "  [SKIP] CI_BUILD_NUMBER または CI_ARCHIVE_PATH が未設定"
  fi
fi

if [[ "$CI_XCODEBUILD_ACTION" == "test" ]] || [[ "$CI_XCODEBUILD_ACTION" == "test-without-building" ]]; then
  echo "  テスト完了"
  echo "  Branch: $CI_BRANCH"
  echo "  Commit: $CI_COMMIT"
fi
