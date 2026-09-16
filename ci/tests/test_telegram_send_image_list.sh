#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
export MAGISK_CI_TOOLKIT_DIR="$root_dir"
sender="$root_dir/ci/telegram_send_image_list.sh"

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
capture_file="$tmp_dir/curl-args.txt"
CAPTURE_FILE=""

curl() {
  printf '%s\n' "$@" >"$CAPTURE_FILE"
}
export -f curl

CAPTURE_FILE="$capture_file" \
TG_BOT_TOKEN=test \
TG_CHAT_ID=test \
MAGISK_TELEGRAM_IMAGE_PUBLISH_OK=1 \
MAGISK_TELEGRAM_PROJECT_NAME=NapGram \
MAGISK_TELEGRAM_PROJECT_TAG='#NapGram' \
MAGISK_TELEGRAM_VERSION_NAME=0.1.5 \
MAGISK_TELEGRAM_IMAGE_EVENT=docker-dev \
MAGISK_TELEGRAM_PLATFORMS=linux/amd64 \
MAGISK_TELEGRAM_IMAGES=$'registry.gitlab.com/magisk3171/napgram:dev-latest\nregistry.gitlab.com/magisk3171/napgram:dev-20260725' \
CI_PROJECT_NAME=NapGram \
CI_PROJECT_PATH=magisk3171/NapGram \
CI_PROJECT_URL=https://gitlab.com/magisk3171/NapGram \
CI_REGISTRY_IMAGE=registry.gitlab.com/magisk3171/napgram \
CI_COMMIT_REF_NAME=beta \
CI_COMMIT_SHORT_SHA=83df2cce \
CI_COMMIT_TITLE='fix(forward): keep buttons inline' \
CI_PIPELINE_URL=https://gitlab.com/magisk3171/NapGram/-/pipelines/2705536792 \
CI_PIPELINE_ID=2705536792 \
  bash "$sender" >/dev/null

captured="$(cat "$capture_file")"
registry_url='https://gitlab.com/magisk3171/NapGram/container_registry'
assert_contains "$captured" '✅ NapGram：v0.1.5' \
  "title should carry the human readable version"
assert_contains "$captured" $'#NapGram #v0_1_5\n' \
  "project and version hashtags should share one line"
assert_contains "$captured" "<a href=\"$registry_url\">GitLab</a>" \
  "registry platform should link to the container registry page"
assert_contains "$captured" $'GitLab</a>\n📋 ' \
  "platform line should be followed by the commit line"
assert_not_contains "$captured" 'dev-20260725' \
  "historical date tags should collapse into the platform line"
assert_not_contains "$captured" '📚 Repo:' "repo line should be gone"
assert_not_contains "$captured" '🌿 Ref:' "ref line should be gone"
assert_not_contains "$captured" '🐳 Platforms:' "platforms line should be gone"
assert_contains "$captured" '<a href="https://gitlab.com/magisk3171/NapGram/-/pipelines/2705536792">fix(forward): keep buttons inline</a>' \
  "commit title should carry the pipeline link"

(
  cd "$tmp_dir"
  CAPTURE_FILE="$capture_file" \
  TG_BOT_TOKEN=test \
  TG_CHAT_ID=test \
  MAGISK_TELEGRAM_IMAGE_PUBLISH_OK=1 \
  MAGISK_TELEGRAM_PROJECT_NAME=Demo \
  MAGISK_TELEGRAM_PROJECT_TAG='#Demo' \
  MAGISK_TELEGRAM_IMAGES='registry.example.invalid/demo:latest' \
  CI_COMMIT_REF_NAME=beta \
    bash "$sender" >/dev/null
)
captured="$(cat "$capture_file")"
assert_contains "$captured" $'#Demo\n' "missing version should retain the project hashtag"
assert_not_contains "$captured" '#v' "missing version should not create an empty version hashtag"

(
  cd "$tmp_dir"
  CAPTURE_FILE="$capture_file" \
  TG_BOT_TOKEN=test \
  TG_CHAT_ID=test \
  MAGISK_TELEGRAM_IMAGE_PUBLISH_OK=1 \
  MAGISK_TELEGRAM_PROJECT_NAME=Demo \
  MAGISK_TELEGRAM_PROJECT_TAG='#Demo' \
  MAGISK_TELEGRAM_IMAGES='registry.example.invalid/demo:latest' \
  CI_COMMIT_TAG=v2.4.0 \
  CI_COMMIT_REF_NAME=v2.4.0 \
    bash "$sender" >/dev/null
)
captured="$(cat "$capture_file")"
assert_contains "$captured" $'#Demo #v2_4_0\n' "release tag should provide the version hashtag fallback"

# --- a failed Telegram send must fail the job and never reach the pin step ----------
rc=0
(
  cd "$tmp_dir"
  curl() {
    printf '%s\n' "$@" >>"$CAPTURE_FILE"
    return 1
  }
  export -f curl
  CAPTURE_FILE="$capture_file" \
  TG_BOT_TOKEN=test \
  TG_CHAT_ID=test \
  MAGISK_TELEGRAM_PIN=latest \
  MAGISK_TELEGRAM_IMAGE_PUBLISH_OK=1 \
  MAGISK_TELEGRAM_PROJECT_NAME=Demo \
  MAGISK_TELEGRAM_PROJECT_TAG='#Demo' \
  MAGISK_TELEGRAM_IMAGES='registry.example.invalid/demo:latest' \
  CI_COMMIT_REF_NAME=beta \
    bash "$sender" >/dev/null 2>&1
) || rc=$?
[ "$rc" -eq 1 ] || fail "a failed Telegram send must exit non-zero"
captured="$(cat "$capture_file")"
assert_not_contains "$captured" 'pinChatMessage' "a failed send must not pin"

echo "Telegram image-list notification tests passed"
