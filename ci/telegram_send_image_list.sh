#!/usr/bin/env bash
# Send a Telegram text notification with a container image list.
# Intended for GitLab CI docker publish jobs (NapGram, xinyi-relay backend, ...).
#
# Required:
#   TG_BOT_TOKEN, TG_CHAT_ID
#
# Identity:
#   MAGISK_TELEGRAM_PROJECT_NAME   default: $CI_PROJECT_NAME
#   MAGISK_TELEGRAM_PROJECT_TAG    default: #$CI_PROJECT_NAME
#   MAGISK_TELEGRAM_IMAGE_EVENT    default: docker  (title suffix, e.g. docker-dev)
#
# Image list (one of):
#   MAGISK_TELEGRAM_IMAGES         full image refs, one per line (preferred)
#   MAGISK_TELEGRAM_IMAGE_REPOS + MAGISK_TELEGRAM_IMAGE_TAGS
#                                  cartesian product repo:tag
#   MAGISK_TELEGRAM_IMAGE_LIST_COMMAND
#                                  command that prints full image refs
#
# Optional:
#   MAGISK_TELEGRAM_PLATFORMS      default: linux/amd64, linux/arm64
#   MAGISK_TELEGRAM_VERSION_NAME   override auto-detected app versionName
#   MAGISK_TELEGRAM_CI_BRANCH      if set, only notify on that branch or renovate/* MRs
#   MAGISK_TELEGRAM_PIN            latest = pin each notification and roll the
#                                  pin over to it (unpins the bot's own previous
#                                  pin in the same topic only)
#   TG_CI_THREAD_ID / TG_GITLAB_THREAD_ID / TG_THREAD_ID
#   TG_API_BASE
set -euo pipefail

if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
  echo "TG_BOT_TOKEN/TG_CHAT_ID not set, skip."
  exit 0
fi

# Default: only notify after a successful image publish job.
# Consumers should needs: the manifest/publish job (optional: false) and pass
# MAGISK_TELEGRAM_IMAGE_PUBLISH_OK=1 via dotenv artifacts from that job.
require_publish_ok="${MAGISK_TELEGRAM_REQUIRE_PUBLISH_OK:-true}"
case "${require_publish_ok,,}" in
  1|true|yes|on)
    if [[ "${MAGISK_TELEGRAM_IMAGE_PUBLISH_OK:-}" != "1" ]]; then
      echo "Image publish did not signal success (MAGISK_TELEGRAM_IMAGE_PUBLISH_OK!=1); skip notify."
      exit 0
    fi
    ;;
esac

