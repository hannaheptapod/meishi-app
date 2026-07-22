#!/usr/bin/env bash

# UIテストのクラス名誤指定と「0件成功」の見逃しを防ぐラッパー。
# 使い方:
#   DESTINATION='platform=iOS Simulator,id=<UDID>' \
#     ./scripts/run-selected-ui-tests.sh testToolbarButtonsExist testUnifiedSearchUsesOneStandardSearchField

set -euo pipefail

cd "$(dirname "$0")/.."

readonly PROJECT="eMeishi.xcodeproj"
readonly SCHEME="eMeishi"
readonly TEST_TARGET="eMeishiUITests"
readonly TEST_CLASS="EMeishiUITests"
readonly TEST_SOURCE="eMeishiUITests/eMeishiUITests.swift"
readonly DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
readonly DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/eMeishi-selected-ui-tests-derived}"

if [[ "$#" -eq 0 ]]; then
    echo "使用方法: $0 <testMethod> [testMethod ...]" >&2
    exit 64
fi

if ! rg -q "final class ${TEST_CLASS}: XCTestCase" "$TEST_SOURCE"; then
    echo "✗ UIテストクラス ${TEST_CLASS} が ${TEST_SOURCE} に見つかりません" >&2
    exit 65
fi

only_testing_args=()
for test_method in "$@"; do
    if [[ ! "$test_method" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "✗ 不正なテストメソッド名です: ${test_method}" >&2
        exit 64
    fi
    if ! rg -q "func ${test_method}\(" "$TEST_SOURCE"; then
        echo "✗ UIテスト ${TEST_CLASS}.${test_method} が見つかりません" >&2
        exit 65
    fi
    only_testing_args+=("-only-testing:${TEST_TARGET}/${TEST_CLASS}/${test_method}")
done

log_file="$(mktemp -t emeishi-ui-tests.XXXXXX)"
trap 'rm -f "$log_file"' EXIT

set +e
xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    "${only_testing_args[@]}" 2>&1 | tee "$log_file"
xcodebuild_status=${PIPESTATUS[0]}
set -e

if [[ "$xcodebuild_status" -ne 0 ]]; then
    echo "✗ xcodebuild test が失敗しました (exit ${xcodebuild_status})" >&2
    exit "$xcodebuild_status"
fi

expected_count="$#"
executed_count="$({ rg -o 'Executed [0-9]+ tests?, with 0 failures' "$log_file" || true; } \
    | sed -E 's/Executed ([0-9]+) tests?, with 0 failures/\1/' \
    | awk '$1 > maximum { maximum = $1 } END { print maximum + 0 }')"

if [[ "$executed_count" -ne "$expected_count" ]]; then
    echo "✗ 指定${expected_count}件に対して実行${executed_count}件でした。未実行・重複実行を成功として扱いません" >&2
    exit 2
fi

echo "✓ 指定UIテスト${expected_count}件をすべて実行し、失敗0件を確認しました"
