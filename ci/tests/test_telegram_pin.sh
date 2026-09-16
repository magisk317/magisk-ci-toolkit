#!/usr/bin/env bash
set -euo pipefail

# === Self-contained rolling-pin test ===
# Mock curl is defined at the top of this file. When run_with_mock prepends
# this file's mock section to the CI/Release/image-list scripts, the child
# bash process sees the function definition inline.

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
capture="$tmp_dir/curl-args.txt"

MOCK_VAR_STORE="$tmp_dir/ci-variables"
mkdir -p "$MOCK_VAR_STORE"
export MOCK_VAR_STORE

TG_MOCK_BOT_ID=8381781770

# Write ONLY the curl mock function to a file (no test logic)
cat > "$tmp_dir/mock_curl.sh" <<'CURL_MOCK'
curl() {
  local url="" arg
  for arg in "$@"; do
    case "$arg" in
      *"/bot"*) url="$arg" ;;
      */variables*) url="$arg" ;;
    esac
  done
  local method="${url##*/}"
  printf 'curl %s %s\n' "$method" "$*" >>"${CAPTURE_FILE:-/dev/null}"

  case "$method" in
    sendMessage)
      printf '{"ok":true,"result":{"message_id":1201,"from":{"id":%s}}}\n' "${TG_MOCK_BOT_ID:-0}"
      return 0 ;;
    sendDocument)
      printf '{"ok":true,"result":{"message_id":1202,"from":{"id":%s}}}\n' "${TG_MOCK_BOT_ID:-0}"
      return 0 ;;
    sendMediaGroup)
      printf '{"ok":true,"result":[{"message_id":3001,"from":{"id":%s}},{"message_id":3002,"from":{"id":%s}},{"message_id":3003,"from":{"id":%s}}]}\n' \
        "${TG_MOCK_BOT_ID:-0}" "${TG_MOCK_BOT_ID:-0}" "${TG_MOCK_BOT_ID:-0}"
      return 0 ;;
    pinChatMessage | unpinChatMessage)
      printf '{"ok":true,"result":true}\n'
      return 0 ;;
  esac

  if [[ "$url" == */variables* ]]; then
    local var_name="${url##*/variables/}"
    var_name="${var_name%%\?*}"
    local var_file="${MOCK_VAR_STORE:-/tmp}/$var_name"
    local hm="GET" pv=""
    for arg in "$@"; do
      [ "$pv" = "-X" ] && hm="$arg"
      pv="$arg"
    done
    case "$hm" in
      GET)
        if [ -f "$var_file" ]; then
          printf '{"key":"%s","value":"%s"}\n' "$var_name" "$(cat "$var_file")"
        else
          printf '{"message":"404"}\n'
        fi
        return 0 ;;
      PUT|POST|PATCH)
        pv=""
        for arg in "$@"; do
          if [ "$pv" = "--form" ]; then
            case "$arg" in value=*) printf '%s' "${arg#value=}" > "$var_file" ;; esac
          fi
          pv="$arg"
        done
        printf '{"key":"%s","value":"%s"}\n' "$var_name" "$(cat "$var_file" 2>/dev/null || echo '')"
        return 0 ;;
    esac
    return 0
  fi

  printf '{"ok":true,"result":{}}\n'
}
CURL_MOCK

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() {
  local value=$1 expected=$2 message=$3
  [[ "$value" == *"$expected"* ]] || fail "$message"
}
assert_not_contains() {
  local value=$1 unexpected=$2 message=$3
  [[ "$value" != *"$unexpected"* ]] || fail "$message"
}
assert_order() {
  local file=$1 first=$2 second=$3 message=$4
  local l1 l2
  l1="$(grep -n "^curl $first" "$file" | head -n1 | cut -d: -f1 || true)"
  l2="$(grep -n "^curl $second" "$file" | head -n1 | cut -d: -f1 || true)"
  [ -n "$l1" ] && [ -n "$l2" ] && [ "$l1" -lt "$l2" ] || fail "$message"
}

run_with_mock() {
  local workdir=$1 script=$2; shift 2
  local wrapped="$tmp_dir/wrapped.sh"
  cat "$tmp_dir/mock_curl.sh" "$script" > "$wrapped"
  for kv in "$@"; do export "$kv"; done
  local rc=0
  ( cd "$workdir" && bash "$wrapped" ) >"$tmp_dir/child_out.txt" 2>&1 || rc=$?
  rm -f "$wrapped"
  return $rc
}

