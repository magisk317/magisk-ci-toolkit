#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
ensure="$root_dir/ci/ensure_pnpm.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v node >/dev/null || fail "node is required to run the ensure_pnpm tests"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# A fake bin dir shadows real pnpm/npm so the tests never touch the network or
# the global install. Both stubs share a state file holding the "installed"
# pnpm version: `pnpm --version` reads it, and `npm install pnpm@x` rewrites it
# (simulating a real install). `npm` also appends to a marker so a test can
# assert whether an install happened at all (fast path must not install).
bin_dir="$tmp_dir/bin"
mkdir -p "$bin_dir"
npm_marker="$tmp_dir/npm-called"
version_state="$tmp_dir/pnpm-version"

cat > "$bin_dir/pnpm" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
  cat "$version_state"
  exit 0
fi
exit 0
STUB

cat > "$bin_dir/npm" <<STUB
#!/usr/bin/env bash
# Record the install request, then make the requested version active by
# rewriting the shared version state the pnpm stub reads.
printf '%s\n' "\$*" >> "$npm_marker"
for arg in "\$@"; do
  case "\$arg" in
    pnpm@*) printf '%s\n' "\${arg#pnpm@}" > "$version_state" ;;
  esac
done
exit 0
STUB

chmod +x "$bin_dir/pnpm" "$bin_dir/npm"

# Seed the version the pnpm stub reports before each run.
seed_installed() { printf '%s\n' "$1" > "$version_state"; }

run_ensure() {
  # Prepend our stubs so they shadow the real pnpm/npm, while keeping the rest
  # of PATH intact (node may live outside /usr/bin, e.g. under linuxbrew).
  PATH="$bin_dir:$PATH" \
  PNPM_CONFIG_REGISTRY="https://registry.npmjs.org" \
    bash "$ensure" "$@"
}

# 1. Fast path: pnpm already matches -> npm must NOT be called.
rm -f "$npm_marker"
seed_installed "11.17.0"
printf '{"packageManager":"pnpm@11.17.0"}\n' > "$tmp_dir/package.json"
(
  cd "$tmp_dir"
  run_ensure
)
[[ ! -f "$npm_marker" ]] || fail "fast path unexpectedly invoked npm install"

# 2. Explicit version arg is honored (pnpm@x.y.z form).
rm -f "$npm_marker"
seed_installed "1.0.0"
(
  cd "$tmp_dir"
  run_ensure "pnpm@11.17.0"
)
[[ -f "$npm_marker" ]] || fail "explicit version did not trigger npm install"
grep -Fq "pnpm@11.17.0" "$npm_marker" || fail "npm install did not request pnpm@11.17.0"

# 3. Bare version arg is honored.
rm -f "$npm_marker"
seed_installed "1.0.0"
(
  cd "$tmp_dir"
  run_ensure "9.5.0"
)
grep -Fq "pnpm@9.5.0" "$npm_marker" || fail "bare version arg not passed to npm install"

# 4. No arg resolves from ./package.json and installs when mismatched.
rm -f "$npm_marker"
seed_installed "1.0.0"
(
  cd "$tmp_dir"
  run_ensure
)
grep -Fq "pnpm@11.17.0" "$npm_marker" || fail "no-arg mode did not resolve from package.json"

# 5. A package.json path arg resolves that manifest.
rm -f "$npm_marker"
seed_installed "1.0.0"
printf '{"packageManager":"pnpm@8.15.0"}\n' > "$tmp_dir/other.json"
(
  cd "$tmp_dir"
  run_ensure "$tmp_dir/other.json"
)
grep -Fq "pnpm@8.15.0" "$npm_marker" || fail "path arg did not resolve the given manifest"

echo "ensure_pnpm tests passed"
