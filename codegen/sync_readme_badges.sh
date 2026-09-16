#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Sync README Badges — Template Version
# Source this file and call sync_badges with appropriate variables set.
# ============================================================================

# Default root depth (2 for scripts/codegen/, 1 for scripts/)
MAGISK_ROOT_DEPTH="${MAGISK_ROOT_DEPTH:-2}"

# Extract a TOML value from libs.versions.toml
extract_toml_value() {
  local key="$1"
  local file="$2"
  sed -nE "s/^${key}[[:space:]]*=[[:space:]]*\"([^\"]+)\"/\1/p" "$file" | head -n1
}

# Escape badge value
badge_escape() {
  local raw="$1"
  raw="${raw//-/--}"
  raw="${raw// /_}"
  printf '%s' "$raw"
}

# Generate a shield.io badge URL
generate_badge() {
  local label="$1"
  local value="$2"
  local color="$3"
  local logo="${4:-}"
  local logo_color="${5:-}"

  local escaped_value
  escaped_value="$(badge_escape "$value")"

  local url="https://img.shields.io/badge/${label}-${escaped_value}-${color}"
  if [[ -n "$logo" ]]; then
    url="${url}?logo=${logo}"
    if [[ -n "$logo_color" ]]; then
      url="${url}&logoColor=${logo_color}"
    fi
  fi

  printf '![%s](%s)' "$label" "$url"
}

# Core sync function — call this from your repo's wrapper script
sync_badges() {
  local root_dir="${1:-.}"
  local readme_file="${root_dir}/README.md"
  local toml_file="${root_dir}/gradle/libs.versions.toml"
  local wrapper_file="${root_dir}/gradle/wrapper/gradle-wrapper.properties"

  if [[ ! -f "$readme_file" ]]; then
    echo "ERROR: README.md not found: $readme_file" >&2
    return 1
  fi

  if [[ ! -f "$toml_file" ]]; then
    echo "ERROR: libs.versions.toml not found: $toml_file" >&2
    return 1
  fi

  # Read versions from TOML
  local kotlin_version
  kotlin_version="$(extract_toml_value "kotlin" "$toml_file")"
  local agp_version
  agp_version="$(extract_toml_value "agp" "$toml_file")"
  local min_sdk
  min_sdk="$(extract_toml_value "minSdk" "$toml_file")"
  local target_sdk
  target_sdk="$(extract_toml_value "targetSdk" "$toml_file")"
  local java_version
  java_version="$(extract_toml_value "java" "$toml_file")"

  # Read Gradle version
  local gradle_version=""
  if [[ -f "$wrapper_file" ]]; then
    gradle_version="$(sed -nE 's/^distributionUrl=.*gradle-([0-9A-Za-z.-]+)-(bin|all)\.zip/\1/p' "$wrapper_file")"
  fi

  # Generate badges (override these in your wrapper if needed)
  local badges=()

  if [[ -n "$kotlin_version" ]]; then
    badges+=("$(generate_badge "Kotlin" "$kotlin_version" "7F52FF" "kotlin" "white")")
  fi

  if [[ -n "$java_version" ]]; then
    badges+=("$(generate_badge "Java" "${java_version}+" "E76F00" "openjdk" "white")")
  fi

  if [[ -n "$gradle_version" ]]; then
    badges+=("$(generate_badge "Gradle" "$gradle_version" "02303A" "gradle" "white")")
  fi

  if [[ -n "$min_sdk" && -n "$target_sdk" ]]; then
    badges+=("$(generate_badge "Android" "${min_sdk}+ / target ${target_sdk}" "3DDC84" "android" "white")")
  fi

  if [[ -n "$agp_version" ]]; then
    badges+=("$(generate_badge "AGP" "$agp_version" "3DDC84" "gradle" "white")")
  fi

  # Add custom badges (set BADGES array in your wrapper)
  if [[ -v CUSTOM_BADGES[@] ]]; then
    badges+=("${CUSTOM_BADGES[@]}")
  fi

  # Update README
  local tmp_file
  tmp_file="$(mktemp)"

  # Find the badges section and replace it
  local in_badges=0
  local badge_start_line=0
  local badge_end_line=0
  local line_num=0

  while IFS= read -r line; do
    line_num=$((line_num + 1))
    if [[ "$line" =~ ^!\[.*\]\(https://img\.shields\.io/ ]]; then
      if [[ $badge_start_line -eq 0 ]]; then
        badge_start_line=$line_num
      fi
      badge_end_line=$line_num
    fi
  done < "$readme_file"

  if [[ $badge_start_line -eq 0 ]]; then
    echo "WARN: No badge lines found in README.md" >&2
    rm -f "$tmp_file"
    return 0
  fi

  # Reconstruct README with new badges
  line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    if [[ $line_num -lt $badge_start_line ]]; then
      echo "$line"
    elif [[ $line_num -eq $badge_start_line ]]; then
      printf '%s\n' "${badges[@]}"
    elif [[ $line_num -gt $badge_end_line ]]; then
      echo "$line"
    fi
  done < "$readme_file" > "$tmp_file"

  mv "$tmp_file" "$readme_file"

  echo "README badges synced from $toml_file"
}

# If sourced directly (not from a wrapper), run with defaults
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ROOT_DIR="$(cd "${SCRIPT_DIR}$(printf '/..%.s' $(seq 1 "${MAGISK_ROOT_DEPTH}"))" && pwd)"

  sync_badges "$ROOT_DIR"
fi
