#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d)"
OUTPUT="$(mktemp -d)"
trap 'rm -rf "$FIXTURE" "$OUTPUT"' EXIT

mkdir -p "$FIXTURE/qwen_embeddings.mlmodelc/weights"
dd if=/dev/zero of="$FIXTURE/qwen_embeddings.mlmodelc/weights/weight.bin" \
  bs=1048576 count=11 status=none
dd if=/dev/zero of="$FIXTURE/tokenizer.json" bs=1024 count=1 status=none

"$ROOT/scripts/cloudkit-models.sh" manifest 1.2.0 "$FIXTURE" "$OUTPUT" >/dev/null

jq -e '.schemaVersion == 2 and .version == "1.2.0"' "$OUTPUT/manifest.json" >/dev/null
jq -e '[.files[].chunks[].size] | max == 10485760' "$OUTPUT/manifest.json" >/dev/null
jq -e '[.files[].chunks[]] | length == 3' "$OUTPUT/manifest.json" >/dev/null

while IFS=$'\t' read -r record expected; do
  actual="$(shasum -a 256 "$OUTPUT/chunks/${record}.bin" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]]
done < <(jq -r '.files[].chunks[] | [.recordName, .sha256] | @tsv' "$OUTPUT/manifest.json")

if "$ROOT/scripts/cloudkit-models.sh" manifest 1.2.0 "$FIXTURE" "$FIXTURE/output" >/dev/null 2>&1; then
  echo "manifest output inside model directory must be rejected" >&2
  exit 1
fi

echo "cloudkit-models manifest test: PASS"
