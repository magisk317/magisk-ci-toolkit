#!/usr/bin/env bash
# Print the versionCode this build was allocated, or fail.
#
# Why a file at all: GitLab runs after_script in its own shell, so an `export`
# made in `script` does not reach the staging step that writes
# ci-dist/app-ci-manifest.json. Job-level `variables:` do reach it, which is why
# MAGISK_CI_TOOLKIT_DIR is usable there and MAGISK_VERSION_CODE was not. The
# build template therefore writes the number into the workspace
# (.magisk-version-code under the project root) and this helper reads it back,
# so there is one place that knows how to find it.
#
# Fail rather than guess: the manifest this number goes into is what the in-app
# updater compares, and an earlier wiring put the pipeline iid in the same slot.
# A build whose iid happened to equal a Play versionCode looked perfectly current
# and stopped offering updates. Silence here is a broken update channel that the
# job would otherwise report as green.
set -euo pipefail

code="${MAGISK_VERSION_CODE:-}"
file="${MAGISK_VERSION_CODE_FILE:-${CI_PROJECT_DIR:-.}/.magisk-version-code}"

# Keep the raw file content out-of-band: an empty file and a file that says "iid"
# need different messages. "no code" means the hand-off never happened; a
# non-numeric value means something wrote the wrong thing into the slot, and the
# operator has to be told which one.
raw=""
if [ -z "$code" ] && [ -f "$file" ]; then
  raw="$(tr -d '[:space:]' < "$file" || true)"
  code="$raw"
fi

if [ -z "$code" ]; then
  echo "allocated_version_code: no allocated versionCode available." >&2
  echo "  MAGISK_VERSION_CODE is unset and $file is missing or empty." >&2
  echo "  Set MAGISK_VERSION_SCOPE on the job so the template allocates one, or pass" >&2
  echo "  MAGISK_VERSION_CODE directly when staging outside a GitLab build job." >&2
  exit 1
fi

case "$code" in
  '' | *[!0-9]*)
    echo "allocated_version_code: '$code' is not a versionCode (digits only expected)." >&2
    if [ -n "$raw" ]; then
      echo "  Read from $file; the build template writes only the allocated number there." >&2
    fi
    exit 1
    ;;
esac

printf '%s\n' "$code"
