#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
resolver="$root_dir/ci/resolve_bun_version.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3 (expected '$1', got '$2')"; }

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

printf '{"packageManager":"bun@1.4.0"}\n' > "$tmp_dir/plain.json"
assert_eq "1.4.0" "$($resolver "$tmp_dir/plain.json")" "plain Bun packageManager"
printf '{"packageManager":"bun@1.3.5+sha512.deadbeef"}\n' > "$tmp_dir/suffix.json"
assert_eq "1.3.5" "$($resolver "$tmp_dir/suffix.json")" "integrity suffix"
assert_eq "1.4.0" "$(BUN_VERSION_PACKAGE_JSON="$tmp_dir/plain.json" "$resolver")" "env manifest"
(
  cd "$tmp_dir"
  cp plain.json package.json
  assert_eq "1.4.0" "$($resolver)" "default manifest"
)
if "$resolver" "$tmp_dir/missing.json" >/dev/null 2>&1; then fail "missing manifest resolved"; fi
printf '{"packageManager":"pnpm@11.22.0"}\n' > "$tmp_dir/pnpm.json"
if "$resolver" "$tmp_dir/pnpm.json" >/dev/null 2>&1; then fail "non-Bun manifest resolved"; fi

echo "resolve_bun_version tests passed"
