#!/usr/bin/env bash
# スクリーンショット撮影前のシミュレータ設定を固定する
#
# 以下を 1 コマンドで実施する：
#   1. シミュレータ shutdown
#   2. Dynamic Island 非表示（iPhone のみ・SBSuppressDynamicIslandCompletely=true）
#   3. シミュレータ boot
#   4. ステータスバー固定（9:41 / 満充電 / Wi-Fi 最大）
#
# UDID は .asc/shots.settings.json の devices.{iphone,ipad}.udid から取得する。
#
# 使い方:
#   ./scripts/shots-preflight.sh           # iphone と ipad 両方
#   ./scripts/shots-preflight.sh iphone    # iphone のみ
#   ./scripts/shots-preflight.sh ipad      # ipad のみ

set -euo pipefail

cd "$(dirname "$0")/.."

SETTINGS=".asc/shots.settings.json"
TARGET="${1:-all}"

if [[ ! -f "$SETTINGS" ]]; then
  echo "✗ $SETTINGS が見つかりません" >&2
  exit 1
fi

read_udid() {
  local key="$1"
  python3 -c "import json,sys; d=json.load(open('$SETTINGS'))['devices'].get('$key'); print(d['udid'] if d else '')"
}

apply() {
  local label="$1"
  local udid="$2"
  local suppress_di="$3"   # true / false

  if [[ -z "$udid" ]]; then
    echo "⏭  $label: UDID 未設定。スキップ"
    return 0
  fi

  echo "=== $label ($udid) ==="

  echo "  → shutdown"
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true

  if [[ "$suppress_di" == "true" ]]; then
    local plist="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Library/Preferences/com.apple.springboard.plist"
    if [[ -f "$plist" ]]; then
      defaults write "$plist" SBSuppressDynamicIslandCompletely -bool true
      echo "  ✓ Dynamic Island 抑制"
    else
      mkdir -p "$(dirname "$plist")"
      /usr/libexec/PlistBuddy -c "Add :SBSuppressDynamicIslandCompletely bool true" "$plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :SBSuppressDynamicIslandCompletely true" "$plist"
      echo "  ✓ Dynamic Island 抑制（plist 新規作成）"
    fi
  fi

  echo "  → boot"
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null

  xcrun simctl status_bar "$udid" override \
    --time "9:41" \
    --dataNetwork wifi \
    --wifiMode active \
    --wifiBars 3 \
    --cellularMode active \
    --cellularBars 4 \
    --batteryState charged \
    --batteryLevel 100
  echo "  ✓ ステータスバー固定（9:41 / 満充電 / Wi-Fi 3）"

  echo ""
}

case "$TARGET" in
  iphone)
    apply "iPhone" "$(read_udid iphone)" true
    ;;
  ipad)
    apply "iPad" "$(read_udid ipad)" false
    ;;
  all|"")
    apply "iPhone" "$(read_udid iphone)" true
    apply "iPad"   "$(read_udid ipad)"   false
    ;;
  *)
    echo "✗ 不明なターゲット: $TARGET（iphone / ipad / all のいずれか）" >&2
    exit 1
    ;;
esac

echo "✅ 撮影前セットアップ完了。スクリーンショットは --mask=ignored で取得すること:"
echo "    xcrun simctl io <UDID> screenshot --mask=ignored out.png"
