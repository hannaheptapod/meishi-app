#!/bin/bash
# PreToolUse hook: git 操作の安全ガード
# - main / develop への直接コミット・マージ・push をブロック
# - 規定外プレフィックスのブランチ作成をブロック

INPUT=$(cat)

# JSON パース（python3 優先、jq フォールバック）
if command -v python3 &>/dev/null; then
  TOOL_NAME=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name',''))" 2>/dev/null)
  COMMAND=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null)
elif command -v jq &>/dev/null; then
  TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
else
  exit 0
fi

# Bash ツール以外はスルー
[ "$TOOL_NAME" != "Bash" ] && exit 0

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

# ① main・develop への直接コミット・マージをブロック
if echo "$COMMAND" | grep -qE "git (commit|merge)"; then
  if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "develop" ]; then
    echo "❌ BLOCKED: '$BRANCH' への直接コミット・マージは禁止です。" >&2
    echo "  feature/* または fix/* ブランチを作成し、PR を通してください。" >&2
    echo "  → /branch を実行して正しいブランチに切り替えてください。" >&2
    exit 2
  fi
fi

# ② main・develop への直接 push をブロック
if echo "$COMMAND" | grep -qE "git push"; then
  if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "develop" ]; then
    echo "❌ BLOCKED: '$BRANCH' への直接 push は禁止です。PR を通してください。" >&2
    exit 2
  fi
  if echo "$COMMAND" | grep -qE "(origin main|origin develop| main$| develop$|:main|:develop)"; then
    echo "❌ BLOCKED: main・develop への直接 push は禁止です。PR を通してください。" >&2
    exit 2
  fi
fi

# ③ 規定外プレフィックスのブランチ作成をブロック
if echo "$COMMAND" | grep -qE "git (checkout -b|switch -c)"; then
  NEW_BRANCH=$(echo "$COMMAND" | grep -oE "\-(b|c)\s+\S+" | awk '{print $NF}' | head -1)
  if [ -n "$NEW_BRANCH" ]; then
    VALID=false
    for p in feature fix release hotfix docs chore; do
      if echo "$NEW_BRANCH" | grep -q "^${p}/"; then
        VALID=true
        break
      fi
    done
    if [ "$VALID" = false ]; then
      echo "❌ BLOCKED: ブランチ名 '$NEW_BRANCH' は規定外プレフィックスです。" >&2
      echo "  使用可能: feature/ fix/ release/ hotfix/ docs/ chore/" >&2
      echo "  → /branch を実行して正しいブランチ名を生成してください。" >&2
      exit 2
    fi
  fi
fi

exit 0
