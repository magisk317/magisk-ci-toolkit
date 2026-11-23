#!/usr/bin/env bash
# Acceptance tests for check_build_warnings.py and its pre-push wiring.
# Run from anywhere: bash ci/tests/test_check_build_warnings.sh
# Fixtures use the two warning shapes measured in this fleet's real builds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$(cd "$HERE/../git_hooks" && pwd)/check_build_warnings.py"
WHITELIST="$(cd "$HERE/../config" && pwd)/build-warning-whitelist.txt"
HOOKS_DIR="$(cd "$HERE/../git_hooks" && pwd)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/.build-logs"
cd "$T/repo" || exit 1
git init -q . >/dev/null 2>&1
git config user.name t; git config user.email t@e.com
git config commit.gpgsign false
echo seed > seed.txt && git add seed.txt && git commit -qm seed

cat > .build-logs/kotlin.log <<FIXTURE
> Task :xposed:compileDebugKotlin
Problem found: Kotlin compiler: RETURN_VALUE_NOT_USED (id: RETURN_VALUE_NOT_USED, in kotlin > compiler:warning)
  Kotlin compiler warning
    Unused return value of 'runCatching'.
    Location: $PWD/xposed/src/main/java/io/github/magisk317/mipush/hook/system/NativeFocusNotificationRewriter.kt:226
FIXTURE

cat > .build-logs/deprecation.log <<'FIXTURE'
> Configure project :common
The Configuration.setVisible(boolean) method has been deprecated. This is scheduled to be removed in Gradle 11.
	at org.gradle.api.internal.artifacts.configurations.DefaultConfiguration.setVisible(DefaultConfiguration.java:374)
	at Build_gradle$3.execute$configureDetekt$lambda$1(build.gradle.kts:178)
	(Run with --stacktrace to get the full stack trace for this deprecation warning.)
FIXTURE

# Self-verify the fixtures carry the shapes before judging the checker.
if grep -q "Problem found: Kotlin compiler: RETURN_VALUE_NOT_USED" .build-logs/kotlin.log \
  && grep -q "Location:" .build-logs/kotlin.log \
  && grep -q "has been deprecated" .build-logs/deprecation.log \
  && grep -q "at .*build.gradle.kts:178" .build-logs/deprecation.log; then
  ok "fixtures carry both warning shapes"
else
  bad "fixture self-verification"
fi

# --- 1: unknown kotlin warning blocks ---
python3 "$CHECKER" --repo "$PWD" --scan-dir .build-logs --whitelist "$WHITELIST" >out.txt 2>&1
rc=$?
if [ "$rc" = "1" ] && grep -q "BLOCKED kotlin:RETURN_VALUE_NOT_USED" out.txt; then
  ok "unknown kotlin warning blocks"
else
  bad "unknown kotlin warning blocks (rc=$rc)"; cat out.txt
fi

# --- 2: whitelisted deprecation alone passes ---
mkdir -p only-dep && cp .build-logs/deprecation.log only-dep/
python3 "$CHECKER" --repo "$PWD" --scan-dir only-dep --whitelist "$WHITELIST" >out.txt 2>&1
rc=$?
if [ "$rc" = "0" ] && grep -q "gradle-deprecation:Configuration.setVisible(boolean)" out.txt; then
  ok "whitelisted deprecation passes"
else
  bad "whitelisted deprecation passes (rc=$rc)"; cat out.txt
fi

# --- 3: mixed log blocks on the kotlin finding only ---
cat .build-logs/deprecation.log .build-logs/kotlin.log > mixed.log
python3 "$CHECKER" --repo "$PWD" --log mixed.log --whitelist "$WHITELIST" >out.txt 2>&1
rc=$?
if [ "$rc" = "1" ] && [ "$(grep -c BLOCKED out.txt)" = "1" ]; then
  ok "mixed log blocks only the unknown finding"
else
  bad "mixed log (rc=$rc)"; cat out.txt
fi

