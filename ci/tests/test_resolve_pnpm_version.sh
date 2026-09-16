#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
resolver="$root_dir/ci/resolve_pnpm_version.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

command -v node >/dev/null || fail "node is required to run the pnpm resolver tests"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# 1. Plain packageManager field resolves to the bare version.
printf '{"packageManager":"pnpm@11.17.0"}\n' > "$tmp_dir/plain.json"
assert_eq "11.17.0" "$("$resolver" "$tmp_dir/plain.json")" "plain packageManager"

# 2. Corepack integrity suffix ("+sha512...") is stripped.
printf '{"packageManager":"pnpm@9.1.2+sha512.deadbeef"}\n' > "$tmp_dir/suffix.json"
assert_eq "9.1.2" "$("$resolver" "$tmp_dir/suffix.json")" "corepack integrity suffix"

# 3. PNPM_VERSION_PACKAGE_JSON env var selects the manifest.
assert_eq "11.17.0" \
  "$(PNPM_VERSION_PACKAGE_JSON="$tmp_dir/plain.json" "$resolver")" \
  "PNPM_VERSION_PACKAGE_JSON env override"

# 4. ./package.json in the working directory is the default.
(
  cd "$tmp_dir"
  cp plain.json package.json
  assert_eq "11.17.0" "$("$resolver")" "default ./package.json"
)

# 5. Missing manifest fails.
if "$resolver" "$tmp_dir/does-not-exist.json" >/dev/null 2>&1; then
  fail "missing package.json unexpectedly resolved"
fi

# 6. Non-pnpm/non-bun packageManager (yarn) fails rather than emitting garbage.
printf '{"packageManager":"yarn@4.0.0"}\n' > "$tmp_dir/yarn.json"
if "$resolver" "$tmp_dir/yarn.json" >/dev/null 2>&1; then
  fail "non-pnpm/non-bun packageManager unexpectedly resolved"
fi

# 7. Absent packageManager field fails.
printf '{"name":"demo"}\n' > "$tmp_dir/none.json"
if "$resolver" "$tmp_dir/none.json" >/dev/null 2>&1; then
  fail "missing packageManager field unexpectedly resolved"
fi

# 8. Fallback path (no node on PATH) still resolves via grep/sed. This mirrors
# the alpine-based docker:*-cli image used by container build jobs. Build a
# minimal PATH that keeps coreutils but hides node.
no_node_path=""
for dir in /usr/bin /bin /usr/local/bin; do
  [[ -d "$dir" ]] && no_node_path="${no_node_path:+$no_node_path:}$dir"
done
if PATH="$no_node_path" command -v node >/dev/null 2>&1; then
  echo "SKIP: node still on minimal PATH; cannot exercise fallback" >&2
else
  printf '{\n  "packageManager": "pnpm@11.17.0"\n}\n' > "$tmp_dir/fallback.json"
  assert_eq "11.17.0" \
    "$(PATH="$no_node_path" bash "$resolver" "$tmp_dir/fallback.json")" \
    "grep/sed fallback without node"
fi

# 9. Bun packageManager resolves to fallback pnpm version.
printf '{"packageManager":"bun@1.4.0"}\n' > "$tmp_dir/bun.json"
assert_eq "11.22.0" "$("$resolver" "$tmp_dir/bun.json")" "bun packageManager falls back to default pnpm"

# 10. Bun with custom fallback version via env var.
printf '{"packageManager":"bun@1.4.0"}\n' > "$tmp_dir/bun2.json"
assert_eq "11.17.0" \
  "$(PNPM_FALLBACK_VERSION="11.17.0" "$resolver" "$tmp_dir/bun2.json")" \
  "bun respects PNPM_FALLBACK_VERSION env var"

echo "pnpm version resolver tests passed"
