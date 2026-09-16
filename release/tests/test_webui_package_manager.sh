#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

BIN_DIR="$TMP_DIR/bin"
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/bun" <<'BUN'
#!/usr/bin/env bash
printf 'bun %s\n' "$*" >> "${WEBUI_TEST_LOG:?}"
if [[ "${1:-}" == "--version" ]]; then
  echo "1.4.0"
fi
BUN
cat > "$BIN_DIR/pnpm" <<'PNPM'
#!/usr/bin/env bash
printf 'pnpm %s\n' "$*" >> "${WEBUI_TEST_LOG:?}"
if [[ "${1:-}" == "--version" ]]; then
  echo "11.22.0"
fi
PNPM
chmod +x "$BIN_DIR/bun" "$BIN_DIR/pnpm"

source "$ROOT_DIR/release/release_tag.sh"

run_case() {
  local manager=$1
  local expected=$2
  local root="$TMP_DIR/$manager"
  mkdir -p "$root/frontend/webui"
  printf '{"packageManager":"%s@%s"}\n' "$manager" "$([[ "$manager" == bun ]] && echo 1.4.0 || echo 11.22.0)" \
    > "$root/frontend/webui/package.json"
  : > "$WEBUI_TEST_LOG"
  run_webui_checks "$root" >/dev/null
  grep -Fq "$expected" "$WEBUI_TEST_LOG" || fail "$manager checks did not use $expected"
  if [[ "$manager" == bun ]] && grep -Fq 'pnpm ' "$WEBUI_TEST_LOG"; then
    fail "Bun checks invoked pnpm"
  fi
  if [[ "$manager" == pnpm ]] && grep -Fq 'bun ' "$WEBUI_TEST_LOG"; then
    fail "pnpm checks invoked Bun"
  fi
}

export PATH="$BIN_DIR:$PATH"
export WEBUI_TEST_LOG="$TMP_DIR/commands.log"
run_case bun 'bun run build'
run_case pnpm 'pnpm -C frontend/webui run build'

echo "release WebUI package-manager tests passed"
