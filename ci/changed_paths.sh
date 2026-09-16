#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <output-file>" >&2
}

if [[ "$#" -ne 1 || -z "$1" ]]; then
  usage
  exit 2
fi

output_file="$1"
head_sha="${CI_COMMIT_SHA:-HEAD}"
merge_base="${CI_MERGE_REQUEST_DIFF_BASE_SHA:-}"

if [[ -z "$merge_base" || "$merge_base" =~ ^0+$ ]]; then
  merge_base="${CI_COMMIT_BEFORE_SHA:-}"
fi

if [[ -z "$merge_base" || "$merge_base" =~ ^0+$ ]]; then
  printf 'full\n' > "$output_file"
  exit 0
fi

if ! git rev-parse --verify "${merge_base}^{commit}" >/dev/null 2>&1 ||
  ! git rev-parse --verify "${head_sha}^{commit}" >/dev/null 2>&1; then
  printf 'full\n' > "$output_file"
  exit 0
fi

printf 'impact\n' > "$output_file"
git diff --name-only --diff-filter=ACMR "$merge_base" "$head_sha" >> "$output_file"
