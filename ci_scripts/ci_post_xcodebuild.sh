#!/usr/bin/env bash
# Xcode Cloud: xcodebuild 実行後の処理

set -euo pipefail

echo "=== ci_post_xcodebuild ($CI_XCODEBUILD_ACTION) ==="

if [[ "$CI_XCODEBUILD_ACTION" == "archive" ]]; then
  echo "  Archive 完了"
  echo "  Branch:  $CI_BRANCH"
  echo "  Commit:  $CI_COMMIT"
  echo "  Build:   $CI_BUILD_NUMBER"
  echo "  Workflow: $CI_WORKFLOW"
fi

if [[ "$CI_XCODEBUILD_ACTION" == "test" ]] || [[ "$CI_XCODEBUILD_ACTION" == "test-without-building" ]]; then
  echo "  テスト完了"
  echo "  Branch: $CI_BRANCH"
  echo "  Commit: $CI_COMMIT"
fi
