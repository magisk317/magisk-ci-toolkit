#!/usr/bin/env bash
# Tests the pre-commit hook's identity baseline logic. Born from the
# 2026-11-23 regression (40f8148): a misplaced `|| true` inside the pipeline
# made awk never run on success, so the baseline became the raw multi-line
# git log and every repo with mixed identities in its last 20 commits was
# blocked. The toolkit repo itself never noticed because it takes the
# ci/commit-identity policy path.
#
# Scenarios: empty repo first commit, single-identity repo, MIXED bot+human
# history (the regression), a real identity mismatch (must still be blocked),
# and the policy-file path.
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
  git -C "$dir" config user.name magisk317
  git -C "$dir" config user.email code@mail.usdt.edu.kg
  git -C "$dir" config commit.gpgsign false
  echo "$dir"
}

# --- 1. empty repo: the first commit must pass (the original bug this hook
#        was fixed for; `git log` fails there and pipefail must not abort) ---
T="$(make_repo)"
echo a > "$T/a.txt"
git -C "$T" add a.txt
if git -C "$T" -c core.hooksPath="$HOOK" commit -qm "first" 2>/dev/null; then
  ok "empty repo first commit passes"
else
  bad "empty repo first commit must pass"
fi
rm -rf "$T"

# --- 2. mixed bot+human history: the 40f8148 regression scenario -----------
T="$(make_repo)"
echo a > "$T/a.txt"
git -C "$T" add a.txt
git -C "$T" -c core.hooksPath=/dev/null \
  -c user.name="GitLab CI" -c user.email=gitlab-ci@magisk3171 commit -qm "bot commit"
echo b > "$T/b.txt"
git -C "$T" add b.txt
if git -C "$T" -c core.hooksPath="$HOOK" commit -qm "human after bot" 2>/dev/null; then
  ok "commit passes with mixed bot+human history (regression guard)"
else
  bad "mixed history must not block the commit"
fi
rm -rf "$T"

# --- 3. a genuine identity mismatch must still be blocked ------------------
T="$(make_repo)"
echo a > "$T/a.txt"
git -C "$T" add a.txt
git -C "$T" -c core.hooksPath=/dev/null commit -qm "seed"
out="$(cd "$T" && GIT_AUTHOR_NAME="someone-else" GIT_AUTHOR_EMAIL="other@example.com" \
  GIT_COMMITTER_NAME="someone-else" GIT_COMMITTER_EMAIL="other@example.com" \
  bash "$HOOK" 2>&1)"
rc=$?
if [ "$rc" != "0" ] && printf '%s' "$out" | grep -q "identity mismatch"; then
  ok "genuine identity mismatch is still blocked"
else
  bad "identity mismatch must still be blocked (rc=$rc)"
fi
rm -rf "$T"

# --- 4. policy-file path: a repo shipping ci/commit-identity uses it -------
T="$(make_repo)"
mkdir -p "$T/ci"
printf 'name=magisk317\nemail=code@mail.usdt.edu.kg\n' > "$T/ci/commit-identity"
echo a > "$T/a.txt"
git -C "$T" add a.txt
if git -C "$T" -c core.hooksPath="$HOOK" commit -qm "policy path" 2>/dev/null; then
  ok "policy-file repo commits normally"
else
  bad "policy-file repo must commit normally"
fi
rm -rf "$T"

printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
