#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [path/to/package.json]" >&2
  echo "  Prints the bare pnpm version (e.g. 11.17.0) from the packageManager field." >&2
  echo "  Accepts both pnpm@x.y.z and bun@x.y.z as package managers." >&2
}

# Single source of truth for the package manager version: the `packageManager`
# field in package.json (corepack convention). Every CI consumer resolves the
# version through this script instead of hardcoding it.
#
# Supports both pnpm and bun as package managers. When bun is detected,
# a fallback pnpm version is returned (CI builds still use pnpm).
#
# Resolution order for the package.json path:
#   1. explicit CLI argument
#   2. PNPM_VERSION_PACKAGE_JSON environment variable
#   3. ./package.json in the current working directory

# Fallback pnpm version when bun is the declared package manager.
: "${PNPM_FALLBACK_VERSION:=11.22.0}"

resolve_pnpm_version() {
  local pkg_json="${1:-${PNPM_VERSION_PACKAGE_JSON:-package.json}}"

  if [[ -z "$pkg_json" ]]; then
    usage
    return 2
  fi
  if [[ ! -f "$pkg_json" ]]; then
    echo "resolve_pnpm_version: package.json not found at $pkg_json" >&2
    return 2
  fi

  # Extract the packageManager value. Prefer node (exact JSON parsing) but fall
  # back to grep/sed so the script also works in minimal images without node.
  local raw=""
  if command -v node >/dev/null 2>&1; then
    raw="$(node -e 'const fs=require("fs");try{process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).packageManager||""))}catch(e){}' "$pkg_json" 2>/dev/null || true)"
  fi
  if [[ -z "$raw" ]]; then
    raw="$(grep -o '"packageManager"[[:space:]]*:[[:space:]]*"[^"]*"' "$pkg_json" 2>/dev/null \
      | head -n1 \
      | sed -E 's/.*"packageManager"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true)"
  fi

  # Accept both pnpm and bun as valid package managers
  if [[ "$raw" == pnpm@* ]]; then
    local version="${raw#pnpm@}"
    version="${version%%+*}"
    printf '%s\n' "$version"
    return 0
  elif [[ "$raw" == bun@* ]]; then
    # Bun detected: use fallback pnpm version for CI build compatibility
    echo "resolve_pnpm_version: bun detected ('$raw'), using fallback pnpm $PNPM_FALLBACK_VERSION" >&2
    printf '%s\n' "$PNPM_FALLBACK_VERSION"
    return 0
  fi

  echo "resolve_pnpm_version: packageManager in $pkg_json is neither pnpm@ nor bun@ (got '${raw:-<empty>}')" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  resolve_pnpm_version "$@"
fi