target_branch="${MAGISK_TELEGRAM_CI_BRANCH:-}"
if [[ -n "$target_branch" ]]; then
  source_branch="${CI_MERGE_REQUEST_SOURCE_BRANCH_NAME:-}"
  if [[ "${CI_COMMIT_BRANCH:-}" != "$target_branch" && "${source_branch}" != renovate/* && -z "${CI_COMMIT_TAG:-}" ]]; then
    echo "Branch ${CI_COMMIT_BRANCH:-${source_branch:-}} is not ${target_branch}/tag/renovate; skip."
    exit 0
  fi
fi

TG_API_BASE="${TG_API_BASE:-https://api.telegram.org}"
TG_API_BASE="${TG_API_BASE%/}"

python_bin=""
if command -v python3 >/dev/null 2>&1; then
  python_bin="python3"
elif command -v python >/dev/null 2>&1; then
  python_bin="python"
fi

telegram_api_url() {
  printf '%s/bot%s/%s' "$TG_API_BASE" "$TG_BOT_TOKEN" "$1"
}

# --- optional rolling pin (MAGISK_TELEGRAM_PIN=latest) ---
TELEGRAM_LAST_MESSAGE_IDS=""

telegram_capture_message_ids() {
  local resp=${1:-}
  [ -n "$resp" ] || return 0
  local ids
  ids=""
  local _cap_dir="${MAGISK_CI_TOOLKIT_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
  if [ -n "$python_bin" ] && [ -f "$_cap_dir/ci/capture_ids.py" ]; then
    ids="$(printf '%s' "$resp" | "$python_bin" "$_cap_dir/ci/capture_ids.py" 2>/dev/null)" || {
      echo "capture_ids failed; Telegram pin will be skipped" >&2
      ids=""
    }
  fi
  [ -n "$ids" ] || return 0
  TELEGRAM_LAST_MESSAGE_IDS="$ids"
}

telegram_read_pin_var() {
  local var_name=$1
  local val=""
  if [ -n "${GITLAB_API_TOKEN:-}" ] && [ -n "${CI_PROJECT_ID:-}" ]; then
    val="$(curl -sS --header "PRIVATE-TOKEN: $GITLAB_API_TOKEN" \
      "${CI_API_V4_URL:-https://gitlab.com/api/v4}/projects/$CI_PROJECT_ID/variables/$var_name" 2>/dev/null \
      | sed -nE 's/.*"value":"?([^"]*)"?.*/\1/p' || true)"
  fi
  [ "$val" != "0" ] && [ -n "$val" ] && printf '%s' "$val" || true
}

telegram_write_pin_var() {
  local var_name=$1 value=$2
  [ -n "${GITLAB_API_TOKEN:-}" ] && [ -n "${CI_PROJECT_ID:-}" ] || return 0
  local api="${CI_API_V4_URL:-https://gitlab.com/api/v4}"
  local rc
  rc="$(curl -sS -o /dev/null -w '%{http_code}' --header "PRIVATE-TOKEN: $GITLAB_API_TOKEN" \
    "$api/projects/$CI_PROJECT_ID/variables/$var_name" 2>/dev/null || true)"
  if [ "$rc" = "200" ]; then
    curl -sS -X PUT --header "PRIVATE-TOKEN: $GITLAB_API_TOKEN" \
      "$api/projects/$CI_PROJECT_ID/variables/$var_name" \
      --form "value=$value" >/dev/null 2>&1 || true
  else
    curl -sS -X POST --header "PRIVATE-TOKEN: $GITLAB_API_TOKEN" \
      "$api/projects/$CI_PROJECT_ID/variables" \
      --form "key=$var_name" --form "value=$value" >/dev/null 2>&1 || true
  fi
}

telegram_pin_latest() {
  [ "${MAGISK_TELEGRAM_PIN:-latest}" = "latest" ] || return 0
  local message_ids=${TELEGRAM_LAST_MESSAGE_IDS:-}
  if [ -z "$message_ids" ]; then
    echo "MAGISK_TELEGRAM_PIN=latest but no message id was captured; nothing to pin."
    return 0
  fi
  local pin_type=${2:-ci}
  local var_name="TG_LAST_$(printf '%s' "$pin_type" | tr '[:lower:]' '[:upper:]')_PIN_ID"

  local old_ids=""
  old_ids="$(telegram_read_pin_var "$var_name")"

  local _thread="${1:-}"
  local any_failed=0

  local mid
  for mid in $(printf '%s' "$message_ids" | tr ',' ' '); do
    local pin_args=(-d "chat_id=${TG_CHAT_ID}" -d "message_id=${mid}" -d "disable_notification=true")
    if [ -n "$_thread" ]; then
      pin_args+=(-d "message_thread_id=$_thread")
    fi
    local pin_resp
    pin_resp="$(curl -sS -X POST "$(telegram_api_url pinChatMessage)" "${pin_args[@]}" 2>&1)" || true
    if ! printf '%s' "$pin_resp" | grep -q '"ok":true'; then
      echo "Telegram pinChatMessage failed for $mid: $pin_resp" >&2
      any_failed=1
    fi
  done

  if [ "$any_failed" -eq 1 ]; then
    echo "Some pins failed; keeping previous pinned messages."
    return 0
  fi

  if [ -n "$old_ids" ]; then
    for mid in $(printf '%s' "$old_ids" | tr ',' ' '); do
      if printf '%s' ",$message_ids," | grep -q ",$mid,"; then
        continue
      fi
      local unpin_args=(-d "chat_id=${TG_CHAT_ID}" -d "message_id=$mid")
      if [ -n "$_thread" ]; then
        unpin_args+=(-d "message_thread_id=$_thread")
      fi
      local unpin_resp
      unpin_resp="$(curl -sS -X POST "$(telegram_api_url unpinChatMessage)" "${unpin_args[@]}" 2>&1)" || true
      if ! printf '%s' "$unpin_resp" | grep -q '"ok":true'; then
        echo "Telegram unpinChatMessage failed for $mid: $unpin_resp" >&2
      fi
    done
  fi

  telegram_write_pin_var "$var_name" "$message_ids"
}

telegram_html_escape() {
  local value=${1:-}
  value=${value//&/\&amp;}
  value=${value//</\&lt;}
  value=${value//>/\&gt;}
  value=${value//\"/\&quot;}
  printf '%s' "$value"
}

telegram_html_link() {
  local url=$1
  local label=$2
  if [[ -z "$url" ]]; then
    telegram_html_escape "$label"
    return
  fi
  printf '<a href="%s">%s</a>' "$(telegram_html_escape "$url")" "$(telegram_html_escape "$label")"
}

telegram_version_hashtag() {
  local version="${MAGISK_TELEGRAM_VERSION_NAME:-}"
  if [[ -z "$version" && -f gradle/libs.versions.toml ]]; then
    version="$(awk -F'"' '/^[[:space:]]*versionName[[:space:]]*=/{print $2; exit}' gradle/libs.versions.toml)"
  fi
  if [[ -z "$version" && -f package.json ]]; then
    version="$(awk -F'"' '/^[[:space:]]*"version"[[:space:]]*:/{print $4; exit}' package.json)"
  fi
  if [[ -z "$version" ]]; then
    version="${CI_COMMIT_TAG:-}"
  fi
  version="${version#v}"
  version="${version#V}"
  version="$(printf '%s' "$version" | sed -E 's/[^[:alnum:]_]+/_/g; s/^_+//; s/_+$//')"
  [[ -n "$version" ]] && printf '#v%s' "$version"
  return 0
}

telegram_version_display() {
  local version="${MAGISK_TELEGRAM_VERSION_NAME:-}"
  if [[ -z "$version" && -f gradle/libs.versions.toml ]]; then
    version="$(awk -F'"' '/^[[:space:]]*versionName[[:space:]]*=/{print $2; exit}' gradle/libs.versions.toml)"
  fi
  if [[ -z "$version" && -f package.json ]]; then
    version="$(awk -F'"' '/^[[:space:]]*"version"[[:space:]]*:/{print $4; exit}' package.json)"
  fi
  if [[ -z "$version" ]]; then
    version="${CI_COMMIT_TAG:-}"
  fi
  version="${version#v}"
  version="${version#V}"
  [[ -n "$version" ]] && printf 'v%s' "$version"
  return 0
}

# Registry host of an image ref ("" when the ref omits it, i.e. Docker Hub shorthand).
telegram_registry_host() {
  local ref=$1 first
  first="${ref%%/*}"
  case "$first" in
    *.*|*:*) printf '%s' "$first" ;;
    *) printf '' ;;
  esac
}

# Short human label for the registry an image was pushed to.
telegram_registry_label() {
  local ref=$1 host
  host="$(telegram_registry_host "$ref")"
  case "$host" in
    ''|docker.io|index.docker.io|registry-1.docker.io) printf 'DockerHub' ;;
    ghcr.io) printf 'GHCR' ;;
    registry.gitlab.com) printf 'GitLab' ;;
    gcr.io|*.gcr.io) printf 'GCR' ;;
    *.amazonaws.com) printf 'ECR' ;;
    *) printf '%s' "$host" ;;
  esac
}

