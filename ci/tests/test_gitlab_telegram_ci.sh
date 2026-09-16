#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
template="$root_dir/.gitlab/ci/telegram.yml"

auto_fail() {
  echo "FAIL: $*" >&2
  exit 1
}
assert_contains() {
  local value=$1 expected=$2 message=$3
  [[ "$value" == *"$expected"* ]] || auto_fail "$message"
}
assert_not_contains() {
  local value=$1 unexpected=$2 message=$3
  [[ "$value" != *"$unexpected"* ]] || auto_fail "$message"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
script="$tmp_dir/gitlab-telegram-ci.sh"
capture="$tmp_dir/curl-args.txt"

awk '
  /cat > \/tmp\/magisk_telegram_ci[.]sh <<.MAGISK_TELEGRAM_CI_EOF./ {
    capture = 1
    next
  }
  capture && /MAGISK_TELEGRAM_CI_EOF/ { exit }
  capture {
    sub(/^      /, "")
    print
  }
' "$template" > "$script"
bash -n "$script"

mkdir -p "$tmp_dir/work/artifacts"
touch "$tmp_dir/work/artifacts/Demo_v1_arm64-v8a.apk"
git -C "$tmp_dir/work" init --quiet
git -C "$tmp_dir/work" config user.name Test
git -C "$tmp_dir/work" config user.email test@example.invalid
git -C "$tmp_dir/work" config commit.gpgsign false
git -C "$tmp_dir/work" commit --allow-empty --quiet -m 'chore: establish base'
git -C "$tmp_dir/work" switch -c renovate/java-patch --quiet
git -C "$tmp_dir/work" commit --allow-empty --quiet -m 'chore(deps): update java patch dependencies'
feature_sha="$(git -C "$tmp_dir/work" rev-parse HEAD)"
git -C "$tmp_dir/work" switch -C beta HEAD~1 --quiet
git -C "$tmp_dir/work" merge --no-ff --no-edit "$feature_sha" --quiet
merge_sha="$(git -C "$tmp_dir/work" rev-parse HEAD)"

echo 'Merge branch '\''renovate/java-patch'\'' into '\''beta'\''' > "$tmp_dir/work/.merge-title"

curl() {
  printf '%s\n' "$@" > "$CAPTURE_FILE"
}
export -f curl
CAPTURE_FILE="$capture" \
TG_BOT_TOKEN=test \
TG_CHAT_ID=test \
MAGISK_TELEGRAM_PROJECT_NAME=MiPushFramework \
MAGISK_TELEGRAM_PROJECT_TAG='#MiPushFramework' \
MAGISK_TELEGRAM_VERSION_NAME=1.0.1 \
CI_PROJECT_NAME=MiPushFramework \
CI_COMMIT_BRANCH=beta \
CI_COMMIT_SHA="$merge_sha" \
CI_COMMIT_TITLE="Merge branch 'renovate/java-patch' into 'beta'" \
CI_COMMIT_MESSAGE="Merge branch 'renovate/java-patch' into 'beta'" \
CI_PIPELINE_ID=2790756570 \
CI_PIPELINE_URL=https://gitlab.com/magisk3171/MiPushFramework/-/pipelines/2790756570 \
  bash -c "cd '$tmp_dir/work' && bash '$script'" >/dev/null

captured="$(cat "$capture")"
assert_contains "$captured" 'chore(deps): update java patch dependencies' \
  'merge notification should use the source feature commit title'
assert_not_contains "$captured" "Merge branch 'renovate/java-patch' into 'beta'" \
  'merge notification should not use the generated merge title'
assert_contains "$captured" '2790756570' 'pipeline id should remain in notification'

echo 'Telegram CI merge-title notification test passed'
