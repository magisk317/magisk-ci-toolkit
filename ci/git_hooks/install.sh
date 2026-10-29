#!/usr/bin/env bash
# Wire the pointer gate into every /root/play checkout through core.hooksPath.
#
# One hook directory (this repo's ci/git_hooks) instead of 14 copies, so the gate is versioned
# with the tooling it runs. Repos here may carry core.hooksPath=/home/lzc/.git-sign-hooks, which
# is a leftover from the lzc machine: that path does not exist on debian, so git silently ran no
# hooks at all. Commit signing is unaffected - it comes from commit.gpgsign in /root/.gitconfig,
# not from a hook. The previous value is printed and backed up before being replaced.
set -uo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAY="${MAGISK_PLAY_ROOT:-/root/play}"
REPOS="XposedSmsCode xinyi-relay push/MiPushFramework sesame TouchPilot serialbridge \
       magisk-ui-kit magisk-xposed-kit magisk-smscode-core magisk-smscode-rules magisk-build-logic \
       magisk-ci-toolkit magisk-mobile-private"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1
backup="$PLAY/.git-hookspath-backup.txt"
changed=0
for r in $REPOS; do
  dir="$PLAY/$r"
  if [ ! -d "$dir/.git" ]; then
    printf '   %-26s skipped (no .git)\n' "${r##*/}"
    continue
  fi
  old=$(git -C "$dir" config --local core.hooksPath 2>/dev/null || true)
  if [ "$old" = "$SRC_DIR" ]; then
    printf '   %-26s already wired\n' "${r##*/}"
    continue
  fi
  printf '   %-26s hooksPath: %s -> %s\n' "${r##*/}" "${old:-<unset, using .git/hooks>}" "$SRC_DIR"
  [ "$DRY" = "1" ] && continue
  if [ -n "$old" ]; then
    printf '%s\t%s\n' "$dir" "$old" >> "$backup"
  fi
  git -C "$dir" config --local core.hooksPath "$SRC_DIR"
  changed=$((changed + 1))
done
if [ "$DRY" = "0" ]; then
  # remove any junk created by an earlier buggy run that joined an absolute hooksPath onto the
  # repo root (that produced <repo>/home/lzc/.git-sign-hooks); refuse if anything is tracked.
  for r in $REPOS; do
    p="$PLAY/$r/home/lzc/.git-sign-hooks"
    [ -d "$p" ] || continue
    if [ -n "$(git -C "$(dirname "$(dirname "$(dirname "$(dirname "$p")")")")" ls-files home 2>/dev/null)" ]; then
      echo "   WARN $p has tracked files - leaving it alone"
      continue
    fi
    rm -rf "$PLAY/$r/home"
    echo "   cleaned stray $r/home"
  done
  for pair in "HyperFusion/.git/hooks" "push/MiPushFramework/.git/hooks"; do
    rm -f "$PLAY/$pair/post-commit" "$PLAY/$pair/pre-push"
  done
  echo "wired $changed repo(s); previous values in ${backup#$PLAY/} (if any)"
fi
