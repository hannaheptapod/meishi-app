#!/usr/bin/env bash
# Xcode Cloud: xcodebuild 実行後の処理
# Archive 完了後・Xcode Cloud の再署名（エクスポート）前に実行される
# CI_ARCHIVE_PATH のアーカイブ内 Info.plist を直接書き換えてビルド番号を上書きする

set -euo pipefail

echo "=== ci_post_xcodebuild ($CI_XCODEBUILD_ACTION) ==="

if [[ "$CI_XCODEBUILD_ACTION" == "archive" ]]; then
  echo "  Branch:  $CI_BRANCH"
  echo "  Commit:  $CI_COMMIT"
  echo "  Build:   $CI_BUILD_NUMBER"
  echo "  Workflow: $CI_WORKFLOW"
  echo "  Archive: ${CI_ARCHIVE_PATH:-未設定}"

  if [[ -n "${CI_BUILD_NUMBER:-}" ]] && [[ -n "${CI_ARCHIVE_PATH:-}" ]]; then
    DATE_PREFIX=$(date -u +"%Y%m%d")
    SEQ=$(printf "%03d" $(( (CI_BUILD_NUMBER % 999) + 1 )))
    NEW_BUILD_NUMBER="${DATE_PREFIX}${SEQ}"

    echo ""
    echo "=== ビルド番号設定 ==="
    echo "  CI_BUILD_NUMBER: $CI_BUILD_NUMBER"
    echo "  設定値: $NEW_BUILD_NUMBER"

    # アーカイブ内 App Bundle の Info.plist を更新
    APP_PLIST="${CI_ARCHIVE_PATH}/Products/Applications/eMeishi.app/Info.plist"
    if [[ -f "$APP_PLIST" ]]; then
      BEFORE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PLIST")
      /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD_NUMBER" "$APP_PLIST"
      AFTER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PLIST")
      echo "  [OK] Archive CFBundleVersion: $BEFORE → $AFTER"
    else
      echo "  [WARN] $APP_PLIST が見つかりません。フォールバック検索..."
      find "${CI_ARCHIVE_PATH}/Products" -name "Info.plist" 2>/dev/null | while read -r plist; do
        echo "  検索結果: $plist"
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD_NUMBER" "$plist" && \
          echo "  [OK] CFBundleVersion → $NEW_BUILD_NUMBER ($plist)"
      done
    fi

    # アーカイブメタデータ（Info.plist）も更新
    ARCHIVE_META="${CI_ARCHIVE_PATH}/Info.plist"
    if [[ -f "$ARCHIVE_META" ]]; then
      /usr/libexec/PlistBuddy -c "Set :ApplicationProperties:CFBundleVersion $NEW_BUILD_NUMBER" \
        "$ARCHIVE_META" 2>/dev/null && \
        echo "  [OK] Archive metadata CFBundleVersion → $NEW_BUILD_NUMBER" || \
        echo "  [SKIP] Archive metadata 更新スキップ（キーなし）"
    fi

    # ============================================================
    # エクスポート済み App Bundle をパッチして再署名
    # ------------------------------------------------------------
    # Xcode Cloud の export は ci_post_xcodebuild.sh より先に実行され、
    # ExportOptions.plist に buildNumber=CI_BUILD_NUMBER（連番）を注入する。
    # その結果 IPA の CFBundleVersion が連番で上書きされるため、
    # ci_post_xcodebuild.sh（export 後・TestFlight アップロード前）で修正する。
    # ============================================================
    echo ""
    echo "=== エクスポート済み App Bundle パッチ ==="

    # デバッグ: 利用可能な CI 変数を確認
    echo "  CI_APP_STORE_SIGNED_APP_PATH: ${CI_APP_STORE_SIGNED_APP_PATH:-未設定}"
    echo "  CI_PRODUCT_DIRECTORY:         ${CI_PRODUCT_DIRECTORY:-未設定}"
    echo "  CI_AD_HOC_SIGNED_APP_PATH:    ${CI_AD_HOC_SIGNED_APP_PATH:-未設定}"

    # 署名 ID を取得（Apple Distribution / iPhone Distribution）
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
      | grep -E '"Apple Distribution:|iPhone Distribution:' \
      | head -1 | awk -F'"' '{print $2}' || true)
    echo "  署名 ID: ${SIGN_ID:-（なし）}"

    patch_and_resign() {
      local app_path="$1"
      local info_plist="${app_path}/Info.plist"

      if [[ ! -f "$info_plist" ]]; then
        echo "  [WARN] Info.plist が見つかりません: $info_plist"
        return 1
      fi

      local current
      current=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$info_plist" 2>/dev/null || echo "UNKNOWN")

      if [[ "$current" == "$NEW_BUILD_NUMBER" ]]; then
        echo "  [SKIP] CFBundleVersion は既に $NEW_BUILD_NUMBER"
        return 0
      fi

      /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD_NUMBER" "$info_plist"
      echo "  CFBundleVersion: $current → $NEW_BUILD_NUMBER"

      if [[ -z "${SIGN_ID:-}" ]]; then
        echo "  [WARN] Distribution 証明書なし。再署名スキップ（署名無効になる可能性あり）"
        return 0
      fi

      # 1. Frameworks
      if [[ -d "${app_path}/Frameworks" ]]; then
        while IFS= read -r -d '' fw; do
          codesign --force --sign "$SIGN_ID" \
            --preserve-metadata=entitlements,identifier,flags "$fw" 2>/dev/null || true
        done < <(find "${app_path}/Frameworks" -name "*.framework" -print0 2>/dev/null)
      fi

      # 2. App Extensions
      if [[ -d "${app_path}/PlugIns" ]]; then
        while IFS= read -r -d '' ext; do
          codesign --force --sign "$SIGN_ID" \
            --preserve-metadata=entitlements "$ext" 2>/dev/null || true
        done < <(find "${app_path}/PlugIns" -name "*.appex" -print0 2>/dev/null)
      fi

      # 3. メイン App
      codesign --force --sign "$SIGN_ID" \
        --preserve-metadata=entitlements,identifier,flags "$app_path"
      echo "  [OK] 再署名完了: $app_path"
    }

    # --- 方法 A: CI_APP_STORE_SIGNED_APP_PATH ---
    if [[ -n "${CI_APP_STORE_SIGNED_APP_PATH:-}" ]] && [[ -d "$CI_APP_STORE_SIGNED_APP_PATH" ]]; then
      echo "  対象 (A): $CI_APP_STORE_SIGNED_APP_PATH"
      patch_and_resign "$CI_APP_STORE_SIGNED_APP_PATH" || true

    # --- 方法 B: CI_PRODUCT_DIRECTORY 内の IPA を展開してパッチ ---
    elif [[ -n "${CI_PRODUCT_DIRECTORY:-}" ]] && [[ -d "$CI_PRODUCT_DIRECTORY" ]]; then
      IPA_PATH=$(find "$CI_PRODUCT_DIRECTORY" -name "*.ipa" -maxdepth 3 | head -1 || true)
      if [[ -n "$IPA_PATH" ]]; then
        echo "  対象 (B): $IPA_PATH"
        WORK_DIR=$(mktemp -d)
        # エラー時に作業ディレクトリを削除
        cleanup() { rm -rf "$WORK_DIR"; }
        trap cleanup EXIT

        cp "$IPA_PATH" "$WORK_DIR/app.ipa"
        pushd "$WORK_DIR" >/dev/null
        unzip -q app.ipa

        PAYLOAD_APP=$(find Payload -name "*.app" -maxdepth 1 | head -1 || true)
        if [[ -n "$PAYLOAD_APP" ]]; then
          patch_and_resign "$PAYLOAD_APP" || true
          # 元の IPA を上書き
          zip -qr "$IPA_PATH" Payload/
          echo "  [OK] IPA 更新完了"
        else
          echo "  [WARN] Payload/*.app が見つかりません"
        fi

        popd >/dev/null
        rm -rf "$WORK_DIR"
        trap - EXIT
      else
        echo "  [INFO] IPA が見つかりません"
      fi
    else
      echo "  [INFO] CI_APP_STORE_SIGNED_APP_PATH も CI_PRODUCT_DIRECTORY も未設定"
      echo "         次のビルドのログで上記デバッグ変数を確認してください"
    fi

    # --- フォールバック: /Volumes/workspace/tmp 以下を検索 ---
    echo ""
    echo "  === Workspace tmp 検索（デバッグ） ==="
    find /Volumes/workspace/tmp -name "Info.plist" -path "*/Applications/*.app/Info.plist" 2>/dev/null | head -5 | while read -r p; do
      VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$p" 2>/dev/null || echo "?")
      echo "  found: $p  CFBundleVersion=$VER"
    done || true

  else
    echo "  [SKIP] CI_BUILD_NUMBER または CI_ARCHIVE_PATH が未設定"
  fi
fi

if [[ "$CI_XCODEBUILD_ACTION" == "test" ]] || [[ "$CI_XCODEBUILD_ACTION" == "test-without-building" ]]; then
  echo "  テスト完了"
  echo "  Branch: $CI_BRANCH"
  echo "  Commit: $CI_COMMIT"
fi
