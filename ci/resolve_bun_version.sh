#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [path/to/package.json]" >&2
  echo "  Prints the bare Bun version (e.g. 1.4.0) from the packageManager field." >&2
}

resolve_bun_version() {
  local pkg_json="${1:-${BUN_VERSION_PACKAGE_JSON:-package.json}}"

  if [[ -z "$pkg_json" ]]; then
    usage
    return 2
  fi
  if [[ ! -f "$pkg_json" ]]; then
    echo "resolve_bun_version: package.json not found at $pkg_json" >&2
    return 2
  fi

  local raw=""
  if command -v node >/dev/null 2>&1; then
    raw="$(node -e 'const fs=require("fs");try{process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).packageManager||""))}catch(e){}' "$pkg_json" 2>/dev/null || true)"
  fi
  if [[ -z "$raw" ]]; then
    raw="$(grep -o '"packageManager"[[:space:]]*:[[:space:]]*"[^"]*"' "$pkg_json" 2>/dev/null \
      | head -n1 \
      | sed -E 's/.*"packageManager"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true)"
  fi

  if [[ "$raw" != bun@* ]]; then
    echo "resolve_bun_version: package.json does not pin bun@x.y.z (got '${raw:-<empty>}')" >&2
    return 1
  fi

  local version="${raw#bun@}"
  printf '%s\n' "${version%%+*}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  resolve_bun_version "$@"
fi
