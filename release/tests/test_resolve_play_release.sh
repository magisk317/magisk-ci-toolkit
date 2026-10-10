#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
printf 'versionName = "0.2.3"\n' > "$tmp_dir/libs.versions.toml"
git init -q "$tmp_dir/repo"
git -C "$tmp_dir/repo" config user.email test@example.com
git -C "$tmp_dir/repo" config user.name test
git -C "$tmp_dir/repo" config commit.gpgsign false
printf x > "$tmp_dir/repo/file"
git -C "$tmp_dir/repo" add file && git -C "$tmp_dir/repo" commit -qm initial

run_case() {
  local expected_track="$1" expected_name="$2" tag="$3" branch="$4" expected_code="$5"
  env -u ANDROID_PUBLISHER_CREDENTIALS CI_COMMIT_TAG="$tag" CI_COMMIT_BRANCH="$branch" CI_PIPELINE_IID=175 \
    bash "$script_dir/../resolve_play_release.sh" --package-name example.app \
      --version-file "$tmp_dir/libs.versions.toml" --output "$tmp_dir/out" --initial-version-code 1569 \
      >/dev/null 2>&1
  # The resolver runs in the caller's repository; verify its pure decision cases
  grep -Fq "MAGISK_PLAY_TRACK=$expected_track" "$tmp_dir/out"
  grep -Fq "MAGISK_PLAY_VERSION_NAME=$expected_name" "$tmp_dir/out"
  grep -Fq "MAGISK_PLAY_VERSION_CODE=$expected_code" "$tmp_dir/out"
}

(cd "$tmp_dir/repo" && run_case alpha 0.2.3-alpha.175 '' beta 1570)
(cd "$tmp_dir/repo" && run_case beta 0.2.3-beta.175 v0.2.3-beta.1 '' 1570)
(cd "$tmp_dir/repo" && run_case production 0.2.3 v0.2.3 '' 1570)

if (cd "$tmp_dir/repo" && CI_COMMIT_TAG=v0.2.3-alpha.1 CI_PIPELINE_IID=175 \
  bash "$script_dir/../resolve_play_release.sh" --package-name example.app \
    --version-file "$tmp_dir/libs.versions.toml" --output "$tmp_dir/out" --initial-version-code 1569 \
    >/dev/null 2>&1); then
  echo 'FAIL: alpha tags must be rejected' >&2
  exit 1
fi
(cd "$tmp_dir/repo" && MAGISK_PLAY_TRACK_OVERRIDE=beta CI_PIPELINE_IID=175 \
  bash "$script_dir/../resolve_play_release.sh" --package-name example.app \
    --version-file "$tmp_dir/libs.versions.toml" --output "$tmp_dir/out" --initial-version-code 1569 \
    >/dev/null 2>&1)
grep -Fq 'MAGISK_PLAY_TRACK=beta' "$tmp_dir/out"
grep -Fq 'MAGISK_PLAY_VERSION_NAME=0.2.3-beta.175' "$tmp_dir/out"

if (cd "$tmp_dir/repo" && MAGISK_PLAY_TRACK_OVERRIDE=unsupported CI_PIPELINE_IID=175 \
  bash "$script_dir/../resolve_play_release.sh" --package-name example.app \
    --version-file "$tmp_dir/libs.versions.toml" --output "$tmp_dir/out" --initial-version-code 1569 \
    >/dev/null 2>&1); then
  echo 'FAIL: unsupported track override must be rejected' >&2
  exit 1
fi

echo 'PASS: Play release resolution cases'

# Contract: the review gate must read the real lifecycle from the read-only
# per-track releases endpoint (the legacy edits->tracks listing keeps
# reporting "completed" for a submission that is still in review, so it can
# never gate anything), apply on every track, and tolerate the endpoint's
# transient empty responses.
resolver="$script_dir/../resolve_play_release.sh"
grep -Fq '/tracks/${track}/releases' "$resolver" || { echo 'FAIL: resolver must query the per-track releases endpoint' >&2; exit 1; }
grep -Fq 'RELEASE_LIFECYCLE_STATE_' "$resolver" || { echo 'FAIL: resolver must strip the lifecycle state prefix' >&2; exit 1; }
grep -Fq 'MAGISK_PLAY_SKIP_STATUSES:-IN_REVIEW APPROVED_NOT_PUBLISHED' "$resolver" || { echo 'FAIL: default skip states must be IN_REVIEW and APPROVED_NOT_PUBLISHED' >&2; exit 1; }
grep -Fq 'incomplete body' "$resolver" || { echo 'FAIL: resolver must retry the transient empty releases response' >&2; exit 1; }
if grep -Fq '[[ "$track" == beta' "$resolver"; then
  echo 'FAIL: the review gate must not be restricted to the beta track' >&2
  exit 1
fi
grep -Fq '"$api_root/$edit_id/bundles"' "$resolver" || { echo 'FAIL: resolver must query edit bundles endpoint' >&2; exit 1; }
grep -Fq '/generatedApks/' "$resolver" || { echo 'FAIL: resolver must probe generatedApks endpoint for withdrawn bundles' >&2; exit 1; }

echo 'PASS: Play release gate contract'

# Fail-closed contract: when the track status cannot be resolved (Play API
# unreachable / credentials rejected), the resolver must order the publish
# step to skip instead of uploading blind.
openssl genrsa -out "$tmp_dir/key.pem" 2048 2>/dev/null
python3 - "$tmp_dir/key.pem" > "$tmp_dir/creds.json" <<'PY'
import json, sys
print(json.dumps({
    "private_key": open(sys.argv[1], encoding="utf-8").read(),
    "client_email": "resolver-test@example.com",
}))
PY
mkdir -p "$tmp_dir/bin"
printf '#!/bin/sh\nexit 7\n' > "$tmp_dir/bin/curl"
chmod +x "$tmp_dir/bin/curl"
if ! (cd "$tmp_dir/repo" && PATH="$tmp_dir/bin:$PATH" \
  ANDROID_PUBLISHER_CREDENTIALS="$(cat "$tmp_dir/creds.json")" \
  MAGISK_PLAY_TRACK_OVERRIDE=beta CI_PIPELINE_IID=175 \
  bash "$resolver" --package-name example.app \
    --version-file "$tmp_dir/libs.versions.toml" --output "$tmp_dir/out" \
    --initial-version-code 1569 >/dev/null 2>&1); then
  echo 'FAIL: resolver must exit 0 when the track query fails' >&2
  exit 1
fi
grep -Fq 'MAGISK_PLAY_SKIP_RELEASE=1' "$tmp_dir/out" || { echo 'FAIL: track query failure must set MAGISK_PLAY_SKIP_RELEASE=1 (fail-closed)' >&2; exit 1; }
grep -Fq 'MAGISK_PLAY_TRACK_STATUS=PLAY_QUERY_FAILED' "$tmp_dir/out" || { echo 'FAIL: track query failure must report PLAY_QUERY_FAILED' >&2; exit 1; }
grep -Fq 'MAGISK_PLAY_QUERY_STATUS=unavailable' "$tmp_dir/out" || { echo 'FAIL: track query failure must keep MAGISK_PLAY_QUERY_STATUS=unavailable' >&2; exit 1; }

echo 'PASS: Play release fail-closed contract'
