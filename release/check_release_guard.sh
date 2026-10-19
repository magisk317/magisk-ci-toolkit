#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Release Guard — Modular Version
# Source this file and call check_release_guard with appropriate variables set.
# ============================================================================

# Default root depth (2 for scripts/release/, 1 for scripts/)
MAGISK_ROOT_DEPTH="${MAGISK_ROOT_DEPTH:-2}"

# Extract a TOML value from libs.versions.toml
extract_toml_value() {
  local key="$1"
  local file="$2"
  sed -nE "s/^${key}[[:space:]]*=[[:space:]]*\"([^\"]+)\"/\1/p" "$file" | head -n1
}

# Check version extraction from TOML
check_version_extraction() {
  local root_dir="$1"
  local version_file="${root_dir}/${MAGISK_RELEASE_VERSION_FILE:-gradle/libs.versions.toml}"

  if [[ ! -f "$version_file" ]]; then
    echo "ERROR: Missing $version_file" >&2
    return 1
  fi

  VERSION_NAME="$(extract_toml_value "versionName" "$version_file")"
  VERSION_CODE="$(extract_toml_value "versionCode" "$version_file")"
  if [[ -z "$VERSION_NAME" ]]; then
    echo "ERROR: Failed to parse versionName from $version_file" >&2
    return 1
  fi

  echo "- versionName: $VERSION_NAME"
  if [[ -n "$VERSION_CODE" ]]; then
    echo "- versionCode: $VERSION_CODE"
  fi
}

# Check for non-ASCII commit subjects in the pending release range.
check_commit_subjects() {
  local root_dir="$1"
  local allow_non_ascii="${2:-false}"
  local commit_range=""
  local range_source=""
  local base_ref=""
  local base_tag=""
  local upstream=""
  local checked=0
  local has_non_ascii=0
  local row=""
  local sha=""
  local subject=""
  local offenders=()

  if [[ "$allow_non_ascii" == "true" ]]; then
    echo "PASS: commit subject ASCII guard disabled by ALLOW_NON_ASCII_COMMIT_SUBJECT=true"
    return 0
  fi

  if [[ -n "${MAGISK_RELEASE_COMMIT_RANGE:-}" ]]; then
    commit_range="$MAGISK_RELEASE_COMMIT_RANGE"
    range_source="MAGISK_RELEASE_COMMIT_RANGE"
  else
    if [[ -n "${MAGISK_RELEASE_BASE_REF:-}" ]]; then
      base_ref="$MAGISK_RELEASE_BASE_REF"
      range_source="MAGISK_RELEASE_BASE_REF"
    elif [[ -n "${CI_COMMIT_BEFORE_SHA:-}" && ! "$CI_COMMIT_BEFORE_SHA" =~ ^0+$ ]]; then
      base_ref="$CI_COMMIT_BEFORE_SHA"
      range_source="CI_COMMIT_BEFORE_SHA"
    else
      upstream="$(git -C "$root_dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
      if [[ -n "$upstream" ]]; then
        base_ref="$upstream"
        range_source="upstream"
      fi
    fi

    if [[ -n "$base_ref" ]]; then
      if ! git -C "$root_dir" rev-parse --verify "${base_ref}^{commit}" >/dev/null 2>&1; then
        echo "FAIL: invalid release commit base ref: $base_ref" >&2
        return 1
      fi
      commit_range="${base_ref}..HEAD"
    else
      base_tag="$(git -C "$root_dir" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
      if [[ -n "$base_tag" ]]; then
        commit_range="${base_tag}..HEAD"
        range_source="latest release tag"
      else
        echo "FAIL: cannot determine release commit range; set MAGISK_RELEASE_BASE_REF or MAGISK_RELEASE_COMMIT_RANGE." >&2
        return 1
      fi
    fi
  fi

  while IFS=$'\t' read -r sha subject; do
    [[ -z "$sha" ]] && continue
    checked=$((checked + 1))
    if printf '%s' "$subject" | LC_ALL=C grep -q '[^ -~]'; then
      has_non_ascii=1
      offenders+=("$sha|$subject")
    fi
  done < <(git -C "$root_dir" log --no-merges --pretty=tformat:'%h%x09%s' "$commit_range")

  if (( checked == 0 )); then
    echo "PASS: commit subject check skipped (no commits in range: $commit_range; source: $range_source)"
    return 0
  fi

  if (( has_non_ascii == 0 )); then
    echo "PASS: commit subjects are ASCII-only ($checked commits, range: $commit_range; source: $range_source)"
    return 0
  fi

  echo "FAIL: non-ASCII commit subject detected (range: $commit_range; source: $range_source)"
  for row in "${offenders[@]}"; do
    sha="${row%%|*}"
    subject="${row#*|}"
    echo " - $sha $subject"
  done
  return 1
}

