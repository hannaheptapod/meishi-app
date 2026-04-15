#!/usr/bin/env bash
# Xcode Cloud: リポジトリクローン後に実行
#
# ビルド番号（CURRENT_PROJECT_VERSION）は Xcode Cloud が CI_BUILD_NUMBER を
# 自動注入する標準挙動に委ねるため、このスクリプトでは何もしない。

set -euo pipefail

echo "=== ci_post_clone ==="
echo "  Build #: ${CI_BUILD_NUMBER:-?} （Xcode Cloud 自動注入）"