# Web page for a pushed image; empty when we cannot derive a meaningful one.
telegram_registry_url() {
  local ref=$1 label name
  label="$(telegram_registry_label "$ref")"
  name="${ref%:*}"
  case "$label" in
    DockerHub) printf 'https://hub.docker.com/r/%s' "${name#docker.io/}" ;;
    GitLab) printf '%s' "${registry_url:-}" ;;
    *) printf '' ;;
  esac
}

collect_images() {
  local images=()
  local line repo tag

  if [[ -n "${MAGISK_TELEGRAM_IMAGES:-}" ]]; then
    while IFS= read -r line; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" || "$line" == \#* ]] && continue
      images+=("$line")
    done <<< "${MAGISK_TELEGRAM_IMAGES}"
  elif [[ -n "${MAGISK_TELEGRAM_IMAGE_LIST_COMMAND:-}" ]]; then
    while IFS= read -r line; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" || "$line" == \#* ]] && continue
      images+=("$line")
    done < <(bash -lc "${MAGISK_TELEGRAM_IMAGE_LIST_COMMAND}")
  elif [[ -n "${MAGISK_TELEGRAM_IMAGE_REPOS:-}" && -n "${MAGISK_TELEGRAM_IMAGE_TAGS:-}" ]]; then
    local repos=() tags=()
    while IFS= read -r line; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" || "$line" == \#* ]] && continue
      repos+=("$line")
    done <<< "${MAGISK_TELEGRAM_IMAGE_REPOS}"
    while IFS= read -r line; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" || "$line" == \#* ]] && continue
      tags+=("$line")
    done <<< "${MAGISK_TELEGRAM_IMAGE_TAGS}"
    for repo in "${repos[@]}"; do
      for tag in "${tags[@]}"; do
        images+=("${repo}:${tag}")
      done
    done
  fi

  if [[ ${#images[@]} -eq 0 ]]; then
    echo "No container images resolved for Telegram notify; skip." >&2
    exit 0
  fi

  printf '%s\n' "${images[@]}"
}

images_file="$(mktemp)"
trap 'rm -f "$images_file"' EXIT
collect_images >"$images_file"

project_name="${MAGISK_TELEGRAM_PROJECT_NAME:-${CI_PROJECT_NAME:-project}}"
project_tag="${MAGISK_TELEGRAM_PROJECT_TAG:-#${project_name}}"
version_tag="$(telegram_version_hashtag)"
tag_line="${project_tag}${version_tag:+ $version_tag}"
event_name="${MAGISK_TELEGRAM_IMAGE_EVENT:-docker}"
platforms="${MAGISK_TELEGRAM_PLATFORMS:-linux/amd64, linux/arm64}"
project_path="${CI_PROJECT_PATH:-$project_name}"
project_url="${CI_PROJECT_URL:-}"
registry_url="${project_url:+${project_url%/}/container_registry}"
ref_name="${CI_COMMIT_REF_NAME:-${CI_COMMIT_BRANCH:-${CI_COMMIT_TAG:-unknown}}}"
commit_sha="${CI_COMMIT_SHA:-unknown}"
short_sha="${CI_COMMIT_SHORT_SHA:-${commit_sha:0:8}}"
thread="${TG_CI_THREAD_ID:-${TG_GITLAB_THREAD_ID:-${TG_THREAD_ID:-}}}"

# One line per registry platform: the label carries the registry name only,
# so repeated tags/filesystems collapse instead of dumping every full ref.
image_block=""
seen_platforms=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  platform="$(telegram_registry_label "$line")"
  case " ${seen_platforms} " in
    *" ${platform} "*) continue ;;
  esac
  seen_platforms="${seen_platforms} ${platform}"
  [[ -n "$image_block" ]] && image_block+=$'\n'
  image_block+="📦 $(telegram_html_link "$(telegram_registry_url "$line")" "$platform")"
done <"$images_file"

version_display="$(telegram_version_display)"
commit_title="${CI_COMMIT_TITLE:-${CI_COMMIT_MESSAGE:-}}"
commit_title="$(printf %s "$commit_title" | head -n 1)"

if [[ -n "$version_display" ]]; then
  title_line="✅ $(telegram_html_escape "$project_name")：$(telegram_html_escape "$version_display")"
else
  title_line="✅ $(telegram_html_escape "$project_name")"
fi
commit_line="📋 $(telegram_html_link "${CI_PIPELINE_URL:-}" "$commit_title")"

msg="$title_line"
if [[ -n "$tag_line" ]]; then
  msg+=$'\n'"$(telegram_html_escape "$tag_line")"
fi
if [[ -n "$image_block" ]]; then
  msg+=$'\n'"$image_block"
fi
if [[ -n "$commit_title" ]]; then
  msg+=$'\n'"$commit_line"
fi

curl_args=(
  --fail-with-body
  -sS
  -X POST
  "${TG_API_BASE}/bot${TG_BOT_TOKEN}/sendMessage"
  -d "chat_id=${TG_CHAT_ID}"
  --data-urlencode "text=${msg}"
  -d "parse_mode=HTML"
  -d "disable_web_page_preview=true"
)
if [[ -n "$thread" ]]; then
  curl_args+=(-d "message_thread_id=${thread}")
fi

echo "Sending Telegram image-list notification (${event_name}) with $(wc -l <"$images_file") image refs..."
if ! resp="$(curl "${curl_args[@]}")"; then
  printf '%s\n' "$resp" >&2
  exit 1
fi
telegram_capture_message_ids "$resp"
telegram_pin_latest "$thread" images
