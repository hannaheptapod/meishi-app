#!/bin/bash
# PreToolUse hook: ファイル編集の安全ガード（Edit / Write / NotebookEdit）
# 以下をブロックする（exit 2）:
#   ① project.pbxproj の直接編集（Xcode で行うこと）
#   ② .xcdatamodeld の直接編集（Xcode エディタ + マイグレーション手順に従うこと）
#   ③ .env / .p8 / secrets への書き込み

INPUT=$(cat)

if command -v python3 &>/dev/null; then
  TOOL_NAME=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name',''))" 2>/dev/null)
  FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))" 2>/dev/null)
elif command -v jq &>/dev/null; then
  TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
else
  exit 0
fi

# Edit・Write・NotebookEdit のみ対象
case "$TOOL_NAME" in
  Edit|Write|NotebookEdit) ;;
  *) exit 0 ;;
esac

# ① project.pbxproj の直接編集をブロック
if echo "$FILE_PATH" | grep -qE "project\.pbxproj$"; then
  echo "❌ BLOCKED: project.pbxproj の直接編集は禁止です。" >&2
  echo "  変更は Xcode で行い、生成された差分をコミットしてください。" >&2
  echo "  MARKETING_VERSION 変更: Xcode → Target → General → Version" >&2
  exit 2
fi

# ② .xcdatamodeld の直接編集をブロック
if echo "$FILE_PATH" | grep -qE "\.xcdatamodeld/"; then
  echo "❌ BLOCKED: .xcdatamodeld の直接編集は禁止です。" >&2
  echo "  CoreData モデル変更は Xcode エディタで行い、マイグレーション手順に従ってください。" >&2
  exit 2
fi

# ③ 秘密情報ファイルへの書き込みをブロック
if echo "$FILE_PATH" | grep -qE "(^|/)\.(env)(\.|$)|(^|/)\.(env)$|\.p8$|(^|/)secrets/(^|/)private/"; then
  echo "❌ BLOCKED: 秘密情報ファイルへの書き込みは禁止です: $FILE_PATH" >&2
  exit 2
fi

exit 0
