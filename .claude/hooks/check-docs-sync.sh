#!/bin/bash
# Stop hook: タスク完了時に CLAUDE.md / README.md との整合性確認を促す
# 実装変更を伴うコミットがある場合のみ表示する

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

# main / develop はそもそも直接作業しないので除外
[ "$BRANCH" = "main" ] || [ "$BRANCH" = "develop" ] && exit 0

# 直近コミット・ステージング・未コミット変更に Swift ファイルが含まれているか確認
SWIFT_COMMITTED=$(git diff --name-only HEAD~1 HEAD 2>/dev/null | grep -c "\.swift$" || echo 0)
SWIFT_STAGED=$(git diff --cached --name-only 2>/dev/null | grep -c "\.swift$" || echo 0)
SWIFT_CHANGED=$(git diff --name-only 2>/dev/null | grep -c "\.swift$" || echo 0)

if [ "$SWIFT_COMMITTED" -gt 0 ] || [ "$SWIFT_STAGED" -gt 0 ] || [ "$SWIFT_CHANGED" -gt 0 ]; then
  echo "📋 実装変更を検出しました。以下を確認してください："
  echo "  1. CLAUDE.md の記述と実装内容がズレていないか"
  echo "  2. README.md の機能説明・ディレクトリ構成が最新か"
  echo "  ズレがある場合は同じ PR で更新してください（CLAUDE.md ルール）"
fi

exit 0
