#!/usr/bin/env bash
set -euo pipefail

MODE=write
root="$PWD"

usage() {
  cat <<'EOF'
Usage: sync_fastlane_changelogs.sh --root DIR [--check]

Synchronizes policy-selected distribution/whatsnew locale files to
Fastlane changelogs/<versionCode>.txt. Identical targets are left untouched.
EOF
}

while (($#)); do
  case "$1" in
    --root)
      (($# >= 2)) || { usage >&2; exit 2; }
      root="$2"
      shift 2
      ;;
    --check)
      MODE=check
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -d "$root" ]] || { echo "ERROR: root directory not found: $root" >&2; exit 2; }
policy="$root/scripts/config/release-policy.json"
if [[ -f "$policy" ]]; then
  if ! policy_values="$(python3 - "$policy" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    data = json.load(source)
locales = data.get("whatsnew_locales", ["en-US", "zh-CN"])
if not isinstance(locales, list) or not locales or not all(isinstance(item, str) and item for item in locales):
    raise SystemExit("release policy whatsnew_locales must be a non-empty string list")
for value in (
    data.get("version_file", "gradle/libs.versions.toml"),
    data.get("whatsnew_directory", "distribution/whatsnew"),
    data.get("fastlane_directory", "fastlane/metadata/android"),
    " ".join(locales),
):
    print(value)
PY
)"; then
    echo "ERROR: cannot read release policy: $policy" >&2
    exit 2
  fi
  mapfile -t values <<< "$policy_values"
  [[ ${#values[@]} -eq 4 ]] || { echo "ERROR: malformed release policy output" >&2; exit 2; }
  version_rel="${values[0]}"
  whatsnew_rel="${values[1]}"
  fastlane_rel="${values[2]}"
  read -r -a locales <<< "${values[3]}"
else
  version_rel=gradle/libs.versions.toml
  whatsnew_rel=distribution/whatsnew
  fastlane_rel=fastlane/metadata/android
  locales=(en-US zh-CN)
fi

version_file="$root/$version_rel"
[[ -f "$version_file" ]] || { echo "ERROR: missing version file: $version_file" >&2; exit 2; }
version_code="$(sed -nE 's/^versionCode[[:space:]]*=[[:space:]]*"([0-9]+)"/\1/p' "$version_file" | head -n1)"
[[ "$version_code" =~ ^[0-9]+$ ]] || { echo "ERROR: cannot parse numeric versionCode from $version_file" >&2; exit 2; }

status=0
for locale in "${locales[@]}"; do
  source_file="$root/$whatsnew_rel/whatsnew-$locale"
  target_file="$root/$fastlane_rel/$locale/changelogs/$version_code.txt"
  if [[ ! -s "$source_file" ]]; then
    echo "FAIL: missing or empty whatsnew source: $source_file" >&2
    status=1
    continue
  fi
  if [[ "$MODE" == check ]]; then
    if [[ ! -f "$target_file" ]]; then
      echo "FAIL: missing Fastlane changelog: $target_file" >&2
      status=1
    elif ! cmp -s "$source_file" "$target_file"; then
      echo "FAIL: Fastlane changelog differs from whatsnew: $target_file" >&2
      status=1
    else
      echo "CHECK: $locale changelog matches versionCode $version_code"
    fi
  elif [[ -f "$target_file" ]] && cmp -s "$source_file" "$target_file"; then
    echo "UNCHANGED: $locale changelog already matches versionCode $version_code"
  else
    mkdir -p "$(dirname "$target_file")"
    cp "$source_file" "$target_file"
    echo "SYNC: $locale -> $target_file"
  fi
done

(( status == 0 )) || exit "$status"
echo "Fastlane changelog $MODE passed for versionCode=$version_code"
