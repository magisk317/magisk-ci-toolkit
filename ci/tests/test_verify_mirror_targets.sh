#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$root_dir/ci/verify_mirror_targets.py"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/source one" "$tmp_dir/source-two"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

write_target() {
  printf 'sync:github:\n  variables:\n    MAGISK_GITHUB_MIRROR_REPOSITORY: "%s"\n' "$2" > "$1/.gitlab-ci.yml"
}

# GitHub names need not match their local or GitLab repository names.
write_target "$tmp_dir/source one" 'example/shared-sms'
write_target "$tmp_dir/source-two" 'example/shared-forward'
python3 "$checker" "$tmp_dir/source one" "$tmp_dir/source-two"
python3 "$checker" "$tmp_dir/source one" "$tmp_dir/source one"

write_target "$tmp_dir/source-two" 'EXAMPLE/Shared-Sms'
if python3 "$checker" "$tmp_dir/source one" "$tmp_dir/source-two" > "$tmp_dir/duplicate.out" 2> "$tmp_dir/duplicate.err"; then
  fail "two sources were allowed to overwrite the same case-insensitive GitHub target"
fi
grep -Fq 'mirror target is shared by' "$tmp_dir/duplicate.err" || fail "collision diagnostic is missing"

write_target "$tmp_dir/source-two" "\$MIRROR_TARGET"
if python3 "$checker" "$tmp_dir/source-two" > "$tmp_dir/dynamic.out" 2> "$tmp_dir/dynamic.err"; then
  fail "an unresolved mirror target was accepted"
fi

printf 'stages: [test]\n' > "$tmp_dir/source-two/.gitlab-ci.yml"
if python3 "$checker" "$tmp_dir/source-two" > "$tmp_dir/missing.out" 2> "$tmp_dir/missing.err"; then
  fail "a missing target was accepted"
fi

if python3 "$checker" "$tmp_dir/absent" > "$tmp_dir/absent.out" 2> "$tmp_dir/absent.err"; then
  fail "a missing source checkout was accepted"
fi

echo "mirror target uniqueness tests passed"
