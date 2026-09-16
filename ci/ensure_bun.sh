#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [path/to/package.json]" >&2
}

ensure_bun() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local version
  version="$(bash "$here/resolve_bun_version.sh" "${1:-}")"
  local have
  have="$(bun --version 2>/dev/null || true)"

  if [[ "$have" == "$version" ]]; then
    return 0
  fi

  # If bun is already available but the exact version differs, try to
  # install the requested one.  If installation tooling is missing (common
  # in minimal Alpine images that already ship bun), warn and use the
  # pre-installed version rather than hard-failing.
  if [[ -n "$have" ]]; then
    echo "bun $have is installed; requested $version." >&2
    if ! command -v npm >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
      echo "WARNING: no npm/curl to install bun@$version; using pre-installed bun $have." >&2
      return 0
    fi
  fi

  echo "Installing bun@$version" >&2
  local registry_args=()
  if [[ -n "${BUN_CONFIG_REGISTRY:-}" ]]; then
    registry_args+=("--registry=$BUN_CONFIG_REGISTRY")
  fi
  if command -v npm >/dev/null 2>&1; then
    npm install --global --no-audit --no-fund --force "${registry_args[@]}" "bun@$version"
  elif command -v curl >/dev/null 2>&1 && command -v bash >/dev/null 2>&1; then
    export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
    curl -fsSL https://bun.sh/install | bash -s "bun-v$version"
    export PATH="$BUN_INSTALL/bin:$PATH"
  else
    echo "ensure_bun: cannot install bun without npm or curl+bash" >&2
    return 1
  fi

  [[ "$(bun --version)" == "$version" ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ensure_bun "$@"
fi
