#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --root PROJECT_ROOT --config compat-check.json [--toolkit TOOLKIT_DIR]" >&2
  exit 2
}

root_dir=""
config_file=""
toolkit_dir="${MAGISK_CI_TOOLKIT_DIR:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root_dir="$2"; shift 2 ;;
    --config) config_file="$2"; shift 2 ;;
    --toolkit) toolkit_dir="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
[[ -n "$root_dir" && -n "$config_file" ]] || usage
root_dir="$(cd "$root_dir" && pwd)"
config_file="$(cd "$(dirname "$config_file")" && pwd)/$(basename "$config_file")"
toolkit_dir="${toolkit_dir:-$root_dir/.magisk-ci-toolkit}"
runner="$toolkit_dir/gradle/run_gradle_with_retry.sh"
[[ -x "$runner" ]] || { echo "Gradle runner unavailable: $runner" >&2; exit 2; }

mapfile -t common_args < <(python3 - "$config_file" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
for value in config.get("gradle_args", []):
    print(value)
PY
)
if [[ -n "${MAGISK_GRADLE_ARGS:-}" ]]; then
  read -r -a env_args <<< "$MAGISK_GRADLE_ARGS"
  common_args+=("${env_args[@]}")
fi
if [[ "${SKIP_GOOGLE_SERVICES:-false}" == "true" ]]; then
  common_args+=("-PskipGoogleServices=true")
fi

mapfile -t groups < <(python3 - "$config_file" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    for index, _ in enumerate(json.load(handle).get("groups", [])):
        print(index)
PY
)
(( ${#groups[@]} > 0 )) || { echo "compat config has no task groups: $config_file" >&2; exit 2; }

cd "$root_dir"
for index in "${groups[@]}"; do
  mapfile -t group_args < <(python3 - "$config_file" "$index" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    group = json.load(handle)["groups"][int(sys.argv[2])]
for value in group.get("args", []):
    print(value)
PY
  )
  mapfile -t tasks < <(python3 - "$config_file" "$index" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    group = json.load(handle)["groups"][int(sys.argv[2])]
for value in group.get("tasks", []):
    print(value)
PY
  )
  ((${#tasks[@]} > 0)) || { echo "compat group $index has no tasks" >&2; exit 2; }
  echo "== compat group ${index}: ${tasks[*]} =="
  bash "$runner" "${common_args[@]}" "${group_args[@]}" "${tasks[@]}"
done
