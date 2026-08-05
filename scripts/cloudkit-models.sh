#!/usr/bin/env bash
set -euo pipefail

# CloudKit Web Services API を使うモデル配布 CLI。
# 既存 MLModelPackage のフィールドだけを再利用するため、CloudKit schema の追加は不要。

readonly CONTAINER="${CLOUDKIT_CONTAINER:-iCloud.com.jinks.emeishi}"
readonly ENVIRONMENT="${CLOUDKIT_ENVIRONMENT:-development}"
readonly DATABASE="public"
readonly RECORD_TYPE="MLModelPackage"
readonly API_ROOT="https://api.apple-cloudkit.com"
readonly CHUNK_BYTES=$((10 * 1024 * 1024))
readonly STATE_ROOT="${CLOUDKIT_UPLOAD_STATE_DIR:-.cloudkit-model-upload}"

usage() {
  echo "Usage:"
  echo "  $0 manifest <version> <model-directory> [output-directory]"
  echo "  $0 upload <version> <model-directory>"
  echo "  $0 promote <version>"
  echo "  $0 rollback [version]"
  echo "  $0 status"
  echo
  echo "Environment for network commands:"
  echo "  CLOUDKIT_KEY_ID, CLOUDKIT_PRIVATE_KEY"
  echo "  CLOUDKIT_ENVIRONMENT=development|production"
}

require_tools() {
  local tool
  for tool in curl jq openssl shasum split find stat; do
    command -v "$tool" >/dev/null || { echo "missing command: $tool" >&2; exit 2; }
  done
}

require_credentials() {
  : "${CLOUDKIT_KEY_ID:?CLOUDKIT_KEY_ID is required}"
  : "${CLOUDKIT_PRIVATE_KEY:?CLOUDKIT_PRIVATE_KEY is required}"
  [[ -r "$CLOUDKIT_PRIVATE_KEY" ]] || { echo "private key is not readable" >&2; exit 2; }
}

safe_version() {
  printf '%s' "$1" | tr '.+/' '---' | tr -cd 'A-Za-z0-9_-'
}

canonical_path() {
  local path="$1" suffix="" leaf
  while [[ ! -e "$path" ]]; do
    leaf="$(basename "$path")"
    suffix="/${leaf}${suffix}"
    path="$(dirname "$path")"
  done
  if [[ -d "$path" ]]; then
    printf '%s%s' "$(cd "$path" && pwd -P)" "$suffix"
  else
    printf '%s%s' "$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")" "$suffix"
  fi
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

file_size() {
  stat -f '%z' "$1"
}

signed_post() {
  local subpath="$1" body="$2" output="$3"
  local date body_hash message signature
  date="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  body_hash="$(printf '%s' "$body" | openssl dgst -sha256 -binary | openssl base64 -A)"
  message="${date}:${body_hash}:${subpath}"
  signature="$(printf '%s' "$message" | openssl dgst -sha256 -sign "$CLOUDKIT_PRIVATE_KEY" | openssl base64 -A)"

  curl --fail-with-body --silent --show-error \
    -X POST "${API_ROOT}${subpath}" \
    -H 'content-type: application/json' \
    -H "X-Apple-CloudKit-Request-KeyID: ${CLOUDKIT_KEY_ID}" \
    -H "X-Apple-CloudKit-Request-ISO8601Date: ${date}" \
    -H "X-Apple-CloudKit-Request-SignatureV1: ${signature}" \
    --data-binary "$body" >"$output"

  if jq -e '.serverErrorCode // .records[]?.serverErrorCode' "$output" >/dev/null 2>&1; then
    jq . "$output" >&2
    return 1
  fi
}

api_subpath() {
  printf '/database/1/%s/%s/%s/%s' "$CONTAINER" "$ENVIRONMENT" "$DATABASE" "$1"
}

record_lookup() {
  local record_name="$1" output="$2"
  local body
  body="$(jq -cn --arg name "$record_name" '{records:[{recordName:$name}]}')"
  signed_post "$(api_subpath records/lookup)" "$body" "$output"
}

modify_record() {
  local record_name="$1" fields_json="$2" output="$3"
  local body
  body="$(jq -cn \
    --arg name "$record_name" \
    --arg type "$RECORD_TYPE" \
    --argjson fields "$fields_json" \
    '{operations:[{operationType:"forceUpdate",record:{recordName:$name,recordType:$type,fields:$fields}}]}')"
  signed_post "$(api_subpath records/modify)" "$body" "$output"
}

