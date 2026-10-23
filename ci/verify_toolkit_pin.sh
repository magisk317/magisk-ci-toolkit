#!/usr/bin/env bash
# SC2016: this guard matches Actions expression literals (${{ ... }}) verbatim,
# it does not want them expanded.
# shellcheck disable=SC2016
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
expected_ref="$(printf '%s' "$ref" | tr '[:upper:]' '[:lower:]')"

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

# The GitHub side has to run against the same toolkit commit the GitLab
# includes do. Each pattern below is a live code path on GitHub, not a comment:
#   * `uses: <repo>/magisk-ci-toolkit/<path>@<ref>` selects which reusable
#     workflow body or composite action the runner fetches;
#   * a `ref:` / `toolkit_ref:` input right after such a call selects which
#     toolkit checkout the job clones and runs scripts from;
#   * `git clone ... --branch <name> magisk-ci-toolkit.git` follows a moving
#     ref, so the pipeline changes behaviour with no commit in this repository.
# verify_toolkit_pin.sh used to cover only the GitLab includes, which is how
# xinyi-relay shipped GitHub workflows against an older toolkit for a whole
# release without anything noticing.
github_pins=0
dynamic_refs=0
if [[ -d "$root_dir/.github" ]]; then
  mapfile -t github_files < <(find "$root_dir/.github" -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)
  for file in "${github_files[@]}"; do
    # 1. Cross-repository `uses:` of toolkit workflows and actions.
    while IFS= read -r pinned; do
      [[ -n "$pinned" ]] || continue
      github_pins=$((github_pins + 1))
      pinned_lower="$(printf '%s' "$pinned" | tr '[:upper:]' '[:lower:]')"
      if [[ ! "$pinned" =~ $sha_regex ]]; then
        echo "GitHub uses ref must be one full toolkit SHA, got: $pinned ($file)" >&2
        exit 1
      fi
      if [[ "$pinned_lower" != "$expected_ref" ]]; then
        echo "GitHub uses ref differs: $pinned != $ref ($file)" >&2
        exit 1
      fi
    done < <(grep -hoE 'uses:[[:space:]]*[^ ]*magisk-ci-toolkit/[^ ]*@[^ "[:space:]]+' "$file" | sed -E 's#.*@##')

    # 2. The toolkit ref handed to the step that resolves the toolkit. Only
    # look at ref/toolkit_ref lines that follow such a call, otherwise an
    # unrelated `with: ref:` (a checkout of a branch, say) is a false positive.
    while IFS= read -r passed; do
      [[ -n "$passed" ]] || continue
      case "$passed" in
        '${{'*)
          dynamic_refs=$((dynamic_refs + 1))
          continue
          ;;
      esac
      github_pins=$((github_pins + 1))
      passed_lower="$(printf '%s' "$passed" | tr '[:upper:]' '[:lower:]')"
      if [[ ! "$passed" =~ $sha_regex ]]; then
        echo "GitHub toolkit ref must be one full SHA, got: $passed ($file)" >&2
        exit 1
      fi
      if [[ "$passed_lower" != "$expected_ref" ]]; then
        echo "GitHub toolkit ref differs: $passed != $ref ($file)" >&2
        exit 1
      fi
    done < <(awk '
      /(uses:[[:space:]]*[^[:space:]]*magisk-ci-toolkit[^[:space:]]*@)|(uses:[[:space:]]*[^[:space:]]*resolve-ci-toolkit)/ { window = 4; next }
      window > 0 && /^[[:space:]]*(ref|toolkit_ref):/ {
        sub(/^[[:space:]]*(ref|toolkit_ref):[[:space:]]*/, "")
        gsub(/^["'\'']|["'\'']$/, "")
        print
      }
      window > 0 { window-- }
    ' "$file")

    # 3. A toolkit clone must never track a branch or a tag name. Checked per
    # line, so an unrelated `git clone` of another repository in the same file
    # cannot trip it.
    while IFS= read -r clone_line; do
      [[ -n "$clone_line" ]] || continue
      cloned_ref="$(printf '%s' "$clone_line" | sed -nE 's#.*--branch[=:]?[[:space:]]*([^ "[:space:]]+).*#\1#p')"
      if [[ ! "$cloned_ref" =~ $sha_regex ]]; then
        echo "GitHub clones the toolkit without a pinned 40-character --branch SHA: $clone_line ($file)" >&2
        exit 1
      fi
      github_pins=$((github_pins + 1))
      if [[ "$(printf '%s' "$cloned_ref" | tr '[:upper:]' '[:lower:]')" != "$expected_ref" ]]; then
        echo "GitHub toolkit clone ref differs: $cloned_ref != $ref ($file)" >&2
        exit 1
      fi
    done < <(grep -E 'clone[^#]*magisk-ci-toolkit|magisk-ci-toolkit[^#]*clone' "$file" || true)
  done
fi

summary="$(printf 'CI toolkit pin verified: %s (%d includes, %d GitHub refs' "$ref" "${#refs[@]}" "$github_pins")"
if (( dynamic_refs > 0 )); then
  summary="$(printf '%s, %d dynamic refs not resolvable here' "$summary" "$dynamic_refs")"
fi
printf '%s)\n' "$summary"
