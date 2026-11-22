#!/usr/bin/env bash
# Reject consumer commits and pushes whose CI toolkit reference surfaces drift.
set -euo pipefail

repo="${1:-$(git rev-parse --show-toplevel)}"
ci_file="$repo/.gitlab-ci.yml"
[[ -f "$ci_file" ]] || exit 0

if ! grep -qE '^[[:space:]]*-[[:space:]]*project:[[:space:]]*magisk3171/shared/magisk-ci-toolkit([[:space:]]|$)' "$ci_file"; then
  exit 0
fi

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="${MAGISK_TOOLKIT_PIN_GUARD:-$hook_dir/../verify_toolkit_pin.sh}"
[[ -f "$guard" ]] || {
  echo "toolkit pin gate: missing guard $guard" >&2
  exit 1
}

bash "$guard" --root "$repo"
