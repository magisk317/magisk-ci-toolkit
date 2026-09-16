#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
resolver="$root_dir/ci/changed_paths.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

source_repo="$tmp_dir/source"
git init --quiet --initial-branch=beta "$source_repo"
git -C "$source_repo" config user.name "CI Toolkit Test"
git -C "$source_repo" config user.email "ci-toolkit-test@example.invalid"
git -C "$source_repo" config commit.gpgSign false

printf 'one\n' > "$source_repo/README.md"
git -C "$source_repo" add README.md
git -C "$source_repo" commit --quiet -m one
first_sha="$(git -C "$source_repo" rev-parse HEAD)"

printf 'two\n' > "$source_repo/common.kt"
git -C "$source_repo" add common.kt
git -C "$source_repo" commit --quiet -m two
second_sha="$(git -C "$source_repo" rev-parse HEAD)"

output_file="$tmp_dir/paths"
(cd "$source_repo" && CI_COMMIT_BEFORE_SHA="$first_sha" CI_COMMIT_SHA="$second_sha" "$resolver" "$output_file")
[[ "$(sed -n '1p' "$output_file")" == impact ]] || fail "expected impact mode"
[[ "$(sed -n '2p' "$output_file")" == common.kt ]] || fail "expected changed path"

(cd "$source_repo" && env \
  CI_COMMIT_BEFORE_SHA=0000000000000000000000000000000000000000 \
  CI_COMMIT_SHA="$second_sha" \
  "$resolver" "$output_file")
[[ "$(sed -n '1p' "$output_file")" == full ]] || fail "expected full fallback for zero base SHA"

echo "changed paths tests passed"