# --- 4: CI-style absolute paths normalize to repo-relative ---
sed "s#$PWD/#/builds/magisk3171/MiPushFramework/#" .build-logs/kotlin.log > ci.log
python3 "$CHECKER" --repo "$PWD" --log ci.log --whitelist "$WHITELIST" >out.txt 2>&1
if grep -q "xposed/src/main/java/io/github/magisk317/mipush/hook/system/NativeFocusNotificationRewriter.kt" out.txt; then
  ok "CI paths normalize to repo-relative"
else
  bad "CI path normalization"; cat out.txt
fi

# --- 5: an explicit whitelist entry passes (management protocol path) ---
cat > custom-whitelist.txt <<'WL'
* | xposed/** | kotlin:RETURN_VALUE_NOT_USED | test-only entry | test
WL
python3 "$CHECKER" --repo "$PWD" --log .build-logs/kotlin.log --whitelist custom-whitelist.txt >out.txt 2>&1
rc=$?
if [ "$rc" = "0" ]; then
  ok "explicit whitelist entry passes"
else
  bad "custom whitelist entry (rc=$rc)"; cat out.txt
fi

# --- 6: stale logs are not scanned (freshness filter) ---
# Set both mtimes explicitly so the boundary does not race the wall clock.
since=$(date +%s)
touch -d "@$((since - 3600))" .build-logs/kotlin.log
touch -d "@$since" .build-logs/deprecation.log
python3 "$CHECKER" --repo "$PWD" --scan-dir .build-logs --since-epoch "$since" --whitelist "$WHITELIST" >out.txt 2>&1
rc=$?
if [ "$rc" = "0" ] && ! grep -q "RETURN_VALUE_NOT_USED" out.txt \
  && grep -q "gradle-deprecation:Configuration.setVisible" out.txt; then
  ok "stale log skipped, fresh log still scanned"
else
  bad "freshness filter (rc=$rc)"; cat out.txt
fi
touch .build-logs/kotlin.log

# --- 7: missing .build-logs passes with a notice ---
mkdir -p "$T/other"
python3 "$CHECKER" --repo "$T/other" --scan-dir "$T/other/.build-logs" --whitelist "$WHITELIST" >out.txt 2>&1
rc=$?
if [ "$rc" = "0" ] && grep -q "nothing to scan" out.txt; then
  ok "missing build-logs passes with notice"
else
  bad "missing dir (rc=$rc)"; cat out.txt
fi

# --- 8: pre-push wiring blocks; escape valve passes ---
# Invoke the real pre-push hook with stdin (no real push). The pointer gate is
# stubbed through its documented env override with a python no-op (the hook
# invokes the gate with python3, so /bin/true would be parsed as a script).
cat > "$T/gate-stub.py" <<'STUB'
import sys
sys.exit(0)
STUB
mkdir -p .git/hooks
cp "$HOOKS_DIR/pre-push" .git/hooks/pre-push
cp "$CHECKER" .git/hooks/check_build_warnings.py
chmod +x .git/hooks/pre-push .git/hooks/check_build_warnings.py
Z=0000000000000000000000000000000000000000
sha=$(git rev-parse HEAD)
printf 'refs/heads/main %s refs/heads/main %s\n' "$sha" "$Z" \
  | MAGISK_POINTER_GATE="$T/gate-stub.py" MAGISK_WARNING_WHITELIST="$WHITELIST" \
    .git/hooks/pre-push origin /tmp/nr >push.txt 2>&1
rc=$?
if [ "$rc" = "1" ] && grep -q "build-warning gate" push.txt; then
  ok "pre-push hook blocks unknown warning"
else
  bad "pre-push wiring (rc=$rc)"; cat push.txt
fi

printf 'refs/heads/main %s refs/heads/main %s\n' "$sha" "$Z" \
  | SKIP_WARNING_CHECK=1 MAGISK_POINTER_GATE="$T/gate-stub.py" MAGISK_WARNING_WHITELIST="$WHITELIST" \
    .git/hooks/pre-push origin /tmp/nr >push2.txt 2>&1
rc=$?
if [ "$rc" = "0" ]; then
  ok "SKIP_WARNING_CHECK escape valve passes"
else
  bad "escape valve (rc=$rc)"; cat push2.txt
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