set_mock_var() { printf '%s' "$2" > "$MOCK_VAR_STORE/$1"; }
clear_mock_vars() { rm -f "$MOCK_VAR_STORE"/*; }

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
template="$root_dir/.gitlab/ci/telegram.yml"
ci_script="$root_dir/ci/telegram_send_image_list.sh"
github_script="$root_dir/github/send_telegram_notification.sh"

# Shared work dir
work="$tmp_dir/work"
mkdir -p "$work/artifacts"
touch "$work/artifacts/Demo_v1_arm64-v8a.apk"
git -C "$work" init --quiet
git -C "$work" config user.name Test
git -C "$work" config user.email test@example.invalid
git -C "$work" config commit.gpgsign false
git -C "$work" commit --allow-empty --quiet -m 'chore: establish base'
git -C "$work" switch -c beta --quiet
merge_sha="$(git -C "$work" rev-parse HEAD)"
echo "test" > "$work/.merge-title"

extract_ci_heredoc() {
  awk '/cat > \/tmp\/magisk_telegram_ci[.]sh <<.MAGISK_TELEGRAM_CI_EOF./{c=1;next} c&&/MAGISK_TELEGRAM_CI_EOF/{exit} c{sub(/^      /,"");print}' "$1" > "$2"
}
extract_release_heredoc() {
  awk '/cat > \/tmp\/magisk_telegram_release[.]sh <<.MAGISK_TELEGRAM_RELEASE_EOF./{c=1;next} c&&/MAGISK_TELEGRAM_RELEASE_EOF/{exit} c{sub(/^      /,"");print}' "$1" > "$2"
}

ci_base_env=(
  "CAPTURE_FILE=$capture"
  "TG_MOCK_BOT_ID=$TG_MOCK_BOT_ID"
  "TG_BOT_TOKEN=test"
  "TG_CHAT_ID=test"
  "MAGISK_TELEGRAM_PROJECT_NAME=MiPushFramework"
  "MAGISK_TELEGRAM_PROJECT_TAG=#MiPushFramework"
  "MAGISK_TELEGRAM_VERSION_NAME=1.0.1"
  "CI_PROJECT_NAME=MiPushFramework"
  "CI_PROJECT_ID=12345"
  "CI_API_V4_URL=https://gitlab.com/api/v4"
  "GITLAB_API_TOKEN=fake-token"
  "CI_COMMIT_BRANCH=beta"
  "CI_COMMIT_SHA=$merge_sha"
  "CI_COMMIT_TITLE=merge_renovate_update"
  "CI_COMMIT_MESSAGE=merge_renovate_update"
  "CI_PIPELINE_ID=2790756570"
  "CI_PIPELINE_URL=https://gitlab.com/magisk3171/MiPushFramework/-/pipelines/2790756570"
  "MAGISK_CI_TOOLKIT_DIR=$root_dir"
)

run_ci_scenario() {
  local pin=$1 expect_unpin=$2; shift 2
  local media_group="" kv; local -a extra=()
  for kv in "$@"; do if [ "$kv" = "media-group" ]; then media_group=1; else extra+=("$kv"); fi; done
  local script="$tmp_dir/ci-script.sh"
  extract_ci_heredoc "$template" "$script"
  bash -n "$script"
  : >"$capture"
  run_with_mock "$work" "$script" "${ci_base_env[@]}" "MAGISK_TELEGRAM_PIN=$pin" "${extra[@]}" || true
  local captured; captured="$(cat "$capture")"
  # Debug: if no pinChatMessage, show child output
  if [[ "$captured" != *"pinChatMessage"* ]]; then
    echo "  DEBUG child_out:" >&2
    cp "$tmp_dir/child_out.txt" /tmp/pin_debug_child.txt 2>/dev/null || true
    cat /tmp/pin_debug_child.txt >&2 2>/dev/null || echo "  (no child_out)" >&2
  fi
  if [ -n "$media_group" ]; then
    assert_contains "$captured" "curl sendMediaGroup" "media-group should send album"
    assert_contains "$captured" "message_id=3001" "media-group must pin first item"
    assert_contains "$captured" "message_id=3002" "media-group must pin second item"
    assert_contains "$captured" "message_id=3003" "media-group must pin third item"
  else
    assert_contains "$captured" "curl sendDocument" "should send artifact"
    assert_contains "$captured" 'message_id=1202' "pin must use sent message id"
  fi
  if [ "$expect_unpin" = yes ]; then
    assert_contains "$captured" "curl unpinChatMessage" "expected unpin"
    assert_contains "$captured" "unpinChatMessage" "expected unpin"
  else
    assert_not_contains "$captured" "unpinChatMessage" "must not unpin"
  fi
}

# ============================================================================
echo "Scenario 1: CI with previous CI pin -> roll over"
clear_mock_vars
set_mock_var "TG_LAST_CI_PIN_ID" "8999"
run_ci_scenario latest yes
assert_order "$capture" pinChatMessage unpinChatMessage "pin must precede unpin"

echo "Scenario 2: CI with no previous pin -> just pin"
clear_mock_vars
run_ci_scenario latest no

echo "Scenario 3: PIN=off -> no pin API calls"
clear_mock_vars
: >"$capture"
run_with_mock "$work" "$tmp_dir/ci-script.sh" "${ci_base_env[@]}" "MAGISK_TELEGRAM_PIN=off" || true
captured="$(cat "$capture")"
assert_not_contains "$captured" 'pinChatMessage' "PIN=off must not pin"
assert_contains "$captured" "curl sendDocument" "should still send"

echo "Scenario 4: Release with previous Release pin -> roll over"
clear_mock_vars
set_mock_var "TG_LAST_RELEASE_PIN_ID" "8999"
rel_script="$tmp_dir/rel-script.sh"
extract_release_heredoc "$template" "$rel_script"
bash -n "$rel_script"
release_work="$tmp_dir/release-work"
mkdir -p "$release_work/docs" "$release_work/artifacts"
touch "$release_work/artifacts/XposedSmsCode_v3.3.1_arm64-v8a_release.apk"
cat > "$release_work/docs/CHANGELOG.md" <<'CL'
# Changelog
## [v3.3.1] - 2026-07-26
- Test
CL
: >"$capture"
run_with_mock "$release_work" "$rel_script" \
  "CAPTURE_FILE=$capture" "TG_MOCK_BOT_ID=$TG_MOCK_BOT_ID" \
  "TG_BOT_TOKEN=test" "TG_CHAT_ID=test" "MAGISK_TELEGRAM_PIN=latest" \
  "MAGISK_TELEGRAM_PROJECT_NAME=Demo" "MAGISK_TELEGRAM_PROJECT_TAG=#Demo" \
  "CI_PROJECT_NAME=Demo" "CI_PROJECT_ID=99999" \
  "CI_API_V4_URL=https://gitlab.com/api/v4" "GITLAB_API_TOKEN=fake-token" \
  "CI_COMMIT_TAG=v3.3.1" "CI_PIPELINE_ID=2706357831" "CI_PROJECT_URL=https://gitlab.com/example/demo" \
  "CI_PIPELINE_URL=https://gitlab.com/example/demo/-/pipelines/2706357831" || true
captured="$(cat "$capture")"
assert_contains "$captured" "curl pinChatMessage" "release should pin"
assert_contains "$captured" "curl unpinChatMessage" "release should unpin prev release pin"
assert_contains "$captured" 'message_id=8999' "release unpin must target old pin"

echo "Scenario 5: CI/Release independent (no cross-contamination)"
clear_mock_vars
set_mock_var "TG_LAST_CI_PIN_ID" "7777"
set_mock_var "TG_LAST_RELEASE_PIN_ID" "8888"
: >"$capture"
run_with_mock "$work" "$tmp_dir/ci-script.sh" "${ci_base_env[@]}" "MAGISK_TELEGRAM_PIN=latest" || true
captured="$(cat "$capture")"
assert_contains "$captured" "message_id=7777" "CI must unpin prev CI pin"
assert_not_contains "$captured" "message_id=8888" "CI must NOT unpin Release pin"

echo "Scenario 6: image-list script with previous CI pin -> roll over"
clear_mock_vars
set_mock_var "TG_LAST_IMAGES_PIN_ID" "8999"
: >"$capture"
run_with_mock "$tmp_dir" "$ci_script" \
  "CAPTURE_FILE=$capture" "TG_MOCK_BOT_ID=$TG_MOCK_BOT_ID" \
  "TG_BOT_TOKEN=test" "TG_CHAT_ID=test" "MAGISK_TELEGRAM_PIN=latest" \
  "MAGISK_TELEGRAM_IMAGE_PUBLISH_OK=1" "MAGISK_TELEGRAM_PROJECT_NAME=NapGram" \
  "MAGISK_TELEGRAM_PROJECT_TAG=#NapGram" "MAGISK_TELEGRAM_VERSION_NAME=0.1.5" \
  "MAGISK_TELEGRAM_IMAGE_EVENT=docker-dev" "MAGISK_TELEGRAM_PLATFORMS=linux/amd64" \
  "MAGISK_TELEGRAM_IMAGES=registry.gitlab.com/magisk3171/napgram:dev-latest" \
  "CI_PROJECT_NAME=NapGram" "CI_PROJECT_ID=55555" "CI_PROJECT_PATH=magisk3171/NapGram" "GITLAB_API_TOKEN=fake-token" \
  "CI_PROJECT_URL=https://gitlab.com/magisk3171/NapGram" \
  "CI_REGISTRY_IMAGE=registry.gitlab.com/magisk3171/napgram" \
  "CI_COMMIT_REF_NAME=beta" "CI_COMMIT_SHORT_SHA=83df2cce" \
  "CI_PIPELINE_URL=https://gitlab.com/magisk3171/NapGram/-/pipelines/2705536792" \
  "CI_PIPELINE_ID=2705536792" "CI_API_V4_URL=https://gitlab.com/api/v4" \
  "GITLAB_API_TOKEN=fake-token" || true
captured="$(cat "$capture")"
assert_contains "$captured" "curl pinChatMessage" "image-list should pin"
assert_contains "$captured" "curl unpinChatMessage" "image-list should unpin prev CI pin"

echo "Scenario 7: GitHub script with previous CI pin -> roll over"
clear_mock_vars
set_mock_var "TG_LAST_CI_PIN_ID" "8999"
: >"$capture"
run_with_mock "$work" "$github_script" \
  "CAPTURE_FILE=$capture" "TG_MOCK_BOT_ID=$TG_MOCK_BOT_ID" \
  "TG_BOT_TOKEN=test" "TG_CHAT_ID=test" "MAGISK_TELEGRAM_PIN=latest" \
  "PROJECT_TAG=#MiPushFramework" "CI_COMMIT_TITLE=ci:build" \
  "GITHUB_TOKEN=fake-gh" "GITHUB_REPOSITORY=magisk3171/MiPushFramework" \
  "WF_RUN_ID=424242" \
  "WF_RUN_URL=https://github.com/magisk3171/MiPushFramework/actions/runs/424242" \
  "WF_RUN_CONCLUSION=success" "WF_RUN_NAME=CI" "WF_RUN_BRANCH=beta" \
  "WF_RUN_REPO=magisk3171/MiPushFramework" || true
captured="$(cat "$capture")"
assert_contains "$captured" "curl pinChatMessage" "GitHub should pin"
assert_contains "$captured" "curl unpinChatMessage" "GitHub should unpin prev"

echo "Scenario 8: media group -> pin all items"
clear_mock_vars
set_mock_var "TG_LAST_CI_PIN_ID" "8999"
cp -a "$work" "$tmp_dir/work-mg"
touch "$tmp_dir/work-mg/artifacts/Demo_v1_arm64-v8a_part2.apk"
_orig_work="$work"; work="$tmp_dir/work-mg"
run_ci_scenario latest yes media-group
work="$_orig_work"

echo "Scenario 9: no GITLAB_API_TOKEN -> graceful degradation"
clear_mock_vars
: >"$capture"
run_with_mock "$work" "$tmp_dir/ci-script.sh" \
  "CAPTURE_FILE=$capture" "TG_MOCK_BOT_ID=$TG_MOCK_BOT_ID" \
  "TG_BOT_TOKEN=test" "TG_CHAT_ID=test" "MAGISK_TELEGRAM_PIN=latest" \
  "MAGISK_TELEGRAM_PROJECT_NAME=Test" "MAGISK_TELEGRAM_PROJECT_TAG=#Test" \
  "CI_PROJECT_NAME=Test" "CI_PROJECT_ID=12345" "CI_COMMIT_BRANCH=beta" \
  "CI_COMMIT_SHA=$merge_sha" "CI_COMMIT_TITLE=t" "CI_COMMIT_MESSAGE=t" \
  "CI_PIPELINE_ID=1" "CI_PIPELINE_URL=https://example.invalid" || true
captured="$(cat "$capture")"
assert_contains "$captured" "curl pinChatMessage" "should pin without token"
assert_not_contains "$captured" "unpinChatMessage" "no token = no unpin"

echo "All Telegram rolling-pin tests passed"
