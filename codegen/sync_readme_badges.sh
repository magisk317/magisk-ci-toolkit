#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# sync_readme_badges.sh — shared README badge driver (magisk-ci-toolkit)
#
# Single implementation for every consumer repo. Tech badges are derived from
# the consumer's gradle/libs.versions.toml + gradle-wrapper.properties; the
# platform badge row is derived from config/readme-badges.conf. Marker blocks
# in README.md / README-EN.md are rewritten in place.
#
# Usage:
#   sync_readme_badges.sh --check <repo-root>   # exit 1 when a README is stale
#   sync_readme_badges.sh --write <repo-root>   # rewrite stale READMEs
#   sync_readme_badges.sh <repo-root>           # alias for --write
#
# Config: <repo-root>/config/readme-badges.conf (shell-sourceable)
#   PLATFORM=gitlab                              # only flavour today
#   PROJECT_PATH=magisk3171/XposedSmsCode        # GitLab project path
#   DEFAULT_BRANCH=beta                          # pipeline-status branch
#   LICENSE_ID=GPL-3.0                           # optional, default GPL-3.0
#
# Consumers: xinyi-relay, XposedSmsCode, MiPushFramework.
#
# Called by:
#   - release guard  (release/check_release_guard.sh :: check_readme_badges)
#   - GitLab CI      (.gitlab/ci/readme-badges.yml :: sync:readme-badges)
#   - manual runs    (bash <toolkit>/codegen/sync_readme_badges.sh <repo>)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/badges.sh"

MODE="write"
REPO_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check" ;;
    --write) MODE="write" ;;
    -h|--help)
      sed -n '2,26p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      if [[ -n "$REPO_ROOT" ]]; then
        echo "ERROR: unexpected argument: $1" >&2
        exit 2
      fi
      REPO_ROOT="$1"
      ;;
  esac
  shift
done

if [[ -z "$REPO_ROOT" ]]; then
  echo "ERROR: repo root required (usage: $0 --check|--write <repo-root>)" >&2
  exit 2
fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

CONF="${REPO_ROOT}/config/readme-badges.conf"
if [[ ! -f "$CONF" ]]; then
  echo "ERROR: missing badge config: ${CONF}" >&2
  exit 2
fi
# shellcheck source=/dev/null
source "$CONF"

PLATFORM="${PLATFORM:-gitlab}"
PROJECT_PATH="${PROJECT_PATH:-}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-beta}"
LICENSE_ID="${LICENSE_ID:-GPL-3.0}"
if [[ -z "$PROJECT_PATH" ]]; then
  echo "ERROR: PROJECT_PATH not set in ${CONF}" >&2
  exit 2
fi

TOML="${REPO_ROOT}/gradle/libs.versions.toml"
WRAPPER="${REPO_ROOT}/gradle/wrapper/gradle-wrapper.properties"
if [[ ! -f "$TOML" ]]; then
  echo "ERROR: missing ${TOML}" >&2
  exit 2
fi

kotlin="$(read_toml_value kotlin "$TOML")"
java="$(read_toml_value java "$TOML")"
compose="$(read_toml_value compose-bom-alpha "$TOML")"
agp="$(read_toml_value agp "$TOML")"
min_sdk="$(read_toml_value minSdk "$TOML")"
target_sdk="$(read_toml_value targetSdk "$TOML")"
xposed="$(read_toml_value libxposed-api "$TOML")"
gradle_ver="$(read_gradle_version "$WRAPPER")"
xposed_level="${xposed%%.*}"

