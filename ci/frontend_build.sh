#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: frontend_build.sh

Configuration is supplied through environment variables:
  MAGISK_FRONTEND_DIR                 frontend working directory (default: .)
  MAGISK_FRONTEND_PACKAGE_JSON        manifest used to resolve Bun (default: DIR/package.json)
  MAGISK_FRONTEND_INSTALL_COMMAND     override dependency installation command
  MAGISK_FRONTEND_LINT_COMMAND       optional lint command
  MAGISK_FRONTEND_TYPECHECK_COMMAND  optional typecheck command
  MAGISK_FRONTEND_TEST_COMMAND       optional test command
  MAGISK_FRONTEND_BUILD_COMMAND      optional build command
  MAGISK_FRONTEND_DIST_DIR            optional output directory to verify
EOF
}

frontend_build() {
  local toolkit_dir
  toolkit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local frontend_dir="${MAGISK_FRONTEND_DIR:-.}"
  local package_json="${MAGISK_FRONTEND_PACKAGE_JSON:-$frontend_dir/package.json}"

  [[ -d "$frontend_dir" ]] || { echo "frontend_build: directory not found: $frontend_dir" >&2; return 2; }
  [[ -f "$package_json" ]] || { echo "frontend_build: package.json not found: $package_json" >&2; return 2; }

  bash "$toolkit_dir/ensure_bun.sh" "$package_json"
  cd "$frontend_dir"

  if [[ -n "${MAGISK_FRONTEND_INSTALL_COMMAND:-}" ]]; then
    bash -c "$MAGISK_FRONTEND_INSTALL_COMMAND"
  else
    bun install --frozen-lockfile --cache-dir "${BUN_INSTALL_CACHE_DIR:-.bun-cache}"
  fi

  local command_name command_value variable_name
  for command_name in LINT TYPECHECK TEST BUILD; do
    variable_name="MAGISK_FRONTEND_${command_name}_COMMAND"
    command_value="${!variable_name:-}"
    if [[ -n "$command_value" ]]; then
      echo ">>> $command_value"
      bash -c "$command_value"
    fi
  done

  if [[ -n "${MAGISK_FRONTEND_DIST_DIR:-}" ]]; then
    [[ -d "$MAGISK_FRONTEND_DIST_DIR" ]] || {
      echo "frontend_build: expected output directory not found: $MAGISK_FRONTEND_DIST_DIR" >&2
      return 1
    }
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi
  [[ $# -eq 0 ]] || { usage; exit 2; }
  frontend_build
fi