# Check CHANGELOG section exists
check_changelog_section() {
  local root_dir="$1"
  local version_name="$2"
  local changelog_file="${root_dir}/${MAGISK_RELEASE_CHANGELOG_FILE:-docs/CHANGELOG.md}"

  if [[ ! -f "$changelog_file" ]]; then
    echo "FAIL: missing changelog file ($changelog_file)"
    return 1
  fi

  if grep -Fq "## [v$version_name]" "$changelog_file"; then
    echo "PASS: changelog contains section for v$version_name"
    return 0
  else
    echo "FAIL: changelog section not found: ## [v$version_name] in $changelog_file"
    return 1
  fi
}

# versionCode must be exactly last-released + 1 (no jumps, no reuse).
# The CHANGELOG's first version section is the release being prepared; the
# second one is the last released version, whose versionCode is the baseline.
check_versioncode_increment() {
  local root_dir="$1"
  local toml_file="${root_dir}/gradle/libs.versions.toml"
  local changelog_file="${root_dir}/${MAGISK_RELEASE_CHANGELOG_FILE:-docs/CHANGELOG.md}"

  if [[ ! -f "$toml_file" ]]; then
    echo "FAIL: missing version catalog ($toml_file)"
    return 1
  fi
  if [[ ! -f "$changelog_file" ]]; then
    echo "FAIL: missing changelog file ($changelog_file)"
    return 1
  fi

  local current_code prev_code expected
  current_code="$(extract_toml_value versionCode "$toml_file")"
  if [[ ! "$current_code" =~ ^[0-9]+$ ]]; then
    echo "FAIL: versionCode is not numeric: '$current_code' ($toml_file)"
    return 1
  fi

  prev_code="$(awk '
    /^- 版本：`versionCode [0-9]+/ {
      if (++seen == 2) {
        line = $0
        sub(/^- 版本：`versionCode /, "", line)
        sub(/`.*$/, "", line)
        print line
        exit
      }
    }
  ' "$changelog_file")"
  if [[ ! "$prev_code" =~ ^[0-9]+$ ]]; then
    echo "FAIL: cannot read the previous released versionCode from $changelog_file" >&2
    echo "      (expected the second '- versionCode N' line below the in-progress section)" >&2
    return 1
  fi

  expected=$((prev_code + 1))
  if (( current_code != expected )); then
    echo "FAIL: versionCode $current_code is not last-released+1 (last released $prev_code, expected $expected)" >&2
    return 1
  fi
  echo "PASS: versionCode $current_code = last released $prev_code + 1"
}

# Check tag matches version
check_tag_matches_version() {
  local tag_name="$1"
  local version_name="$2"

  if [[ -z "$tag_name" ]]; then
    return 0
  fi

  expected_tag="v$version_name"
  if [[ "$tag_name" != "$expected_tag" ]]; then
    echo "FAIL: tag mismatch. got '$tag_name', expected '$expected_tag' from versionName."
    return 1
  else
    echo "PASS: tag matches versionName ($tag_name)"
    return 0
  fi
}

# Optional: Check whatsnew locales (XposedSmsCode + xinyi-relay)
check_whatsnew_locales() {
  local root_dir="$1"
  local version_name="$2"
  local required_locales=("${@:3}")
  local max_len="${MAX_WHATSNEW_LEN:-500}"
  local whatsnew_dir="${root_dir}/metadata/android/en-US/changelogs"

  if [[ ! -d "$whatsnew_dir" ]]; then
    echo "FAIL: missing whatsnew directory ($whatsnew_dir)"
    return 1
  fi

  local fail=0
  for locale in "${required_locales[@]}"; do
    file="$whatsnew_dir/whatsnew-$locale"
    if [[ ! -f "$file" ]]; then
      echo "FAIL: required whatsnew locale missing: $locale ($file)"
      fail=1
      continue
    fi

    count="$(wc -m < "$file" | tr -d '[:space:]')"
    if (( count == 0 )); then
      echo "FAIL: $locale is empty ($file)"
      fail=1
    elif (( count > max_len )); then
      echo "FAIL: $locale length=$count exceeds max=$max_len ($file)"
      fail=1
    else
      echo "PASS: $locale length=$count/$max_len"
    fi
  done

  return $fail
}

# Optional: Check fastlane metadata (xinyi-relay only)
check_fastlane_metadata() {
  local root_dir="$1"
  local required_locales=("${@:2}")
  local min_screenshots="${FASTLANE_MIN_SCREENSHOTS:-1}"
  local fastlane_dir="${root_dir}/fastlane/metadata/android"

  if [[ ! -d "$fastlane_dir" ]]; then
    echo "FAIL: missing fastlane metadata directory ($fastlane_dir)"
    return 1
  fi

  local fail=0
  for locale in "${required_locales[@]}"; do
    local images_dir="$fastlane_dir/$locale/images/phoneScreenshots"
    if [[ ! -d "$images_dir" ]]; then
      if (( min_screenshots > 0 )); then
        echo "FAIL: missing screenshots directory for locale $locale ($images_dir)"
        fail=1
      fi
      continue
    fi

    local count
    count="$(find "$images_dir" -maxdepth 1 -type f | wc -l)"
    if (( count < min_screenshots )); then
      echo "FAIL: locale $locale has $count screenshots, minimum is $min_screenshots"
      fail=1
    else
      echo "PASS: locale $locale has $count screenshots"
    fi
  done

  return $fail
}

# README badge blocks must match gradle/libs.versions.toml +
# gradle-wrapper.properties (tech row) and config/readme-badges.conf
# (platform row). The driver is shared with the GitLab sync job, so the
# release guard and CI can never disagree about what "in sync" means.
check_readme_badges() {
  local root_dir="$1"
  local toolkit_dir script out
  toolkit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  script="${toolkit_dir}/codegen/sync_readme_badges.sh"
  if [[ ! -f "$script" ]]; then
    echo "FAIL: badge sync driver not found: $script" >&2
    return 1
  fi
  if out="$(bash "$script" --check "$root_dir" 2>&1)"; then
    echo "PASS: README badges in sync with version catalog"
    return 0
  fi
  printf '%s\n' "$out" >&2
  echo "FAIL: README badge blocks are stale (run the sync driver with --write)" >&2
  return 1
}

validate_release_policy() {
  local root_dir="$1"
  local policy_file="${MAGISK_RELEASE_POLICY_FILE:-$root_dir/scripts/config/release-policy.json}"
  [[ -f "$policy_file" ]] || {
    echo "FAIL: release policy missing: $policy_file" >&2
    return 1
  }
  eval "$(python3 - "$policy_file" <<'PY'
import json
import shlex
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
required = {
    "version_file", "changelog_file", "require_changelog",
    "require_versioncode_increment", "require_readme_badges", "require_tag_match",
}
missing = sorted(required - data.keys())
if missing:
    raise SystemExit(f"release policy missing keys: {', '.join(missing)}")
for key in ("version_file", "changelog_file"):
    if not isinstance(data[key], str) or not data[key]:
        raise SystemExit(f"release policy {key} must be a non-empty string")
for key in required - {"version_file", "changelog_file"}:
    if not isinstance(data[key], bool):
        raise SystemExit(f"release policy {key} must be boolean")
print("MAGISK_RELEASE_VERSION_FILE=" + shlex.quote(data["version_file"]))
print("MAGISK_RELEASE_CHANGELOG_FILE=" + shlex.quote(data["changelog_file"]))
for key in ("require_changelog", "require_versioncode_increment", "require_readme_badges", "require_tag_match"):
    print("MAGISK_RELEASE_" + key.upper() + "=" + shlex.quote(str(data[key]).lower()))
if isinstance(data.get("allow_non_ascii_commit_subject"), bool):
    print("MAGISK_RELEASE_ALLOW_NON_ASCII_COMMIT_SUBJECT=" + shlex.quote(str(data["allow_non_ascii_commit_subject"]).lower()))
if isinstance(data.get("whatsnew_locales"), list):
    print("MAGISK_RELEASE_WHATSNEW_LOCALES=" + shlex.quote(" ".join(map(str, data["whatsnew_locales"]))))
if isinstance(data.get("fastlane_locales"), list):
    print("MAGISK_RELEASE_FASTLANE_LOCALES=" + shlex.quote(" ".join(map(str, data["fastlane_locales"]))))
if isinstance(data.get("whatsnew_max_length"), int):
    print("MAGISK_RELEASE_WHATSNEW_MAX_LENGTH=" + str(data["whatsnew_max_length"]))
if isinstance(data.get("fastlane_min_screenshots"), int):
    print("MAGISK_RELEASE_FASTLANE_MIN_SCREENSHOTS=" + str(data["fastlane_min_screenshots"]))
if isinstance(data.get("whatsnew_directory"), str):
    print("MAGISK_RELEASE_WHATSNEW_DIRECTORY=" + shlex.quote(data["whatsnew_directory"]))
PY
)"
  export MAGISK_RELEASE_POLICY_FILE="$policy_file"
}

# Main entry point — call this from your repo's wrapper script
check_release_guard() {
  local root_dir="${1:-.}"
  local tag_name="${2:-}"
  local allow_non_ascii="${ALLOW_NON_ASCII_COMMIT_SUBJECT:-false}"

  validate_release_policy "$root_dir" || return 1
  echo "Release guard"

  local fail=0
  export VERSION_NAME=""

  check_version_extraction "$root_dir" || fail=1
  check_commit_subjects "$root_dir" "$allow_non_ascii" || fail=1
  if [[ "${MAGISK_RELEASE_REQUIRE_CHANGELOG:-true}" == true ]]; then check_changelog_section "$root_dir" "$VERSION_NAME" || fail=1; fi
  if [[ "${MAGISK_RELEASE_REQUIRE_VERSIONCODE_INCREMENT:-true}" == true ]]; then check_versioncode_increment "$root_dir" || fail=1; fi
  if [[ "${MAGISK_RELEASE_REQUIRE_README_BADGES:-true}" == true ]]; then check_readme_badges "$root_dir" || fail=1; fi
  if [[ "${MAGISK_RELEASE_REQUIRE_TAG_MATCH:-true}" == true ]]; then check_tag_matches_version "$tag_name" "$VERSION_NAME" || fail=1; fi

  if (( fail != 0 )); then
    echo "Release guard failed." >&2
    return 1
  fi

  echo "Release guard passed."
  return 0
}

# If sourced directly (not from a wrapper), run with defaults
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ -n "${1:-}" ]] && [[ -d "$1" ]]; then
    ROOT_DIR="$1"
    TAG_NAME="${2:-}"
  else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ROOT_DIR="$(cd "${SCRIPT_DIR}$(printf '/..%.s' $(seq 1 "${MAGISK_ROOT_DEPTH}"))" && pwd)"
    TAG_NAME="${1:-}"
  fi

  check_release_guard "$ROOT_DIR" "$TAG_NAME"
fi
