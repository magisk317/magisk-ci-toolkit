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
  local version_file="${root_dir}/gradle/libs.versions.toml"

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
  local changelog_file="${root_dir}/docs/CHANGELOG.md"

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

# Main entry point — call this from your repo's wrapper script
check_release_guard() {
  local root_dir="${1:-.}"
  local tag_name="${2:-}"
  local allow_non_ascii="${ALLOW_NON_ASCII_COMMIT_SUBJECT:-false}"

  echo "Release guard"

  local fail=0
  export VERSION_NAME=""

  check_version_extraction "$root_dir" || fail=1
  check_commit_subjects "$root_dir" "$allow_non_ascii" || fail=1
  check_changelog_section "$root_dir" "$VERSION_NAME" || fail=1
  check_tag_matches_version "$tag_name" "$VERSION_NAME" || fail=1

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
