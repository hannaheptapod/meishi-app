#!/usr/bin/env bash
# Xcode Cloud: リポジトリクローン後に実行
#
# ビルド番号の設定は ci_pre_xcodebuild.sh で行う。
# APP_STORE_ELIGIBLE 配布設定が有効な場合、Xcode Cloud が ci_post_clone.sh の後で
# CURRENT_PROJECT_VERSION を CI_BUILD_NUMBER に上書きするため、
# xcodebuild 直前の ci_pre_xcodebuild.sh で xcrun agvtool を使って再設定する。

set -euo pipefail

echo "=== ci_post_clone ==="
echo "  ビルド番号設定は ci_pre_xcodebuild.sh で実施（APP_STORE_ELIGIBLE 上書き対策）"
