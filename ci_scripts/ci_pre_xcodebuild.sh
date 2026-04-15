#!/usr/bin/env bash
# Xcode Cloud: xcodebuild 実行前のバリデーション
# scripts/pre-build-check.sh を CI 用に適応（asc CLI 依存の項目を除外）

set -euo pipefail

echo "=== ci_pre_xcodebuild ($CI_XCODEBUILD_ACTION) ==="

cd "$CI_PRIMARY_REPOSITORY_PATH"

PLIST="eMeishi/Info.plist"
DEBUG_PLIST="eMeishi/Info-Debug.plist"
RELEASE_XCCONFIG="eMeishi/Config/Release.xcconfig"
DEBUG_XCCONFIG="eMeishi/Config/Debug.xcconfig"
PASS=0
FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

plist_bool() {
  plutil -extract "$1" raw -o - "$2" 2>/dev/null || echo "MISSING"
}

# --- Info.plist 構文 ---
echo ""
echo "=== Info.plist 構文 ==="
if plutil -lint "$PLIST" > /dev/null 2>&1; then
  ok "plutil -lint OK"
else
  fail "plutil -lint NG: $(plutil -lint "$PLIST" 2>&1)"
fi

# --- 4方向サポート ---
echo ""
echo "=== 4方向サポート ==="
ORIENTATIONS=$(plutil -extract UISupportedInterfaceOrientations xml1 -o - "$PLIST" 2>/dev/null)
for dir in Portrait PortraitUpsideDown LandscapeLeft LandscapeRight; do
  if echo "$ORIENTATIONS" | grep -q "$dir"; then
    ok "$dir"
  else
    fail "$dir missing"
  fi
done

# --- Boolean フィールド型チェック ---
echo ""
echo "=== Boolean フィールド型チェック ==="
for key in UIFileSharingEnabled ITSAppUsesNonExemptEncryption LSSupportsOpeningDocumentsInPlace; do
  TYPE=$(grep -A1 "$key" "$PLIST" | tail -1 | xargs)
  if echo "$TYPE" | grep -qE "^<(true|false)/>$"; then
    ok "$key = $TYPE"
  else
    fail "$key の型が不正: $TYPE"
  fi
done

# --- Boolean フィールドへの変数展開混入 ---
echo ""
echo "=== 変数展開混入チェック ==="
if grep -A1 "UIFileSharingEnabled\|ITSAppUsesNonExemptEncryption" "$PLIST" \
    | grep -qE '<string>.*\$\('; then
  fail "Boolean フィールドに \$(...) が混入"
else
  ok "変数混入なし"
fi

# --- Release Info.plist の値チェック ---
echo ""
echo "=== Release Info.plist 値チェック ==="
ENC=$(plist_bool ITSAppUsesNonExemptEncryption "$PLIST")
if [[ "$ENC" == "false" ]]; then
  ok "ITSAppUsesNonExemptEncryption = false"
else
  fail "ITSAppUsesNonExemptEncryption = $ENC (false 必須)"
fi

SHARE=$(plist_bool UIFileSharingEnabled "$PLIST")
if [[ "$SHARE" == "false" ]]; then
  ok "UIFileSharingEnabled (Release) = false"
else
  fail "UIFileSharingEnabled (Release) = $SHARE (false 必須)"
fi

# --- Debug Info.plist チェック ---
echo ""
echo "=== Debug Info.plist ==="
if [[ -f "$DEBUG_PLIST" ]]; then
  if plutil -lint "$DEBUG_PLIST" > /dev/null 2>&1; then
    ok "plutil -lint OK ($DEBUG_PLIST)"
  else
    fail "plutil -lint NG: $(plutil -lint "$DEBUG_PLIST" 2>&1)"
  fi
  SHARE_DBG=$(plist_bool UIFileSharingEnabled "$DEBUG_PLIST")
  if [[ "$SHARE_DBG" == "true" ]]; then
    ok "UIFileSharingEnabled (Debug) = true"
  else
    fail "UIFileSharingEnabled (Debug) = $SHARE_DBG (true 必須)"
  fi
else
  fail "$DEBUG_PLIST が存在しない"
fi

# --- xcconfig → Info.plist マッピング ---
echo ""
echo "=== xcconfig マッピング ==="
REL_INFO=$(grep -E "^INFOPLIST_FILE\s*=" "$RELEASE_XCCONFIG" | sed 's/.*=\s*//' | tr -d '[:space:]')
if [[ "$REL_INFO" == "eMeishi/Info.plist" ]]; then
  ok "Release.xcconfig INFOPLIST_FILE = $REL_INFO"
else
  fail "Release.xcconfig INFOPLIST_FILE = $REL_INFO (eMeishi/Info.plist 必須)"
fi

DBG_INFO=$(grep -E "^INFOPLIST_FILE\s*=" "$DEBUG_XCCONFIG" | sed 's/.*=\s*//' | tr -d '[:space:]')
if [[ "$DBG_INFO" == "eMeishi/Info-Debug.plist" ]]; then
  ok "Debug.xcconfig INFOPLIST_FILE = $DBG_INFO"
else
  fail "Debug.xcconfig INFOPLIST_FILE = $DBG_INFO (eMeishi/Info-Debug.plist 必須)"
fi

# --- Usage Description ---
echo ""
echo "=== Usage Description ==="
for key in NSCameraUsageDescription NSContactsUsageDescription NSFaceIDUsageDescription NSPhotoLibraryUsageDescription; do
  if grep -q "$key" "$PLIST"; then
    ok "$key"
  else
    fail "$key MISSING"
  fi
done

# --- ビルド番号 ---
# Xcode Cloud が CI_BUILD_NUMBER（連番整数）を CURRENT_PROJECT_VERSION に自動注入する
# 標準挙動に委ねる。カスタム形式（yyyymmddNNN など）は使わない。
echo ""
echo "=== ビルド番号 ==="
echo "  CI_BUILD_NUMBER: ${CI_BUILD_NUMBER:-?} （Xcode Cloud が自動注入）"
ok "ビルド番号（Xcode Cloud 自動管理）"

# --- CI でスキップする項目 ---
echo ""
echo "  [SKIP] Distribution 証明書 (Xcode Cloud が自動管理)"
echo "  [SKIP] プロビジョニングプロファイル (Xcode Cloud が自動管理)"

# --- 結果 ---
echo ""
echo "================================"
echo "  PASS: $PASS  FAIL: $FAIL"
echo "================================"

if [[ $FAIL -gt 0 ]]; then
  if [[ "$CI_XCODEBUILD_ACTION" == "archive" ]]; then
    echo "FAIL 検出 (archive)。ビルドをブロックします。"
    exit 1
  else
    echo "FAIL 検出 ($CI_XCODEBUILD_ACTION)。警告として続行します。"
  fi
else
  echo "全項目 PASS。"
fi
