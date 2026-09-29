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

# Runs the release script with the baseline environment plus any extra
# assignments passed as arguments, then echoes the captured curl arguments.
run_release() {
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
      env "$@" bash "$release_script" >/dev/null
    cat "$capture_file"
  )
}

captured="$(run_release)"
assert_contains "$captured" 'Demo &gt; Suite' "greater-than signs must use valid HTML entities"
assert_not_contains "$captured" '>gt;' "Bash replacement must not corrupt HTML entities"
assert_contains "$captured" '📦 Demo &gt; Suite：v3.3.1' \
  "the release head must carry the version as plain text"
assert_contains "$captured" '<a href="https://gitlab.com/example/demo/-/releases/v3.3.1">GitLab</a>' \
  "GitLab release must use a labeled hyperlink"
assert_contains "$captured" '<a href="https://github.com/magisk317/Demo/releases/tag/v3.3.1">GitHub</a>' \
  "the GitHub mirror link must default to <owner>/<CI_PROJECT_NAME>"
assert_contains "$captured" '<a href="https://play.example/apps/demo">Google Play</a>' \
  "Play should use the configured canonical link"
assert_not_contains "$captured" '🔗 Release:' \
  "the old Release row must be gone now that channels are labeled links"
assert_not_contains "$captured" '2706357831' \
  "the pipeline line must not be part of the release message"
assert_not_contains "$captured" 'chore(deps): bump fastify' \
  "the commit title line must not be part of the release message"
assert_not_contains "$captured" '🔗 Changelog:' "release message must not include the old changelog link"
assert_not_contains "$captured" 'Full Changelog: https://' "raw changelog URLs must not remain in the notes"
assert_not_contains "$captured" '🖼 Images' \
  "no image list command means no Images section"

# The mirror coordinates are overridable because they are not always
# <owner>/<CI_PROJECT_NAME>, for example when the mirror lives under another org.
captured_owner="$(run_release MAGISK_TELEGRAM_RELEASE_GITHUB_OWNER=some-org)"
assert_contains "$captured_owner" '<a href="https://github.com/some-org/Demo/releases/tag/v3.3.1">GitHub</a>' \
  "MAGISK_TELEGRAM_RELEASE_GITHUB_OWNER must override the mirror owner"

captured_repo="$(run_release MAGISK_TELEGRAM_RELEASE_GITHUB_REPO=NapGram/NapGram)"
assert_contains "$captured_repo" '<a href="https://github.com/NapGram/NapGram/releases/tag/v3.3.1">GitHub</a>' \
  "MAGISK_TELEGRAM_RELEASE_GITHUB_REPO must override the mirror coordinates"
assert_not_contains "$captured_repo" 'github.com/magisk317/Demo' \
  "the default mirror coordinates must not leak when overridden"

captured_no_github="$(run_release MAGISK_TELEGRAM_RELEASE_SHOW_GITHUB_LINK=false)"
assert_not_contains "$captured_no_github" 'github.com/' \
  "MAGISK_TELEGRAM_RELEASE_SHOW_GITHUB_LINK=false must hide the GitHub link"
assert_contains "$captured_no_github" 'GitLab</a>' \
  "the GitLab link must survive hiding the GitHub link"

owner_rules="$(awk '
  /^\.magisk_android_release_owner_rules:/ { capture = 1 }
  capture { print }
  capture && /^\.magisk_android_release_guard:/ { exit }
' "$root_dir/.gitlab/ci/android-release.yml")"
assert_not_contains "$owner_rules" 'when: manual' "GitLab release must run automatically"
assert_not_contains "$owner_rules" 'allow_failure: true' "GitLab release must be blocking"

# The backend image section renders one registry-collapsed hyperlink line
# per registry with the pushed tags as plain text; raw multi-segment refs must
# never appear.
captured_images="$(run_release \
  MAGISK_TELEGRAM_IMAGE_PUBLISH_OK=1 \
  MAGISK_TELEGRAM_IMAGE_LIST_COMMAND='printf "%s\n" registry.gitlab.com/example/demo/backend:v3.3.1 registry.gitlab.com/example/demo/backend:latest docker.io/example/xinyi-relay-backend:v3.3.1')"
assert_contains "$captured_images" '🖼 Images' \
  "the image section header must be present"
assert_contains "$captured_images" '<a href="https://gitlab.com/example/demo/-/container_registry">GitLab</a>：v3.3.1, latest' \
  "GitLab registry images must collapse into one labeled hyperlink with tags"
assert_contains "$captured_images" '<a href="https://hub.docker.com/r/example/xinyi-relay-backend">DockerHub</a>：v3.3.1' \
  "DockerHub images must link to the Docker Hub repository page"
assert_not_contains "$captured_images" 'registry.gitlab.com/example' \
  "raw registry hosts must not leak into the release message"
assert_not_contains "$captured_images" 'docker.io/example' \
  "raw docker.io hosts must not leak into the release message"

captured_images_fallback="$(run_release \
  MAGISK_TELEGRAM_IMAGE_PUBLISH_OK=1 \
  MAGISK_TELEGRAM_IMAGE_LIST_COMMAND='printf "%s\n" ghcr.io/example/demo/backend:v3.3.1')"
assert_contains "$captured_images_fallback" '📦 ghcr.io/example/demo/backend：v3.3.1' \
  "registries without a derivable web page keep the ref minus tag as the label"

echo "GitLab Telegram release contract tests passed"
