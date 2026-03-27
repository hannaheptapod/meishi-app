#!/bin/bash
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
echo "【必須】作業前に /branch と /translate を順に実行せよ。現在のブランチ: ${BRANCH}"
exit 0
