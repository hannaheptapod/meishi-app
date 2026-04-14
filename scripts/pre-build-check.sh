#!/usr/bin/env bash
# ビルド・アップロード前チェック
# 全項目 PASS でなければアーカイブ禁止

set -euo pipefail
PASS=0
FAIL=0
PLIST="eMeishi/Info.plist"
DEBUG_PLIST="eMeishi/Info-Debug.plist"
RELEASE_XCCONFIG="eMeishi/Config/Release.xcconfig"
DEBUG_XCCONFIG="eMeishi/Config/Debug.xcconfig"
BUNDLE_ID="com.jinks.emeishi"

ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

plist_bool() {
  plutil -extract "$1" raw -o - "$2" 2>/dev/null || echo "MISSING"
}

echo "=== ビルド番号 ==="
# ビルド番号は ci_scripts/ci_post_clone.sh が Xcode Cloud で yyyymmddNNN 形式に自動生成する。
# ローカル値の大小チェックは Xcode Cloud と二重管理になるためスキップ。
LATEST=$(~/.blitz/bin/asc builds list --app 6761180218 --platform IOS --limit 3 2>/dev/null \
  | python3 -c "import sys,json; b=json.load(sys.stdin)['data']; print(b[0]['attributes']['version']) if b else print('none')")
CURRENT=$(~/.blitz/bin/asc xcode version view 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['buildNumber'])")
echo "  ASC最新: $LATEST  プロジェクト: $CURRENT（Xcode Cloud が自動更新するためチェックスキップ）"
ok "ビルド番号（CI 自動管理）"

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
echo "=== Release Info.plist の値チェック ==="
# 輸出コンプライアンス: ITSAppUsesNonExemptEncryption=false 必須
# true のまま提出すると暗号化自己申告が必要になり審査が遅れる
ENC=$(plist_bool ITSAppUsesNonExemptEncryption "$PLIST")
if [[ "$ENC" == "false" ]]; then
  ok "ITSAppUsesNonExemptEncryption = false"
else
  fail "ITSAppUsesNonExemptEncryption = $ENC （Release は false 必須）"
fi
# Release は Finder ファイル共有を無効化
SHARE=$(plist_bool UIFileSharingEnabled "$PLIST")
if [[ "$SHARE" == "false" ]]; then
  ok "UIFileSharingEnabled (Release) = false"
else
  fail "UIFileSharingEnabled (Release) = $SHARE （Release は false 必須）"
fi

echo ""
echo "=== Debug Info.plist の値チェック ==="
if [[ -f "$DEBUG_PLIST" ]]; then
  if plutil -lint "$DEBUG_PLIST" > /dev/null 2>&1; then
    ok "plutil -lint OK ($DEBUG_PLIST)"
  else
    fail "plutil -lint NG: $(plutil -lint $DEBUG_PLIST 2>&1)"
  fi
  # Debug は開発用モデル転送のため true 固定
  SHARE_DBG=$(plist_bool UIFileSharingEnabled "$DEBUG_PLIST")
  if [[ "$SHARE_DBG" == "true" ]]; then
    ok "UIFileSharingEnabled (Debug) = true"
  else
    fail "UIFileSharingEnabled (Debug) = $SHARE_DBG （Debug は true 必須・モデル転送に使う）"
  fi
else
  fail "$DEBUG_PLIST が存在しない"
fi

echo ""
echo "=== xcconfig → Info.plist マッピング ==="
# Release が誤って Info-Debug.plist を指していないか（UIFileSharingEnabled=true のまま提出される事故を防ぐ）
REL_INFO=$(grep -E "^INFOPLIST_FILE\s*=" "$RELEASE_XCCONFIG" | sed 's/.*=\s*//' | tr -d '[:space:]')
if [[ "$REL_INFO" == "eMeishi/Info.plist" ]]; then
  ok "Release.xcconfig INFOPLIST_FILE = $REL_INFO"
else
  fail "Release.xcconfig INFOPLIST_FILE = $REL_INFO （eMeishi/Info.plist 必須）"
fi
DBG_INFO=$(grep -E "^INFOPLIST_FILE\s*=" "$DEBUG_XCCONFIG" | sed 's/.*=\s*//' | tr -d '[:space:]')
if [[ "$DBG_INFO" == "eMeishi/Info-Debug.plist" ]]; then
  ok "Debug.xcconfig INFOPLIST_FILE = $DBG_INFO"
else
  fail "Debug.xcconfig INFOPLIST_FILE = $DBG_INFO （eMeishi/Info-Debug.plist 必須）"
fi

echo ""
echo "=== 署名資産（asc）==="
ASC_BIN="$HOME/.blitz/bin/asc"
if [[ -x "$ASC_BIN" ]]; then
  DIST_COUNT=$("$ASC_BIN" certificates list 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(1 for c in d.get('data',[]) if c['attributes']['certificateType']=='DISTRIBUTION'))" 2>/dev/null || echo "0")
  if [[ "$DIST_COUNT" -ge 1 ]] 2>/dev/null; then
    ok "Distribution 証明書: $DIST_COUNT 件"
  else
    fail "Distribution 証明書が 0 件（asc certificates list で確認）"
  fi

  PROFILE_OK=$("$ASC_BIN" profiles list 2>/dev/null \
    | python3 -c "
import sys,json
d = json.load(sys.stdin)
for p in d.get('data', []):
    a = p['attributes']
    if a.get('profileType') == 'IOS_APP_STORE' and a.get('profileState') == 'ACTIVE' and a.get('name', '').startswith('$BUNDLE_ID'):
        print('ok'); sys.exit(0)
print('ng')
" 2>/dev/null || echo "ng")
  if [[ "$PROFILE_OK" == "ok" ]]; then
    ok "IOS_APP_STORE プロファイル ACTIVE（${BUNDLE_ID}）"
  else
    fail "IOS_APP_STORE プロファイルが未作成または expired（asc profiles list で確認）"
  fi
else
  fail "asc CLI が見つからない: $ASC_BIN"
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
  # 古いセンチネルを削除（前回 PASS が残っていても無効化）
  rm -f .release-check-ok
  exit 1
fi
echo "全項目 PASS。ユーザー承認後にアーカイブ可。"

# センチネルファイルを生成（guard-git.sh が release/* push 前に確認）
COMMIT_HASH=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
echo "$COMMIT_HASH" > .release-check-ok
echo "  センチネル生成: .release-check-ok（commit: ${COMMIT_HASH:0:7}）"
