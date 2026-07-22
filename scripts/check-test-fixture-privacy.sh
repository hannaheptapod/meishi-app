#!/usr/bin/env bash

# ユーザー提供データが回帰テストや文書へ転用される事故を防ぐ。
# 自動判定できる範囲として、追加行の実在メールドメインと、テスト配下へ
# 新規追加された画像・文書fixtureを拒否する。氏名など機械判定できない値は
# AGENTS.md のレビュー規則と併用する。

set -euo pipefail

ROOTS=(eMeishiTests eMeishiUITests README.md)
TEMP_ADDITIONS="$(mktemp)"
trap 'rm -f "$TEMP_ADDITIONS"' EXIT

append_added_lines() {
  git diff --unified=0 "$@" -- "${ROOTS[@]}" 2>/dev/null \
    | awk '/^\+[^+]/{sub(/^\+/, ""); print}' >> "$TEMP_ADDITIONS"
}

if git rev-parse --verify origin/develop >/dev/null 2>&1; then
  BASE="$(git merge-base HEAD origin/develop)"
  append_added_lines "$BASE" HEAD
fi
append_added_lines

while IFS= read -r file; do
  [[ -f "$file" ]] || continue
  case "$file" in
    *.swift|*.md) sed 's/^/+/' "$file" | sed 's/^+//' >> "$TEMP_ADDITIONS" ;;
  esac
done < <(git ls-files --others --exclude-standard -- "${ROOTS[@]}")

INVALID_DOMAIN_COUNT="$({
  grep -Eo '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$TEMP_ADDITIONS" || true
} | awk -F@ '
  {
    domain = tolower($2)
    if (domain != "example.com" &&
        domain != "example.jp" &&
        domain != "example.co.jp" &&
        domain != "example.invalid") {
      invalid++
    }
  }
  END { print invalid + 0 }
')"

if [[ "$INVALID_DOMAIN_COUNT" -gt 0 ]]; then
  echo "追加されたテスト・文書に例示用ではないメールドメインがあります。"
  echo "example.com / example.jp / example.co.jp / example.invalid の合成データへ置換してください。"
  exit 1
fi

INVALID_FIXTURE_COUNT=0
while IFS= read -r file; do
  lowercase_file="$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')"
  case "$lowercase_file" in
    emeishitests/*|emeishiuitests/*)
      case "$lowercase_file" in
        *.png|*.jpg|*.jpeg|*.heic|*.tif|*.tiff|*.pdf|*.vcf|*.csv)
          INVALID_FIXTURE_COUNT=$((INVALID_FIXTURE_COUNT + 1))
          ;;
      esac
      ;;
  esac
done < <(git diff --name-only --diff-filter=A HEAD -- eMeishiTests eMeishiUITests; git ls-files --others --exclude-standard -- eMeishiTests eMeishiUITests)

if [[ "$INVALID_FIXTURE_COUNT" -gt 0 ]]; then
  echo "テスト配下に画像・連絡先・書出しfixtureが追加されています。"
  echo "ユーザー提供物ではなく、コード生成した合成データであることを確認できる設計へ変更してください。"
  exit 1
fi

echo "テストデータの個人情報ガード: PASS"
