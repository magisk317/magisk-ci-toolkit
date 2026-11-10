#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$root_dir/ci/check_shell_syntax.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat > "$tmp_dir/first.sh" <<'SCRIPT'
#!/usr/bin/env bash
printf 'executed\n' > "$SYNTAX_SIDE_EFFECT"
SCRIPT
cat > "$tmp_dir/second valid.sh" <<'SCRIPT'
#!/usr/bin/env bash
if true; then
  printf 'valid\n'
fi
SCRIPT
cat > "$tmp_dir/second invalid.sh" <<'SCRIPT'
#!/usr/bin/env bash
if true; then
SCRIPT

SYNTAX_SIDE_EFFECT="$tmp_dir/side-effect" \
  bash "$checker" "$tmp_dir/first.sh" "$tmp_dir/second valid.sh"
[[ ! -e "$tmp_dir/side-effect" ]] || fail "syntax checking executed a script"

if bash "$checker" "$tmp_dir/first.sh" "$tmp_dir/second invalid.sh" \
    > "$tmp_dir/second.stdout" 2> "$tmp_dir/second.stderr"; then
  fail "syntax error in the second script was ignored"
fi
grep -Fq 'second invalid.sh' "$tmp_dir/second.stderr" \
  || fail "diagnostic did not identify the invalid path containing spaces"

if bash "$checker" "$tmp_dir/second invalid.sh" "$tmp_dir/second valid.sh" \
    > "$tmp_dir/first.stdout" 2> "$tmp_dir/first.stderr"; then
  fail "a valid later script hid an earlier syntax error"
fi

if bash "$checker" "$tmp_dir/first.sh" "$tmp_dir/missing.sh" \
    > "$tmp_dir/missing.stdout" 2> "$tmp_dir/missing.stderr"; then
  fail "a missing script passed syntax checking"
fi

if bash "$checker" > "$tmp_dir/empty.stdout" 2> "$tmp_dir/empty.stderr"; then
  fail "an empty script list passed syntax checking"
fi

echo "shell syntax checker tests passed"
