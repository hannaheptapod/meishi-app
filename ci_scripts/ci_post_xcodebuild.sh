#!/usr/bin/env bash
# Xcode Cloud: xcodebuild 実行後の処理
#
# Xcode Cloud の自動 Export は manageAppVersionAndBuildNumber=true で
# CFBundleVersion を CI_BUILD_NUMBER に上書きする。これを避けるため、
# ワークフローの Distribution Preparation を None に設定し、
# ここで自前の ExportOptions.plist (manageAppVersionAndBuildNumber=false)
# を使って xcodebuild -exportArchive + altool で TestFlight へアップロードする。
#
# 必要な Xcode Cloud 環境変数（Secret）:
#   ASC_API_KEY_ID      : App Store Connect API Key の Key ID
#   ASC_API_ISSUER_ID   : Issuer ID
#   ASC_API_KEY_P8      : .p8 ファイルの中身全体（BEGIN/END 行含む）

set -euo pipefail

echo "=== ci_post_xcodebuild ($CI_XCODEBUILD_ACTION) ==="

if [[ "$CI_XCODEBUILD_ACTION" != "archive" ]]; then
  echo "  [SKIP] archive 以外は処理なし"
  exit 0
fi

echo "  Branch:   $CI_BRANCH"
echo "  Commit:   $CI_COMMIT"
echo "  Workflow: $CI_WORKFLOW"
echo "  Archive:  ${CI_ARCHIVE_PATH:-未設定}"

if [[ -z "${CI_ARCHIVE_PATH:-}" ]] || [[ ! -d "${CI_ARCHIVE_PATH}" ]]; then
  echo "  [ERROR] CI_ARCHIVE_PATH が無効です"
  exit 1
fi

# archive 内 CFBundleVersion 確認（ci_pre_xcodebuild.sh の agvtool 結果）
APP_PLIST="${CI_ARCHIVE_PATH}/Products/Applications/eMeishi.app/Info.plist"
if [[ -f "$APP_PLIST" ]]; then
  CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PLIST")
  echo "  Archive CFBundleVersion: $CURRENT_VERSION"
fi

# --- 環境変数チェック ---
if [[ -z "${ASC_API_KEY_ID:-}" ]] || [[ -z "${ASC_API_ISSUER_ID:-}" ]] || [[ -z "${ASC_API_KEY_P8:-}" ]]; then
  echo "  [ERROR] ASC_API_KEY_ID / ASC_API_ISSUER_ID / ASC_API_KEY_P8 が未設定です"
  echo "         Xcode Cloud の環境変数（Secret）に追加してください"
  exit 1
fi

# --- .p8 ファイルを altool が読める場所に配置 ---
PRIVATE_KEYS_DIR="$HOME/private_keys"
mkdir -p "$PRIVATE_KEYS_DIR"
P8_FILE="${PRIVATE_KEYS_DIR}/AuthKey_${ASC_API_KEY_ID}.p8"
printf '%s' "$ASC_API_KEY_P8" > "$P8_FILE"
chmod 600 "$P8_FILE"
echo "  [OK] .p8 ファイル配置: $P8_FILE"

# --- 自前 Export ---
EXPORT_DIR="${CI_PRIMARY_REPOSITORY_PATH}/build/export"
EXPORT_OPTIONS="${CI_PRIMARY_REPOSITORY_PATH}/ci_scripts/ExportOptions.plist"
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

echo ""
echo "=== 自前 Export（manageAppVersionAndBuildNumber=false） ==="
xcodebuild -exportArchive \
  -archivePath "$CI_ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$P8_FILE" \
  -authenticationKeyID "$ASC_API_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_API_ISSUER_ID"

IPA_PATH=$(find "$EXPORT_DIR" -name "*.ipa" -maxdepth 2 | head -1)
if [[ -z "$IPA_PATH" ]]; then
  echo "  [ERROR] IPA が生成されませんでした"
  ls -la "$EXPORT_DIR"
  exit 1
fi
echo "  [OK] IPA 生成: $IPA_PATH"

# IPA 内 CFBundleVersion 確認
TMP_VERIFY=$(mktemp -d)
unzip -q "$IPA_PATH" -d "$TMP_VERIFY"
VERIFY_PLIST=$(find "$TMP_VERIFY/Payload" -name "Info.plist" -maxdepth 2 | head -1)
if [[ -f "$VERIFY_PLIST" ]]; then
  IPA_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$VERIFY_PLIST")
  echo "  IPA CFBundleVersion: $IPA_VERSION"
fi
rm -rf "$TMP_VERIFY"

# --- TestFlight アップロード ---
echo ""
echo "=== TestFlight アップロード（altool） ==="
xcrun altool --upload-app \
  --type ios \
  --file "$IPA_PATH" \
  --apiKey "$ASC_API_KEY_ID" \
  --apiIssuer "$ASC_API_ISSUER_ID"

echo "  [OK] アップロード完了"
