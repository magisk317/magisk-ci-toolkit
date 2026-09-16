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
