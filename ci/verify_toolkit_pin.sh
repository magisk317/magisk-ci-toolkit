#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --root CONSUMER_ROOT" >&2
  exit 2
}

root_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root_dir="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
[[ -n "$root_dir" ]] || usage
root_dir="$(cd "$root_dir" && pwd)"
ci_file="$root_dir/.gitlab-ci.yml"
[[ -f "$ci_file" ]] || { echo "missing $ci_file" >&2; exit 1; }

sha_regex='^[0-9a-fA-F]{40}$'
ref="$(sed -nE 's/^[[:space:]]*MAGISK_CI_TOOLKIT_REF:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' "$ci_file" | head -n 1)"
[[ "$ref" =~ $sha_regex ]] || { echo "toolkit ref must be one full SHA, got: $ref" >&2; exit 1; }

mapfile -t refs < <(awk '
  /project:[[:space:]]*magisk3171\/shared\/magisk-ci-toolkit/ { seen=1; next }
  seen && /ref:/ { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/["[:space:]]/, ""); print; seen=0 }
' "$ci_file")
(( ${#refs[@]} > 0 )) || { echo "no toolkit includes found" >&2; exit 1; }
for include_ref in "${refs[@]}"; do
  [[ "$include_ref" == "$ref" ]] || { echo "include ref differs: $include_ref != $ref" >&2; exit 1; }
done

resolver="$root_dir/scripts/resolve_ci_toolkit.sh"
if [[ -f "$resolver" ]]; then
  fallback="$(sed -nE 's/^TOOLKIT_REF="\$\{MAGISK_CI_TOOLKIT_REF:-([^}]*)\}"$/\1/p' "$resolver")"
  [[ "$fallback" == "$ref" ]] || { echo "resolver fallback differs: $fallback != $ref" >&2; exit 1; }
fi

action="$root_dir/.github/actions/resolve-ci-toolkit/action.yml"
if [[ -f "$action" ]]; then
  action_ref="$(sed -nE "s/^[[:space:]]*default:[[:space:]]*['\"]?([0-9a-fA-F]{40})['\"]?[[:space:]]*$/\1/p" "$action")"
  if [[ -n "$action_ref" && "$action_ref" != "$ref" ]]; then
    echo "GitHub action ref differs: $action_ref != $ref" >&2
    exit 1
  fi
fi

printf 'CI toolkit pin verified: %s (%d includes)\n' "$ref" "${#refs[@]}"
