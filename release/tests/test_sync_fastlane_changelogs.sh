#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
toolkit_root="$(cd "$script_dir/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'find "$tmp_dir" -depth -type f -delete; find "$tmp_dir" -depth -type d -empty -delete' EXIT

repo="$tmp_dir/repo"
mkdir -p "$repo/gradle" "$repo/scripts/config" \
  "$repo/distribution/whatsnew" \
  "$repo/fastlane/metadata/android/en-US/changelogs" \
  "$repo/fastlane/metadata/android/zh-CN/changelogs"
printf 'versionCode = "57"\nversionName = "0.4.4"\n' > "$repo/gradle/libs.versions.toml"
cat > "$repo/scripts/config/release-policy.json" <<'JSON'
{
  "version_file": "gradle/libs.versions.toml",
  "changelog_file": "docs/CHANGELOG.md",
  "whatsnew_directory": "distribution/whatsnew",
  "whatsnew_locales": ["en-US", "zh-CN"],
  "fastlane_directory": "fastlane/metadata/android"
}
JSON
printf 'English release note\n' > "$repo/distribution/whatsnew/whatsnew-en-US"
printf '中文发布说明\n' > "$repo/distribution/whatsnew/whatsnew-zh-CN"

script="$toolkit_root/release/sync_fastlane_changelogs.sh"
[[ -x "$script" ]] || { echo "FAIL: helper is missing or not executable" >&2; exit 1; }

bash "$script" --root "$repo"
second_sync="$(bash "$script" --root "$repo")"
[[ "$second_sync" == *"UNCHANGED: en-US changelog"* ]] || {
  echo "FAIL: identical en-US changelog should not be rewritten" >&2
  exit 1
}
cmp "$repo/distribution/whatsnew/whatsnew-en-US" \
  "$repo/fastlane/metadata/android/en-US/changelogs/57.txt"
cmp "$repo/distribution/whatsnew/whatsnew-zh-CN" \
  "$repo/fastlane/metadata/android/zh-CN/changelogs/57.txt"
bash "$script" --root "$repo" --check

printf 'changed\n' >> "$repo/distribution/whatsnew/whatsnew-en-US"
if bash "$script" --root "$repo" --check > "$tmp_dir/check.log" 2>&1; then
  echo "FAIL: check must reject a stale changelog" >&2
  exit 1
fi
grep -Fq "differs from whatsnew" "$tmp_dir/check.log"

bash "$script" --root "$repo"
bash "$script" --root "$repo" --check
echo "sync_fastlane_changelogs tests passed"
