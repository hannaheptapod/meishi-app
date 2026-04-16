#!/bin/bash
# PreToolUse hook: git 操作の安全ガード
# 以下を機械的にブロックする（exit 2）:
#   ① main・develop への直接 commit / merge
#   ② force push（--force / --force-with-lease）
#   ③ release/* への push — 非 release/* ブランチからは無条件ブロック
#                          — release/* ブランチからは .release-check-ok sentinel 必須
#   ④ main・develop への直接 push（コマンド文字列検査）
#   ⑤ 規定外プレフィックスのブランチ作成

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

# ① main・develop への直接 commit / merge をブロック
if echo "$COMMAND" | grep -qE "git (commit|merge)"; then
  if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "develop" ]; then
    echo "❌ BLOCKED: '$BRANCH' への直接コミット・マージは禁止です。" >&2
    echo "  feature/* または fix/* ブランチを作成し、PR を通してください。" >&2
    echo "  → /branch を実行して正しいブランチに切り替えてください。" >&2
    exit 2
  fi
fi

# ② force push を無条件ブロック
if echo "$COMMAND" | grep -qE "git push" && echo "$COMMAND" | grep -qE "(\s-f\b|--force\b|--force-with-lease\b)"; then
  echo "❌ BLOCKED: force push は禁止です（--force / --force-with-lease）。" >&2
  exit 2
fi

# ③ release/* への push を厳格にガード
#    - --delete は除外
#    - 現在ブランチが release/* かつ sentinel 一致 → 許可
#    - それ以外（非 release/* ブランチからの push、sentinel 不一致）→ ブロック
if echo "$COMMAND" | grep -qE "git push"; then
  # push 先が release/* かどうかを判定（現在ブランチ OR コマンド文字列）
  PUSH_TO_RELEASE=false
  if echo "$BRANCH" | grep -qE "^release/"; then
    PUSH_TO_RELEASE=true
  fi
  if echo "$COMMAND" | grep -qE "release/" && ! echo "$COMMAND" | grep -qE "(--delete|-d)\b"; then
    PUSH_TO_RELEASE=true
  fi

  if [ "$PUSH_TO_RELEASE" = true ] && ! echo "$COMMAND" | grep -qE "(--delete|-d)\b"; then
    # 非 release/* ブランチからは無条件ブロック
    if ! echo "$BRANCH" | grep -qE "^release/"; then
      echo "❌ BLOCKED: release/* への push は release/* ブランチからのみ許可されます。" >&2
      echo "  現在のブランチ: $BRANCH" >&2
      echo "  release/* への push は Xcode Cloud Archive を起動します。" >&2
      exit 2
    fi
    # sentinel ファイル確認
    if [ ! -f ".release-check-ok" ]; then
      echo "❌ BLOCKED: ./scripts/pre-build-check.sh を実行し、全 PASS を確認してください。" >&2
      echo "  PASS 後にセンチネル (.release-check-ok) が生成され、この guard が解除されます。" >&2
      exit 2
    fi
    SENTINEL_COMMIT=$(cat .release-check-ok 2>/dev/null || echo "")
    CURRENT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
    if [ "$SENTINEL_COMMIT" != "$CURRENT_COMMIT" ]; then
      echo "❌ BLOCKED: コミットが更新されたため pre-build-check.sh を再実行してください。" >&2
      echo "  チェック時: ${SENTINEL_COMMIT:0:7}  現在: ${CURRENT_COMMIT:0:7}" >&2
      exit 2
    fi
    echo "✅ pre-build-check.sh PASS 確認（commit: ${CURRENT_COMMIT:0:7}）" >&2
    echo "⚠️  push 後、Xcode Cloud Release Build（Archive）が自動起動します。" >&2
  fi
fi

# ④ main・develop への直接 push をブロック
if echo "$COMMAND" | grep -qE "git push"; then
  if echo "$COMMAND" | grep -qE "(--delete|-d)\b"; then
    : # ブランチ削除は許可
  else
    if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "develop" ]; then
      echo "❌ BLOCKED: '$BRANCH' への直接 push は禁止です。PR を通してください。" >&2
      exit 2
    fi
    if echo "$COMMAND" | grep -qE "(origin main|origin develop|\smain$|\sdevelop$|:main\b|:develop\b)"; then
      echo "❌ BLOCKED: main・develop への直接 push は禁止です。PR を通してください。" >&2
      exit 2
    fi
  fi
fi

# ⑤ 破壊的 git 操作をブロック
# git reset --hard
if echo "$COMMAND" | grep -qE "git reset\s+--hard"; then
  echo "❌ BLOCKED: git reset --hard は禁止です（作業内容が失われる可能性があります）。" >&2
  exit 2
fi
# git clean -f
if echo "$COMMAND" | grep -qE "git clean\s+.*-f"; then
  echo "❌ BLOCKED: git clean -f は禁止です（未追跡ファイルが削除されます）。" >&2
  exit 2
fi
# タグの push（vX.Y.Z タグ打ちはユーザー操作）
if echo "$COMMAND" | grep -qE "git push.*(--tags|refs/tags|:\s*v[0-9])"; then
  echo "❌ BLOCKED: タグの push はユーザーが行う操作です。" >&2
  exit 2
fi
# release/* / main / develop ブランチの強制削除をブロック
if echo "$COMMAND" | grep -qE "git branch\s+-D"; then
  DEL_BRANCH=$(echo "$COMMAND" | grep -oE "\-D\s+\S+" | awk '{print $NF}')
  if echo "$DEL_BRANCH" | grep -qE "^(main|develop|release/)"; then
    echo "❌ BLOCKED: '$DEL_BRANCH' の強制削除は禁止です。ブランチ削除はユーザーが行います。" >&2
    exit 2
  fi
fi

# ⑦ 規定外プレフィックスのブランチ作成をブロック
if echo "$COMMAND" | grep -qE "git (checkout -b|switch -c)"; then
  NEW_BRANCH=$(echo "$COMMAND" | grep -oE "\-(b|c)\s+\S+" | awk '{print $NF}' | head -1)
  if [ -n "$NEW_BRANCH" ]; then
    VALID=false
    for p in feature fix refactor release hotfix docs chore; do
      if echo "$NEW_BRANCH" | grep -q "^${p}/"; then
        VALID=true
        break
      fi
    done
    if [ "$VALID" = false ]; then
      echo "❌ BLOCKED: ブランチ名 '$NEW_BRANCH' は規定外プレフィックスです。" >&2
      echo "  使用可能: feature/ fix/ refactor/ release/ hotfix/ docs/ chore/" >&2
      echo "  → /branch を実行して正しいブランチ名を生成してください。" >&2
      exit 2
    fi
  fi
fi

exit 0
