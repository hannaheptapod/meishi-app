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
# ビルド番号（CURRENT_PROJECT_VERSION）は Xcode Cloud が CI_BUILD_NUMBER を自動注入する。
# ローカル値の大小チェックは Xcode Cloud と二重管理になるためスキップ。
LATEST=$(~/.blitz/bin/asc builds list --app 6761180218 --platform IOS --limit 3 2>/dev/null \
  | python3 -c "import sys,json; b=json.load(sys.stdin)['data']; print(b[0]['attributes']['version']) if b else print('none')")
CURRENT=$(~/.blitz/bin/asc xcode version view 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['buildNumber'])")
echo "  ASC最新: ${LATEST}  プロジェクト: ${CURRENT}（Xcode Cloud が自動更新するためチェックスキップ）"
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
    ok "plutil -lint OK (${DEBUG_PLIST})"
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

# 署名資産（Distribution 証明書・プロビジョニングプロファイル）は
# Xcode Cloud の Automatic Signing が自動管理するためチェックしない。
# ci_scripts/ci_pre_xcodebuild.sh でも [SKIP] と明記済み。

echo ""
echo "=== Swift 言語モード（Issue #147 Phase 6 で確定）==="
# Swift 6 言語モード必須。SWIFT_VERSION = 6.0 / SWIFT_STRICT_CONCURRENCY = complete
# を両 xcconfig で強制する。ダウングレードは Swift 5 の警告緩和設定と整合せず
# regression を招くため禁止。
REL_STRICT=$(grep -E "^SWIFT_STRICT_CONCURRENCY\s*=" "$RELEASE_XCCONFIG" | sed 's/.*=\s*//' | tr -d '[:space:]')
DBG_STRICT=$(grep -E "^SWIFT_STRICT_CONCURRENCY\s*=" "$DEBUG_XCCONFIG" | sed 's/.*=\s*//' | tr -d '[:space:]')
REL_SVER=$(grep -E "^SWIFT_VERSION\s*=" "$RELEASE_XCCONFIG" | sed 's/.*=\s*//' | tr -d '[:space:]')
DBG_SVER=$(grep -E "^SWIFT_VERSION\s*=" "$DEBUG_XCCONFIG" | sed 's/.*=\s*//' | tr -d '[:space:]')
if [[ "$REL_STRICT" == "complete" ]]; then
  ok "SWIFT_STRICT_CONCURRENCY (Release) = complete"
else
  fail "SWIFT_STRICT_CONCURRENCY (Release) = '${REL_STRICT}' （complete 必須）"
fi
if [[ "$DBG_STRICT" == "complete" ]]; then
  ok "SWIFT_STRICT_CONCURRENCY (Debug) = complete"
else
  fail "SWIFT_STRICT_CONCURRENCY (Debug) = '${DBG_STRICT}' （complete 必須）"
fi
if [[ "$REL_SVER" == "6.0" ]]; then
  ok "SWIFT_VERSION (Release) = 6.0"
else
  fail "SWIFT_VERSION (Release) = '${REL_SVER}' （6.0 必須）"
fi
if [[ "$DBG_SVER" == "6.0" ]]; then
  ok "SWIFT_VERSION (Debug) = 6.0"
else
  fail "SWIFT_VERSION (Debug) = '${DBG_SVER}' （6.0 必須）"
fi

# project.pbxproj に SWIFT_VERSION = 5.x が残っていないか直接検証。
# xcconfig は pbxproj に負けるため、xcconfig だけ見ると Swift 5 のまま
# ビルドされる事故が起きる（Phase 7 で実際に発覚）。
PBXPROJ="eMeishi.xcodeproj/project.pbxproj"
SWIFT5_COUNT=$(grep -cE "SWIFT_VERSION = 5\." "$PBXPROJ" || true)
SWIFT6_COUNT=$(grep -cE "SWIFT_VERSION = 6\." "$PBXPROJ" || true)
if [[ "$SWIFT5_COUNT" == "0" ]]; then
  ok "project.pbxproj に SWIFT_VERSION = 5.x 残骸なし"
else
  fail "project.pbxproj に SWIFT_VERSION = 5.x が $SWIFT5_COUNT 箇所残存（Xcode で Swift 6 に変更すること）"
fi
if [[ "$SWIFT6_COUNT" -ge 6 ]]; then
  ok "project.pbxproj の SWIFT_VERSION = 6.x が $SWIFT6_COUNT 箇所（3 ターゲット × Debug/Release）"
else
  fail "project.pbxproj の SWIFT_VERSION = 6.x が $SWIFT6_COUNT 箇所のみ（6 箇所必須）"
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
echo "=== テストデータの個人情報ガード ==="
if ./scripts/check-test-fixture-privacy.sh; then
  ok "ユーザー提供データのテスト・文書転用なし"
else
  fail "テストデータの個人情報ガードに違反"
fi

echo ""
echo "=== UIライフサイクルガード ==="
if ./scripts/check-ui-lifecycle.sh; then
  ok "ルートUI状態・固定時間待機の回帰なし"
else
  fail "UIライフサイクルガードに違反"
fi

echo ""
echo "=== CloudKit Production schema deploy ==="
# CloudKit は Dev → Prod への schema deploy が手動（Dashboard の "Deploy Schema
# Changes" ボタンでのみ反映）。未 deploy のまま TestFlight/本番に出ると、
# NSPersistentCloudKitContainer が mirroring 用 Record Type（CDMR / CD_*）を
# Prod で find できず _pcs_data / _defaultZone に BAD_REQUEST を返し、
# 双方向同期が完全停止する（v1.1.0 本番直前に発覚した事件の再発防止）。
# CloudKit Management API には server-to-server token が必要でこのリポジトリ
# には設定していないため、自動検査は行わず「self-confirm + env override」で
# ヒューマンチェックを強制する。
if [[ -n "${CLOUDKIT_SCHEMA_DEPLOYED:-}" ]]; then
  ok "CloudKit schema deploy 確認（env CLOUDKIT_SCHEMA_DEPLOYED=${CLOUDKIT_SCHEMA_DEPLOYED}）"
elif [[ -t 0 ]]; then
  echo "  確認手順: CloudKit Dashboard → iCloud.com.jinks.emeishi → Development"
  echo "           → Deploy Schema Changes... → 差分確認 → Deploy"
  echo "  確認 URL: https://icloud.developer.apple.com/dashboard/database/teams/9SD55B8AYW/containers/iCloud.com.jinks.emeishi/environments/PRODUCTION/types"
  echo "  （Production 側に CDMR / CD_BusinessCard / CD_Tag / GrandfatherMark が"
  echo "   見えていれば deploy 済み）"
  read -r -p "  Dev → Production への schema deploy は済んでいますか？ [y/N]: " ANS
  if [[ "$ANS" == "y" || "$ANS" == "Y" ]]; then
    ok "CloudKit schema deploy 確認済み"
  else
    fail "CloudKit schema が Production に未 deploy。Dashboard で deploy してから再実行"
  fi
else
  fail "CloudKit schema deploy 確認不能（TTY なし）。CLOUDKIT_SCHEMA_DEPLOYED=1 を指定して再実行"
fi

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
