#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
wrapper="$root_dir/gradle/run_gradle_with_retry.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Fake gradlew that records its arguments and succeeds. The wrapper runs it
# under setsid, so keep the stub dependency-free.
args_file="$tmp_dir/gradle-args"
cat > "$tmp_dir/gradlew" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$args_file"
exit 0
STUB
chmod +x "$tmp_dir/gradlew"

run_wrapper() {
  # env -i keeps the ambient proxy variables of the test runner out of the
  # assertions; every case sets exactly the environment it needs.
  env -i \
    PATH="/usr/bin:/bin" \
    GRADLEW_BIN="$tmp_dir/gradlew" \
    GRADLE_RETRY_MAX_ATTEMPTS=1 \
    "$@" \
    bash "$wrapper" assembleDebug >/dev/null 2>&1
}

recorded_args() { tr '\n' ' ' < "$args_file"; }

expect_contains() {
  recorded_args | grep -Fq -- "$1" || fail "expected Gradle args to contain '$1' (got: $(recorded_args))"
}

expect_absent() {
  if recorded_args | grep -Fq -- "$1"; then
    fail "expected Gradle args NOT to contain '$1' (got: $(recorded_args))"
  fi
}

expect_task_passthrough() {
  grep -Fqx "assembleDebug" "$args_file" || fail "task arguments must survive proxy flag injection (got: $(recorded_args))"
}

# 1. No proxy environment -> no proxy flags at all.
: > "$args_file"
run_wrapper
expect_absent "proxy"
expect_task_passthrough

# 2. https_proxy only -> both the https and the http pair (fallback).
run_wrapper https_proxy=http://10.33.207.217:7890
expect_contains "-Dhttps.proxyHost=10.33.207.217"
expect_contains "-Dhttps.proxyPort=7890"
expect_contains "-Dhttp.proxyHost=10.33.207.217"
expect_contains "-Dhttp.proxyPort=7890"
expect_task_passthrough

# 3. Uppercase HTTPS_PROXY is honoured too.
run_wrapper HTTPS_PROXY=http://proxy.internal:3128
expect_contains "-Dhttps.proxyHost=proxy.internal"
expect_contains "-Dhttps.proxyPort=3128"
expect_contains "-Dhttp.proxyHost=proxy.internal"

# 4. Userinfo (user:password@) is stripped from the host.
run_wrapper https_proxy=http://user:secret@proxy.internal:3128
expect_contains "-Dhttps.proxyHost=proxy.internal"
expect_absent "secret"

# 5. no_proxy converts commas to pipes and leading dots to wildcards.
run_wrapper https_proxy=http://proxy.internal:3128 no_proxy="localhost,127.0.0.1,.corp.example.com"
expect_contains "-Dhttp.nonProxyHosts=localhost|127.0.0.1|*.corp.example.com"

# 6. no_proxy without any proxy variable adds nothing.
run_wrapper no_proxy=localhost
expect_absent "proxy"

# 7. A malformed proxy URL only warns; the Gradle run still happens.
: > "$args_file"
run_wrapper https_proxy="http://"
expect_absent "proxyHost"
[[ -s "$args_file" ]] || fail "malformed proxy URL must not abort the Gradle run"

# 8. Explicit opt-out wins over the environment.
run_wrapper https_proxy=http://10.33.207.217:7890 MAGISK_GRADLE_PROXY_DISABLE=1
expect_absent "proxy"

# 9. A socks5 proxy maps to the JVM socks properties instead.
run_wrapper https_proxy=socks5://127.0.0.1:1080
expect_contains "-DsocksProxyHost=127.0.0.1"
expect_contains "-DsocksProxyPort=1080"
expect_absent "https.proxyHost"

# 10. A missing port defaults per scheme.
run_wrapper https_proxy=http://proxy.internal
expect_contains "-Dhttps.proxyPort=80"
run_wrapper https_proxy=https://proxy.internal
expect_contains "-Dhttps.proxyPort=443"

# 11. Bracketed IPv6 literals keep their brackets.
run_wrapper https_proxy="http://[::1]:8080"
expect_contains "-Dhttps.proxyHost=[::1]"
expect_contains "-Dhttps.proxyPort=8080"

# 12. Path/query suffixes after the authority are ignored.
run_wrapper https_proxy=http://proxy.internal:3128/pac?token=x
expect_contains "-Dhttps.proxyHost=proxy.internal"
expect_contains "-Dhttps.proxyPort=3128"
expect_absent "pac"

echo "run_gradle_with_retry proxy tests passed"
