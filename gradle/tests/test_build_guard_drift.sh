#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
guard="$root_dir/gradle/00-build-guard.gradle"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$guard" ] || fail "$guard is missing; the repository copy is the only reviewable one"

require() { grep -Fq -- "$1" "$guard" || fail "guard lost required text: '$1'"; }

lineno() { grep -n -F -- "$1" "$guard" | head -1 | cut -d: -f1; }

# This guard is not part of any consumer include chain. A host provisioner fans this file out
# to every GRADLE_USER_HOME/init.d and every unpacked Gradle distribution init.d, and the
# runner's pre_build_script copies the .locks copy into each CI slot home. Two consequences:
#
#   1. A nested TestKit build reads the DISTRIBUTION copy, not the home copy, because its
#      GRADLE_USER_HOME is a throwaway .gradle-test-kit directory. A fix that lands only in
#      ~/.gradle/init.d is a no-op for the very JVM that deadlocks.
#   2. Whatever gets deployed must be this file. Drift never shows up in a pipeline diff.
#
# 2026-10-23: the re-entrancy marker is a System property, so it does not cross into the test
# worker or the single-use daemon that worker starts. The nested build queued for a lock its
# own parent held, and strict mode waited without a deadline -- 7200 s of zero trace output
# before GitLab killed the job. Everything below exists to keep that from coming back.

# Nested builds are excused through the environment, the one channel proven to cross
# job -> client -> daemon -> test worker -> nested daemon.
require 't.environment("MAGISK_GW_LOCK_HELD", "1")'

# Waiting is bounded, and the bound is reachable by the operator.
require 'MAGISK_GRADLE_LOCK_MAX_WAIT_SEC'
require 'waitedSec >= maxWaitSec'
# ... and a suspected self-deadlock is detected early instead of burning the whole bound.
require 'holderIsOwnAncestor'

# A deadlock has to fail the build. The catch-all that keeps lock plumbing from breaking
# builds must not swallow it, otherwise the failure mode is silent again.
require 'MAGISK_BUILD_GUARD_DEADLOCK'
require 't.message.startsWith("MAGISK_BUILD_GUARD_DEADLOCK")'

# The exemption is registered on BOTH lock-held paths: whichever copy evaluates first
# acquires, and every later evaluation in that JVM takes the re-entrant early-return.
# Registering only after a successful acquire works or not depending on load order.
registrations=$(grep -c -F 'markNestedBuildsExempt(' "$guard" || true)
[ "${registrations:-0}" -ge 2 ] || fail \
  "expected >=2 markNestedBuildsExempt call sites (acquire + re-entrant), got ${registrations:-0}"

# Ordering invariants from the 2026-10-21 incident: closing any fd on the lock inode drops
# the whole process's POSIX record lock, so the same-JVM re-entrant path must return before
# a second channel is ever opened.
reentrant_line=$(lineno 'String alreadyHeld = System.getProperty(holdKey)')
open_line=$(lineno 'FileChannel channel = FileChannel.open(lockPath,')
[ -n "$reentrant_line" ] && [ -n "$open_line" ] || fail 'lock bookkeeping structure changed; update this contract'
[ "$reentrant_line" -lt "$open_line" ] || fail 'the re-entrant path must return before opening any channel'

# The exception whitelist must live inside the catch that would otherwise hide it.
catch_line=$(lineno 'catch (Throwable t) {')
rethrow_line=$(lineno 't.message.startsWith("MAGISK_BUILD_GUARD_DEADLOCK")')
[ "$catch_line" -lt "$rethrow_line" ] || fail 'the deadlock rethrow must be inside the swallow-all catch'

# --- drift against the deployed copy ------------------------------------------------
# First readable candidate wins: the container bind mount, the host cache path, then the
# authoritative source. Nothing readable means the comparison is unavailable here -- say so
# instead of pretending it passed.
deployed=""
for candidate in \
  "${MAGISK_GRADLE_LOCK_DIR:-}/00-build-guard.gradle" \
  /opt/gradle-cache/.locks/00-build-guard.gradle \
  /home/brew/.gitlab-runner-magisk/gradle-cache/.locks/00-build-guard.gradle \
  "${MAGISK_GRADLE_SOURCE:-/root/.gradle/init.d/00-build-guard.gradle}"; do
  if [ -r "$candidate" ]; then
    deployed="$candidate"
    break
  fi
done

if [ -z "$deployed" ]; then
  echo "SKIP drift: no deployed copy readable here (normal off the runner host; the host still"
  echo "     owes gradle-lock-sync, verified by 'gradle-lock-sync status' reporting 0 anomalies)."
elif cmp -s "$guard" "$deployed"; then
  echo "OK drift: deployed copy $deployed matches the repository byte for byte."
else
  fail "repository copy drifted from the deployed $deployed
  deployed:   $(md5sum "$deployed" | cut -d' ' -f1)
  repository: $(md5sum "$guard" | cut -d' ' -f1)
  If the deployed edit was the hotfix, bring it into this file and deploy with
  'gradle-lock-sync sync'. If the repository is ahead, deploy it before merging on
  faith: consumers run the deployed copy, not this one."
fi

echo "PASS: gradle build guard contract holds."