upload_asset() {
  local record_name="$1" field_name="$2" file="$3" output="$4"
  local token_body token_response upload_url
  token_body="$(jq -cn \
    --arg name "$record_name" \
    --arg type "$RECORD_TYPE" \
    --arg field "$field_name" \
    '{tokens:[{recordName:$name,recordType:$type,fieldName:$field}]}')"
  token_response="${output}.token"
  signed_post "$(api_subpath assets/upload)" "$token_body" "$token_response"
  upload_url="$(jq -er '.tokens[0].url' "$token_response")"
  curl --fail-with-body --silent --show-error -X POST "$upload_url" --data-binary "@$file" >"$output"
  jq -e '.singleFile' "$output" >/dev/null
  rm -f "$token_response"
}

build_manifest() {
  local version="$1" model_dir="$2" output_dir="$3"
  [[ -d "$model_dir" ]] || { echo "model directory not found: $model_dir" >&2; exit 2; }
  local model_abs output_abs
  model_abs="$(canonical_path "$model_dir")"
  output_abs="$(canonical_path "$output_dir")"
  if [[ "$output_abs" == "$model_abs" || "$output_abs" == "$model_abs/"* ]]; then
    echo "output directory must not be the model directory or its descendant" >&2
    exit 2
  fi
  rm -rf "$output_dir/chunks"
  mkdir -p "$output_dir/chunks"

  local files_json='[]' global_index=0 file relative size sha file_chunks chunk chunk_size chunk_sha record_name
  while IFS= read -r file; do
    relative="${file#"$model_dir"/}"
    size="$(file_size "$file")"
    sha="$(sha256_file "$file")"
    file_chunks='[]'

    local prefix="$output_dir/chunks/file-${global_index}-"
    split -b "$CHUNK_BYTES" -a 4 "$file" "$prefix"
    while IFS= read -r chunk; do
      chunk_size="$(file_size "$chunk")"
      chunk_sha="$(sha256_file "$chunk")"
      record_name="model-v2-$(safe_version "$version")-chunk-$(printf '%05d' "$global_index")"
      mv "$chunk" "$output_dir/chunks/${record_name}.bin"
      file_chunks="$(jq -cn \
        --argjson current "$file_chunks" \
        --arg name "$record_name" \
        --argjson size "$chunk_size" \
        --arg sha "$chunk_sha" \
        '$current + [{recordName:$name,size:$size,sha256:$sha}]')"
      global_index=$((global_index + 1))
    done < <(find "$output_dir/chunks" -type f -name "file-*" | sort)

    files_json="$(jq -cn \
      --argjson current "$files_json" \
      --arg path "$relative" \
      --argjson size "$size" \
      --arg sha "$sha" \
      --argjson chunks "$file_chunks" \
      '$current + [{relativePath:$path,size:$size,sha256:$sha,chunks:$chunks}]')"
  done < <(find "$model_dir" -type f | sort)

  jq -n \
    --arg version "$version" \
    --argjson files "$files_json" \
    --argjson chunkBytes "$CHUNK_BYTES" \
    '{schemaVersion:2,version:$version,chunkBytes:$chunkBytes,files:$files}' \
    >"$output_dir/manifest.json"
  echo "$output_dir/manifest.json"
}

upload_version() {
  local version="$1" model_dir="$2"
  require_credentials
  local safe work state_file manifest response record_name chunk asset asset_value chunk_sha manifest_sha total
  safe="$(safe_version "$version")"
  work="$STATE_ROOT/$ENVIRONMENT/$safe"
  mkdir -p "$work"
  manifest="$(build_manifest "$version" "$model_dir" "$work")"
  state_file="$work/state.json"
  [[ -f "$state_file" ]] || printf '{"uploadedRecords":[]}' >"$state_file"

  total="$(find "$work/chunks" -type f -name '*.bin' | wc -l | tr -d ' ')"
  local completed=0
  while IFS= read -r chunk; do
    record_name="$(basename "$chunk" .bin)"
    chunk_sha="$(sha256_file "$chunk")"
    chunk_size="$(file_size "$chunk")"
    if jq -e \
      --arg name "$record_name" \
      --arg sha "$chunk_sha" \
      --argjson size "$chunk_size" \
      '.uploadedRecords | any(select(type == "object"); .recordName == $name and .sha256 == $sha and .size == $size)' \
      "$state_file" >/dev/null; then
      completed=$((completed + 1))
      echo "skip $record_name ($completed/$total)"
      continue
    fi

    response="$work/${record_name}.asset.json"
    upload_asset "$record_name" weightChunk0 "$chunk" "$response"
    asset_value="$(jq -c '.singleFile' "$response")"
    modify_record "$record_name" "$(jq -cn \
      --argjson asset "$asset_value" \
      --arg sha "$chunk_sha" \
      '{weightChunk0:{value:$asset},embedWeightSHA256:{value:$sha}}')" \
      "$work/${record_name}.record.json"
    jq \
      --arg name "$record_name" \
      --arg sha "$chunk_sha" \
      --argjson size "$chunk_size" \
      '.uploadedRecords = ([.uploadedRecords[] | select(type == "object" and .recordName != $name)] + [{recordName:$name,size:$size,sha256:$sha}])' \
      "$state_file" >"${state_file}.tmp"
    mv "${state_file}.tmp" "$state_file"
    completed=$((completed + 1))
    echo "uploaded $record_name ($completed/$total)"
  done < <(find "$work/chunks" -type f -name '*.bin' | sort)

  record_name="model-v2-${safe}-manifest"
  response="$work/manifest.asset.json"
  upload_asset "$record_name" tokenizerAsset "$manifest" "$response"
  asset_value="$(jq -c '.singleFile' "$response")"
  manifest_sha="$(sha256_file "$manifest")"
  modify_record "$record_name" "$(jq -cn \
    --argjson asset "$asset_value" \
    --arg sha "$manifest_sha" \
    --argjson count "$total" \
    '{tokenizerAsset:{value:$asset},embedWeightSHA256:{value:$sha},weightChunkCount:{value:$count}}')" \
    "$work/manifest.record.json"
  verify_remote_manifest "$version"
  echo "version $version uploaded and verified locally; run: $0 promote $version"
}

