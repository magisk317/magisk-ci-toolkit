#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [pnpm-version | path/to/package.json]" >&2
  echo "  With no argument the version follows the packageManager field in" >&2
  echo "  ./package.json (or \$PNPM_VERSION_PACKAGE_JSON). An explicit" >&2
  echo "  'pnpm@x.y.z' or 'x.y.z' overrides. A path resolves via that file." >&2
}

# Ensure the pnpm on PATH matches the version a repository pins.
#
# The single source of truth is the `packageManager` field in package.json
# (corepack convention); resolve_pnpm_version.sh performs the read. Callers
# should normally invoke this with no argument so the version always follows
# the repo.
#
# Accepted argument forms:
#   (none)              resolve from ./package.json (or $PNPM_VERSION_PACKAGE_JSON)
#   pnpm@x.y.z / x.y.z  use this exact version
#   path/to/package.json resolve from the given manifest
ensure_pnpm() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  local arg="${1:-}"
  local version=""

  if [[ -z "$arg" ]]; then
    version="$(bash "$here/resolve_pnpm_version.sh")"
  elif [[ "$arg" == pnpm@* || "$arg" =~ ^[0-9] ]]; then
    version="${arg#pnpm@}"
    version="${version%%+*}"
  elif [[ -f "$arg" ]]; then
    version="$(bash "$here/resolve_pnpm_version.sh" "$arg")"
  else
    echo "ensure_pnpm: '$arg' is neither a pnpm version nor an existing package.json" >&2
    usage
    return 2
  fi

  if [[ -z "$version" ]]; then
    echo "ensure_pnpm: unable to resolve a pnpm version" >&2
    return 2
  fi

  # Fast path: if whatever pnpm is already on PATH (corepack shim, prior global
  # install, etc.) already matches, do nothing. This keeps the job green when the
  # runtime image provides pnpm via corepack, and avoids clobbering an existing
  # binary.
  local current
  if current="$(pnpm --version 2>/dev/null)" && [[ "$current" == "$version" ]]; then
    return 0
  fi

  local registry="${PNPM_CONFIG_REGISTRY:-https://registry.npmjs.org}"
  npm install --global --no-audit --no-fund --force \
    --registry="$registry" \
    "pnpm@$version"

  local actual
  actual="$(pnpm --version)"
  if [[ "$actual" != "$version" ]]; then
    echo "Expected pnpm $version, got $actual" >&2
    return 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ensure_pnpm "$@"
fi
