#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
template="$root_dir/.gitlab/ci/telegram.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local value=$1 expected=$2 message=$3
  [[ "$value" == *"$expected"* ]] || fail "$message"
}

assert_not_contains() {
  local value=$1 unexpected=$2 message=$3
  [[ "$value" != *"$unexpected"* ]] || fail "$message"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
release_script="$tmp_dir/gitlab-telegram-release.sh"
capture_file="$tmp_dir/curl-args.txt"

awk '
  /cat > \/tmp\/magisk_telegram_release[.]sh <<.MAGISK_TELEGRAM_RELEASE_EOF./ {
    capture = 1
    next
  }
  capture && /MAGISK_TELEGRAM_RELEASE_EOF/ { exit }
  capture {
    sub(/^      /, "")
    print
  }
' "$template" > "$release_script"
bash -n "$release_script"

mkdir -p "$tmp_dir/work/docs" "$tmp_dir/work/artifacts"
touch "$tmp_dir/work/artifacts/XposedSmsCode_v3.3.1_arm64-v8a_release.apk"
cat > "$tmp_dir/work/docs/CHANGELOG.md" <<'CHANGELOG'
# Changelog

---

## [v3.3.1] - 2026-07-26
- 版本：`versionCode 123` / `versionName 3.3.1`。
- `[architecture]` Refined Hook and runtime boundaries with shared entry points.
- `[hook/sms]` Hardened SMS and MMS dispatch, recovery, and inbox handling.
- `[telemetry]` Added application and Xposed lifecycle observability.
- `[ci/deps]` Updated shared release tooling and core dependencies.

> Full Changelog: https://gitlab.com/magisk3171/XposedSmsCode/-/compare/v3.3.0...v3.3.1

---
CHANGELOG

curl() {
  # Assigned in the exported function environment below.
  # shellcheck disable=SC2153
  printf '%s\n' "$@" > "$CAPTURE_FILE"
}
export -f curl

(
  cd "$tmp_dir/work"
  CAPTURE_FILE="$capture_file" \
  TG_BOT_TOKEN=test \
  TG_CHAT_ID=test \
  MAGISK_TELEGRAM_PROJECT_NAME='Demo > Suite' \
  MAGISK_TELEGRAM_PROJECT_TAG='#Demo' \
  MAGISK_ANDROID_RELEASE_PACKAGE_NAME=com.example.demo \
  MAGISK_ANDROID_RELEASE_PLAY_URL=https://play.example/apps/demo \
  CI_PROJECT_NAME=Demo \
  CI_PROJECT_URL=https://gitlab.com/example/demo \
  CI_COMMIT_TAG=v3.3.1 \
  CI_COMMIT_TITLE='chore(deps): bump fastify' \
  CI_PIPELINE_ID=2706357831 \
  CI_PIPELINE_URL=https://gitlab.com/example/demo/-/pipelines/2706357831 \
    bash "$release_script" >/dev/null
)

captured="$(cat "$capture_file")"
assert_contains "$captured" 'Demo &gt; Suite' "greater-than signs must use valid HTML entities"
assert_not_contains "$captured" '>gt;' "Bash replacement must not corrupt HTML entities"
assert_contains "$captured" '<a href="https://gitlab.com/example/demo/-/releases/v3.3.1">v3.3.1</a>' \
  "release should use a labeled hyperlink"
assert_contains "$captured" '<a href="https://gitlab.com/example/demo/-/pipelines/2706357831">chore(deps): bump fastify</a>' \
  "pipeline link should hang off the commit line"
assert_not_contains "$captured" '🔗 Release:' \
  "release row should be gone now that the version is the link"
assert_contains "$captured" '<a href="https://play.example/apps/demo">Google Play</a>' \
  "Play should use the configured canonical link"
assert_not_contains "$captured" '🔗 Changelog:' "release message must not include the old changelog link"
assert_not_contains "$captured" 'Full Changelog: https://' "raw changelog URLs must not remain in the notes"

owner_rules="$(awk '
  /^\.magisk_android_release_owner_rules:/ { capture = 1 }
  capture { print }
  capture && /^\.magisk_android_release_guard:/ { exit }
' "$root_dir/.gitlab/ci/android-release.yml")"
assert_not_contains "$owner_rules" 'when: manual' "GitLab release must run automatically"
assert_not_contains "$owner_rules" 'allow_failure: true' "GitLab release must be blocking"

echo "GitLab Telegram release contract tests passed"
