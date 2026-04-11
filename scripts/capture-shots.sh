#!/usr/bin/env bash
# App Store スクリーンショットを XCUITest 経由で取得するスクリプト
#
# 流れ:
#   1. shots-preflight.sh で対象シミュレータを 9:41 / Dynamic Island 抑制状態に固定
#   2. xcodebuild test で eMeishiUITests/ScreenshotRunnerTests を実行
#   3. xcresulttool で .xcresult から PNG を抽出して
#      screenshots/raw/<device_dir>/ に配置
#
# 使い方:
#   ./scripts/capture-shots.sh           # iphone と ipad 両方
#   ./scripts/capture-shots.sh iphone    # iphone のみ
#   ./scripts/capture-shots.sh ipad      # ipad のみ

set -euo pipefail

cd "$(dirname "$0")/.."

SETTINGS=".asc/shots.settings.json"
TARGET="${1:-all}"

if [[ ! -f "$SETTINGS" ]]; then
  echo "✗ $SETTINGS が見つかりません" >&2
  exit 1
fi

read_json() {
  python3 -c "import json,sys; d=json.load(open('$SETTINGS')); print($1)"
}

read_device() {
  local key="$1"
  local field="$2"
  python3 -c "
import json
d = json.load(open('$SETTINGS'))['devices'].get('$key')
print(d.get('$field', '') if d else '')
"
}

SCHEME=$(read_json "d['app']['scheme']")
PROJECT=$(read_json "d['app']['project']")

extract_screenshots() {
  local xcresult="$1"
  local out_dir="$2"

  mkdir -p "$out_dir"

  echo "  → xcresult から添付ファイルを抽出: $xcresult"

  local stage_dir
  stage_dir="$(mktemp -d)"
  xcrun xcresulttool export attachments \
    --path "$xcresult" \
    --output-path "$stage_dir" >/dev/null

  python3 - "$stage_dir" "$out_dir" <<'PY'
import json
import shutil
import sys
from pathlib import Path

stage = Path(sys.argv[1])
out_dir = Path(sys.argv[2])
out_dir.mkdir(parents=True, exist_ok=True)

# 既存の PNG をクリア
for old in out_dir.glob("*.png"):
    old.unlink()

manifest_path = stage / "manifest.json"
if not manifest_path.exists():
    print("✗ manifest.json が見つかりません", file=sys.stderr)
    sys.exit(1)

manifest = json.loads(manifest_path.read_text())
copied = 0
for entry in manifest:
    for att in entry.get("attachments", []):
        suggested = att.get("suggestedHumanReadableName") or ""
        exported = att.get("exportedFileName")
        if not exported or not suggested.lower().endswith(".png"):
            continue
        # XCTAttachment(screenshot:) は "<name>_<index>_<UUID>.png" に展開されるので
        # 末尾 2 セグメントを取り除いて元の name を復元する
        base = suggested.rsplit("_", 2)[0] + ".png"
        shutil.copy(stage / exported, out_dir / base)
        print(f"  ✓ {base}")
        copied += 1

if copied == 0:
    print("✗ PNG 添付が見つかりません", file=sys.stderr)
    sys.exit(1)

print(f"  ✓ {copied} 枚のスクリーンショットを {out_dir} に保存")
PY

  rm -rf "$stage_dir"
}

run_target() {
  local label="$1"
  local key="$2"

  local udid raw_dir
  udid=$(read_device "$key" "udid")
  raw_dir=$(read_device "$key" "raw_dir")

  if [[ -z "$udid" ]]; then
    echo "⏭  $label: UDID 未設定。スキップ"
    return 0
  fi

  echo ""
  echo "=== $label ($udid) ==="

  # 撮影前: シミュレータを撮影モードにセットアップ
  ./scripts/shots-preflight.sh "$key"

  # Simulator.app を起動して対象 UDID を boot 状態に維持しておく
  # （xctrunner の "Application failed preflight checks" 回避）
  open -a Simulator
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null

  # XCUITest 実行
  local xcresult="build/screenshots-${key}.xcresult"
  rm -rf "$xcresult"

  echo "  → xcodebuild test 実行"
  set +e
  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$udid" \
    -only-testing:eMeishiUITests/ScreenshotRunnerTests \
    -resultBundlePath "$xcresult" \
    -quiet
  local rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    echo "✗ xcodebuild test が失敗 (exit $rc)" >&2
    exit $rc
  fi

  # PNG 抽出
  rm -rf "$raw_dir"
  extract_screenshots "$xcresult" "$raw_dir"

  echo "✅ $label 完了"
}

case "$TARGET" in
  iphone) run_target "iPhone" "iphone" ;;
  ipad)   run_target "iPad"   "ipad"   ;;
  all|"")
    run_target "iPhone" "iphone"
    run_target "iPad"   "ipad"
    ;;
  *)
    echo "✗ 不明なターゲット: $TARGET（iphone / ipad / all）" >&2
    exit 1
    ;;
esac

echo ""
echo "✅ スクリーンショット撮影完了"
