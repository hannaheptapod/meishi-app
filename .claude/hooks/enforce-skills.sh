#!/bin/bash
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

# 規定プレフィックス確認
VALID=false
for p in feature fix release hotfix docs chore; do
  if echo "$BRANCH" | grep -q "^${p}/"; then
    VALID=true
    break
  fi
done
[ "$BRANCH" = "main" ] || [ "$BRANCH" = "develop" ] && VALID=true

if [ "$VALID" = false ]; then
  echo "【必須】作業前に /branch と /translate を順に実行せよ。現在のブランチ: ${BRANCH}
⚠️ 警告: '${BRANCH}' は規定外プレフィックスです！
  /branch を実行してブランチを feature/ fix/ release/ hotfix/ docs/ chore/ のいずれかにリネームしてから作業を開始してください。
  claude/ agent/ temp/ 等のプレフィックスは禁止です。"
else
  echo "【必須】作業前に /branch と /translate を順に実行せよ。現在のブランチ: ${BRANCH}"
fi

exit 0
