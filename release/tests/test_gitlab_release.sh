#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/assets"
printf 'apk' > "$TMP_DIR/assets/example.apk"
printf 'notes' > "$TMP_DIR/release-notes.md"

output="$({
  cd "$TMP_DIR"
  CI_API_V4_URL="https://gitlab.example/api/v4" \
  CI_PROJECT_ID="group/project" \
  CI_PROJECT_URL="https://gitlab.example/group/project" \
  CI_COMMIT_TAG="v1.2.3" \
  CI_JOB_TOKEN="test-token" \
  MAGISK_RELEASE_DRY_RUN="true" \
  MAGISK_RELEASE_NOTES_FILE="$TMP_DIR/release-notes.md" \
  MAGISK_GITLAB_RELEASE_PREPARED_ASSET_DIR="$TMP_DIR/assets" \
  MAGISK_GITLAB_RELEASE_DIRECT_ASSET_PREFIX="/mipush" \
    bash "$ROOT_DIR/release/gitlab_release.sh"
})"

grep -Fq 'https://gitlab.example/api/v4/projects/group%2Fproject/packages/generic/android-release/v1.2.3/example.apk' <<< "$output"
grep -Fq '"direct_asset_path": "/mipush/example.apk"' <<< "$output"

echo "gitlab release prepared-assets test passed"
