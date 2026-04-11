#!/usr/bin/env bash
# ビルド・アップロード前チェック
# 全項目 PASS でなければアーカイブ禁止

set -euo pipefail
PASS=0
FAIL=0
PLIST="eMeishi/Info.plist"

ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "=== ビルド番号 ==="
LATEST=$(~/.blitz/bin/asc builds list --app 6761180218 --platform IOS --limit 3 2>/dev/null \
  | python3 -c "import sys,json; b=json.load(sys.stdin)['data']; print(b[0]['attributes']['version']) if b else print('none')")
CURRENT=$(~/.blitz/bin/asc xcode version view 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['buildNumber'])")
echo "  ASC最新: $LATEST  プロジェクト: $CURRENT"
if [[ "$CURRENT" -gt "$LATEST" ]] 2>/dev/null; then
  ok "ビルド番号 $CURRENT > ASC最新 $LATEST"
else
  fail "ビルド番号が ASC最新以下または比較不可 ($CURRENT <= $LATEST)"
fi

echo ""
echo "=== Info.plist 構文 ==="
if plutil -lint "$PLIST" > /dev/null 2>&1; then
  ok "plutil -lint OK"
else
  fail "plutil -lint NG: $(plutil -lint $PLIST 2>&1)"
fi

echo ""
echo "=== 4方向サポート ==="
ORIENTATIONS=$(plutil -extract UISupportedInterfaceOrientations xml1 -o - "$PLIST" 2>/dev/null)
for dir in Portrait PortraitUpsideDown LandscapeLeft LandscapeRight; do
  if echo "$ORIENTATIONS" | grep -q "$dir"; then
    ok "$dir"
  else
    fail "$dir が missing"
  fi
done

echo ""
echo "=== Boolean フィールド型チェック ==="
for key in UIFileSharingEnabled ITSAppUsesNonExemptEncryption LSSupportsOpeningDocumentsInPlace; do
  TYPE=$(grep -A1 "$key" "$PLIST" | tail -1 | xargs)
  if echo "$TYPE" | grep -qE "^<(true|false)/>$"; then
    ok "$key = $TYPE"
  else
    fail "$key の型が不正: $TYPE （<true/> or <false/> 必須）"
  fi
done

echo ""
echo "=== Boolean フィールドへの変数展開混入 ==="
if grep -A1 "UIFileSharingEnabled\|ITSAppUsesNonExemptEncryption" "$PLIST" \
    | grep -qE "<string>.*\$\("; then
  fail "Boolean フィールドに文字列変数 \$(...) が混入している"
else
  ok "変数混入なし"
fi

echo ""
echo "=== Usage Description ==="
for key in NSCameraUsageDescription NSContactsUsageDescription NSFaceIDUsageDescription NSPhotoLibraryUsageDescription; do
  if grep -q "$key" "$PLIST"; then
    ok "$key"
  else
    fail "$key が missing"
  fi
done

echo ""
echo "================================"
echo "  PASS: $PASS  FAIL: $FAIL"
echo "================================"
if [[ $FAIL -gt 0 ]]; then
  echo "FAIL があります。アーカイブ禁止。"
  exit 1
fi
echo "全項目 PASS。ユーザー承認後にアーカイブ可。"