verify_remote_manifest() {
  local version="$1" safe record_name output expected url downloaded actual
  safe="$(safe_version "$version")"
  record_name="model-v2-${safe}-manifest"
  output="$(mktemp)"
  downloaded="$(mktemp)"
  if ! record_lookup "$record_name" "$output"; then
    rm -f "$output" "$downloaded"
    echo "manifest record not found: $record_name" >&2
    return 1
  fi
  expected="$(jq -er '.records[0].fields.embedWeightSHA256.value' "$output")"
  url="$(jq -er '.records[0].fields.tokenizerAsset.value.downloadURL' "$output")"
  curl --fail-with-body --silent --show-error "$url" -o "$downloaded"
  actual="$(sha256_file "$downloaded")"
  rm -f "$output" "$downloaded"
  [[ "$actual" == "$expected" ]] || {
    echo "manifest hash mismatch for $record_name" >&2
    return 1
  }
}

channel_versions() {
  local output="$1"
  if ! record_lookup model-v2-channel-stable "$output"; then
    printf '\t\n'
    return
  fi
  local current previous
  current="$(jq -r '.records[0].fields.embedWeightSHA256.value // ""' "$output")"
  previous="$(jq -r '.records[0].fields.ffnWeightSHA256.value // ""' "$output")"
  printf '%s\t%s\n' "$current" "$previous"
}

promote_version() {
  local version="$1" output current previous
  require_credentials
  verify_remote_manifest "$version"
  output="$(mktemp)"
  IFS=$'\t' read -r current previous < <(channel_versions "$output")
  modify_record model-v2-channel-stable "$(jq -cn \
    --arg current "$version" \
    --arg previous "$current" \
    '{embedWeightSHA256:{value:$current},ffnWeightSHA256:{value:$previous}}')" "$output"
  rm -f "$output"
  echo "stable: ${current:-none} -> $version"
}

rollback_version() {
  local requested="${1:-}" output current previous target
  require_credentials
  output="$(mktemp)"
  IFS=$'\t' read -r current previous < <(channel_versions "$output")
  target="${requested:-$previous}"
  [[ -n "$target" ]] || { echo "no rollback target" >&2; exit 1; }
  verify_remote_manifest "$target"
  modify_record model-v2-channel-stable "$(jq -cn \
    --arg current "$target" \
    --arg previous "$current" \
    '{embedWeightSHA256:{value:$current},ffnWeightSHA256:{value:$previous}}')" "$output"
  rm -f "$output"
  echo "stable: ${current:-none} -> $target (rollback)"
}

show_status() {
  require_credentials
  local output current previous
  output="$(mktemp)"
  IFS=$'\t' read -r current previous < <(channel_versions "$output")
  rm -f "$output"
  echo "environment: $ENVIRONMENT"
  echo "stable: ${current:-not configured}"
  echo "rollback: ${previous:-not configured}"
}

main() {
  require_tools
  local command="${1:-}"
  case "$command" in
    manifest)
      [[ $# -ge 3 ]] || { usage; exit 2; }
      build_manifest "$2" "${3%/}" "${4:-$STATE_ROOT/manifest-$(safe_version "$2")}" >/dev/null
      echo "manifest created: ${4:-$STATE_ROOT/manifest-$(safe_version "$2")}/manifest.json"
      ;;
    upload)
      [[ $# -eq 3 ]] || { usage; exit 2; }
      upload_version "$2" "${3%/}"
      ;;
    promote)
      [[ $# -eq 2 ]] || { usage; exit 2; }
      promote_version "$2"
      ;;
    rollback)
      rollback_version "${2:-}"
      ;;
    status)
      show_status
      ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