missing=()
[[ -n "$kotlin" ]] || missing+=("kotlin")
[[ -n "$java" ]] || missing+=("java")
[[ -n "$compose" ]] || missing+=("compose-bom-alpha")
[[ -n "$agp" ]] || missing+=("agp")
[[ -n "$min_sdk" ]] || missing+=("minSdk")
[[ -n "$target_sdk" ]] || missing+=("targetSdk")
[[ -n "$xposed" ]] || missing+=("libxposed-api")
[[ -n "$gradle_ver" ]] || missing+=("gradle wrapper")
if (( ${#missing[@]} > 0 )); then
  echo "ERROR: unresolved version keys in ${TOML}: ${missing[*]}" >&2
  exit 2
fi

# --- tech stack (identical subset + order across all consumer repos) ---
tech="$(tech_badge Kotlin "$kotlin" 7F52FF kotlin https://kotlinlang.org)"
tech="$tech $(tech_badge Java "${java}+" E76F00 openjdk https://openjdk.org)"
tech="$tech $(tech_badge "Jetpack Compose" "BOM ${compose}" 4285F4 android https://developer.android.com/jetpack/compose)"
tech="$tech $(tech_badge Gradle "$gradle_ver" 02303A gradle https://gradle.org)"
tech="$tech $(tech_badge AGP "$agp" 3DDC84 gradle https://developer.android.com/studio/releases/gradle-plugin)"
tech="$tech $(tech_badge "Min SDK" "$min_sdk" brightgreen android https://developer.android.com/about/versions)"
tech="$tech $(tech_badge "Target SDK" "$target_sdk" blue android https://developer.android.com/about/versions)"
tech="$tech $(tech_badge "Xposed API" "$xposed_level" orange '' https://github.com/libxposed/api)"
tech="$tech $(tech_badge Telegram Group 2CA5E0 telegram https://t.me/+NR2QaQ4dlEgxYmNl)"

# --- platform row ---
project_enc="${PROJECT_PATH//\//%2F}"
case "$PLATFORM" in
  gitlab)
    plat="$(tech_badge GitLab "$PROJECT_PATH" FC6D26 gitlab "https://gitlab.com/${PROJECT_PATH}")"
    plat="$plat [![CI](https://img.shields.io/gitlab/pipeline-status/${project_enc}?branch=${DEFAULT_BRANCH}&style=flat-square&logo=gitlab&label=CI)](https://gitlab.com/${PROJECT_PATH}/-/pipelines?ref=${DEFAULT_BRANCH})"
    plat="$plat [![Latest Release](https://img.shields.io/gitlab/v/release/${project_enc}?include_prereleases&style=flat-square&logo=gitlab)](https://gitlab.com/${PROJECT_PATH}/-/releases)"
    plat="$plat $(tech_badge License "$LICENSE_ID" blue '' LICENSE)"
    ;;
  *)
    echo "ERROR: unsupported PLATFORM '${PLATFORM}' in ${CONF}" >&2
    exit 2
    ;;
esac

stale=()
synced=()

sync_one() {
  local readme="$1"
  [[ -f "$readme" ]] || return 0
  if [[ "$MODE" == "check" ]]; then
    local tmp
    tmp="$(mktemp -d)"
    cp "$readme" "${tmp}/README"
    replace_block "${tmp}/README" platform "$plat" >/dev/null
    replace_block "${tmp}/README" tech "$tech" >/dev/null
    if ! cmp -s "$readme" "${tmp}/README"; then
      stale+=("$(basename "$readme")")
      diff -u "$readme" "${tmp}/README" | sed 's/^/    /' || true
    fi
    rm -rf "$tmp"
  else
    replace_block "$readme" platform "$plat" >/dev/null
    replace_block "$readme" tech "$tech" >/dev/null
    synced+=("$(basename "$readme")")
  fi
}

for readme in "${REPO_ROOT}/README.md" "${REPO_ROOT}/README-EN.md"; do
  sync_one "$readme"
done

if [[ "$MODE" == "check" ]]; then
  if (( ${#stale[@]} > 0 )); then
    echo "FAIL: README badge blocks out of sync: ${stale[*]}" >&2
    echo "      fix: bash ${SCRIPT_DIR}/sync_readme_badges.sh ${REPO_ROOT} --write" >&2
    exit 1
  fi
  echo "PASS: README badge blocks in sync (${REPO_ROOT})"
else
  echo "README badges synced: ${synced[*]:-none} (${REPO_ROOT})"
fi
