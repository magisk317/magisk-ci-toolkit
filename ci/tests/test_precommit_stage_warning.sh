#!/usr/bin/env bash
# Tests the pre-commit hook's recently-modified-but-unstaged warning (H7):
# a fresh unstaged file is reported, an old one is not, and the hook never
# blocks the commit. Self-contained: builds throwaway repos in a temp dir.
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../git_hooks" && pwd)/pre-commit"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

make_repo() {
  local dir
  dir="$(mktemp -d)"
  git -C "$dir" init -q .
  git -C "$dir" config user.name t
  git -C "$dir" config user.email t@e.com
  git -C "$dir" config commit.gpgsign false
  echo base > "$dir/base.txt"
  git -C "$dir" add base.txt
  # The first commit bypasses the hook: an empty repo has no history for the
  # identity baseline, which is unrelated to what this test covers.
  git -C "$dir" -c core.hooksPath=/dev/null commit -qm base
  echo "$dir"
}

# --- positive: a file touched seconds ago is reported -----------------------
T="$(make_repo)"
echo fresh > "$T/fresh.txt"
echo staged > "$T/staged.txt"
git -C "$T" add staged.txt
out="$(cd "$T" && bash "$HOOK" 2>&1)"
rc=$?
if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q "fresh.txt"; then
  ok "fresh unstaged file is reported and the hook exits 0"
else
  bad "fresh unstaged file should be reported (rc=$rc)"
fi
rm -rf "$T"

# --- negative: an old unstaged file is not reported -------------------------
T="$(make_repo)"
echo old > "$T/old.txt"
touch -d "2 hours ago" "$T/old.txt"
echo x > "$T/x.txt"
git -C "$T" add x.txt
out="$(cd "$T" && bash "$HOOK" 2>&1)"
if printf '%s' "$out" | grep -q "old.txt"; then
  bad "old unstaged file must not be reported"
else
  ok "old unstaged file stays silent"
fi
rm -rf "$T"

# --- negative: staged-only changes stay silent ------------------------------
T="$(make_repo)"
echo y > "$T/y.txt"
git -C "$T" add y.txt
out="$(cd "$T" && bash "$HOOK" 2>&1)"
if printf '%s' "$out" | grep -q "pre-commit: 注意"; then
  bad "fully staged commit must stay silent"
else
  ok "fully staged commit stays silent"
fi
rm -rf "$T"

printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
