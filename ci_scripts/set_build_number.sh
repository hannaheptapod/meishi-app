#!/usr/bin/env bash
# Xcode Build Phase から呼び出されるビルド番号設定スクリプト
# CI_BUILD_NUMBER が未設定（ローカルビルド）の場合はスキップ
#
# 目的: Xcode Cloud は ci_pre_xcodebuild.sh の直後に agvtool を実行し
# Info.plist の CFBundleVersion を CI_BUILD_NUMBER（連番）で上書きする。
# Run Script Build Phase は agvtool の後かつコード署名前に実行されるため、
# OUTPUT の Info.plist を直接書き換えることで連番上書きを回避できる。

[ -z "${CI_BUILD_NUMBER:-}" ] && exit 0

DATE_PREFIX=$(date -u +"%Y%m%d")
SEQ=$(printf "%03d" $(( (CI_BUILD_NUMBER % 999) + 1 )))
NEW_BUILD_NUMBER="${DATE_PREFIX}${SEQ}"

PROCESSED_PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ -f "$PROCESSED_PLIST" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD_NUMBER" "$PROCESSED_PLIST"
  echo "note: CFBundleVersion → $NEW_BUILD_NUMBER (CI_BUILD_NUMBER=${CI_BUILD_NUMBER})"
else
  echo "warning: Info.plist not found at ${PROCESSED_PLIST}"
fi
