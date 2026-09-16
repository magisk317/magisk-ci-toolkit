#!/usr/bin/env bash
set -euo pipefail

if [ -z "${TG_BOT_TOKEN:-}" ]; then
  echo "TG_BOT_TOKEN not set, skip."
  exit 0
fi

# Cloud Bot API default. Point to Local Bot API, e.g. http://10.99.0.102:8081
TG_API_BASE="${TG_API_BASE:-https://api.telegram.org}"
TG_API_BASE="${TG_API_BASE%/}"
# Cloud hard limit ~50MB; Local Bot API (--local) can be raised via env.
TG_MAX_FILESIZE="${TG_MAX_FILESIZE:-$((50 * 1024 * 1024))}"
# Where to attach the single group caption: last (footer) or first
TG_MEDIA_CAPTION_POSITION="${TG_MEDIA_CAPTION_POSITION:-last}"
TG_MEDIA_CAPTION_MAX=1024

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
  if [ -z "$url" ]; then
    telegram_html_escape "$label"
    return
  fi
  printf '<a href="%s">%s</a>' "$(telegram_html_escape "$url")" "$(telegram_html_escape "$label")"
}

telegram_markdown_to_html() {
  local input_file
  input_file="$(mktemp)"
  cat > "$input_file"
  python3 - "$input_file" <<'PY'
import html
import pathlib
import re
import sys
import urllib.parse

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")


def esc(value: str, *, quote: bool = False) -> str:
    return html.escape(value, quote=quote)


def link(url: str, label: str) -> str:
    return f'<a href="{esc(url, quote=True)}">{esc(label)}</a>'


def compare_label(url: str) -> str:
    match = re.search(r"/compare/([^?#\s<>]+)\.\.\.([^?#\s<>]+)", url)
    if not match:
        return url
    left = urllib.parse.unquote(match.group(1))
    right = urllib.parse.unquote(match.group(2))
    return f"{left}...{right}"


def plain_markdown_to_html(value: str) -> str:
    escaped = esc(value)
    escaped = re.sub(r"\*\*([^*\n]+)\*\*", r"<b>\1</b>", escaped)
    escaped = re.sub(r"__([^_\n]+)__", r"<b>\1</b>", escaped)
    escaped = re.sub(r"~~([^~\n]+)~~", r"<s>\1</s>", escaped)
    return escaped


def inline_markdown_to_html(value: str) -> str:
    result: list[str] = []
    pos = 0
    code_or_link = re.compile(r"`([^`\n]+)`|\[([^\]\n]+)\]\((https?://[^)\s]+)\)")
    for match in code_or_link.finditer(value):
        result.append(plain_markdown_to_html(value[pos:match.start()]))
        if match.group(1) is not None:
            result.append(f"<code>{esc(match.group(1))}</code>")
        else:
            result.append(link(match.group(3), match.group(2)))
        pos = match.end()
    result.append(plain_markdown_to_html(value[pos:]))
    return "".join(result)


def line_to_html(line: str) -> str:
    changelog = re.match(r"^(\s*>[ \t]*)?Full Changelog:[ \t]*(https?://\S+)\s*$", line)
    if changelog:
        url = changelog.group(2)
        return f"🔗 Changelog: {link(url, compare_label(url))}"
    return inline_markdown_to_html(line)


output: list[str] = []
code_lines: list[str] = []
in_code = False

for line in source.splitlines():
    if line.strip().startswith("```"):
        if in_code:
            output.append(f"<pre><code>{esc(chr(10).join(code_lines))}</code></pre>")
            code_lines = []
            in_code = False
        else:
            in_code = True
            code_lines = []
        continue
    if in_code:
        code_lines.append(line)
    else:
        output.append(line_to_html(line))

if in_code:
    output.append(f"<pre><code>{esc(chr(10).join(code_lines))}</code></pre>")

print("\n".join(output))
PY
  rm -f "$input_file"
}

send_message() {
  local thread=$1
  local text=$2
  local resp
  local curl_args=(
    --fail-with-body
    -sS
    -X POST
    "${TG_API_BASE}/bot${TG_BOT_TOKEN}/sendMessage"
    -d "chat_id=${TG_CHAT_ID}"
    --data-urlencode "text=${text}"
    -d "parse_mode=HTML"
    -d "disable_web_page_preview=true"
  )
  if [ -n "$thread" ]; then
    curl_args+=(-d "message_thread_id=$thread")
  fi
  if ! resp="$(curl "${curl_args[@]}")"; then
    printf '%s\n' "$resp" >&2
    exit 1
  fi
  telegram_capture_message_id "$resp"
}

telegram_upload_name() {
  local name=$1
  local max_len=60

  if [ "${#name}" -le "$max_len" ]; then
    printf '%s' "$name"
    return 0
  fi

  local ext=""
  local stem=$name
  if [[ "$name" == *.* ]]; then
    ext=".${name##*.}"
    stem="${name%.*}"
  fi

  local keep=$((max_len - ${#ext} - 2))
  if [ "$keep" -lt 16 ]; then
    printf '%s' "$name"
    return 0
  fi

  local head_len=$((keep / 2))
  local tail_len=$((keep - head_len))
  printf '%s__%s%s' "${stem:0:head_len}" "${stem: -tail_len}" "$ext"
}

telegram_json_escape() {
  local value=${1:-}
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

telegram_truncate_caption() {
  local value=${1:-}
  if [ "${#value}" -le "$TG_MEDIA_CAPTION_MAX" ]; then
    printf '%s' "$value"
    return 0
  fi
  printf '%s…' "${value:0:$((TG_MEDIA_CAPTION_MAX - 1))}"
}

telegram_oversize_download_link() {
  local name=$1
  local size_mb=$2
  local link
  local link_label="Download"
  if [ -n "${WF_RUN_ID:-}" ]; then
    link="https://github.com/${WF_RUN_REPO}/actions/runs/${WF_RUN_ID}"
    link_label="${WF_RUN_ID}"
  elif [ -n "${RELEASE_TAG:-}" ]; then
    link="https://github.com/${WF_RUN_REPO}/releases/tag/${RELEASE_TAG}"
    link_label="${RELEASE_TAG}"
  else
    link="https://github.com/${WF_RUN_REPO}/releases"
  fi
  printf '📦 %s (%sMB) exceeds Telegram upload limit.\n🔗 Download: %s' \
    "$(telegram_html_escape "$name")" \
    "$size_mb" \
    "$(telegram_html_link "$link" "$link_label")"
}

telegram_api_url() {
  # usage: telegram_api_url METHOD
  printf '%s/bot%s/%s' "$TG_API_BASE" "$TG_BOT_TOKEN" "$1"
}

# --- optional rolling pin (MAGISK_TELEGRAM_PIN=latest) ---
TELEGRAM_LAST_MESSAGE_ID=""

telegram_capture_message_id() {
  local resp=${1:-}
  [ -n "$resp" ] || return 0
  local id
  id="$(printf '%s' "$resp" | tr -d '\n' | sed -nE 's/.*"message_id":([0-9]+).*/\1/p')"
  [ -n "$id" ] || return 0
  TELEGRAM_LAST_MESSAGE_ID="$id"
}

telegram_read_pin_var() {
  local var_name=$1
  local val=""
  local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [ -n "$token" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    val="$(curl -sS -H "Authorization: Bearer $token" \
      "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/variables/$var_name" 2>/dev/null \
      | sed -nE 's/.*"value":"?([^"]*)"?.*/\1/p' || true)"
  fi
  [ "$val" != "0" ] && [ -n "$val" ] && printf '%s' "$val" || true
}

telegram_write_pin_var() {
  local var_name=$1 value=$2
  local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  [ -n "$token" ] && [ -n "${GITHUB_REPOSITORY:-}" ] || return 0
  local rc
  rc="$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" \
    "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/variables/$var_name" 2>/dev/null || true)"
  if [ "$rc" = "200" ]; then
    curl -sS -X PATCH -H "Authorization: Bearer $token" \
      "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/variables/$var_name" \
      -H "Content-Type: application/json" -d "{\"value\":\"$value\"}" >/dev/null 2>&1 || true
  else
    curl -sS -X POST -H "Authorization: Bearer $token" \
      "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/variables" \
      -H "Content-Type: application/json" -d "{\"name\":\"$var_name\",\"value\":\"$value\"}" >/dev/null 2>&1 || true
  fi
}

telegram_pin_latest() {
  [ "${MAGISK_TELEGRAM_PIN:-latest}" = "latest" ] || return 0
  local message_id=${TELEGRAM_LAST_MESSAGE_ID:-}
  if [ -z "$message_id" ]; then
    echo "MAGISK_TELEGRAM_PIN=latest but no message id was captured; nothing to pin."
    return 0
  fi
  local pin_type=${2:-ci}
  local var_name="TG_LAST_$(printf '%s' "$pin_type" | tr '[:lower:]' '[:upper:]')_PIN_ID"

  local old_id=""
  old_id="$(telegram_read_pin_var "$var_name")"

  if ! curl --fail -sS -X POST "$(telegram_api_url pinChatMessage)" \
    -d "chat_id=${TG_CHAT_ID}" -d "message_id=${message_id}" \
    -d "disable_notification=true" >/dev/null 2>&1; then
    echo "Telegram pinChatMessage failed; keeping previous pinned message."
    return 0
  fi

  if [ -n "$old_id" ] && [ "$old_id" != "$message_id" ]; then
    curl --fail -sS -X POST "$(telegram_api_url unpinChatMessage)" \
      -d "chat_id=${TG_CHAT_ID}" -d "message_id=$old_id" >/dev/null 2>&1 || true
  fi

  telegram_write_pin_var "$var_name" "$message_id"
}

send_document() {
  local file=$1
  local thread=$2
  local caption=$3
  local resp
  local size
  size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
  local name
  name=$(basename "$file")
  local upload_name
  upload_name=$(telegram_upload_name "$name")

  if [ "$size" -gt "$TG_MAX_FILESIZE" ]; then
    echo "$name is $((size / 1024 / 1024))MB, exceeds Telegram upload limit; sending download link instead."
    send_message "$thread" "$(telegram_oversize_download_link "$name" "$((size / 1024 / 1024))")"
    return 0
  fi

  echo "Sending $file to Telegram..."
  local curl_args=(
    --fail-with-body
    -sS
    -X POST
    "$(telegram_api_url sendDocument)"
    -F "chat_id=${TG_CHAT_ID}"
    -F "document=@${file};filename=${upload_name};type=application/octet-stream"
  )
  if [ -n "$thread" ]; then
    curl_args+=(-F "message_thread_id=$thread")
  fi
  if [ -n "$caption" ]; then
    curl_args+=(--form-string "caption=$(telegram_truncate_caption "$caption")" --form-string "parse_mode=HTML")
  fi
  if ! resp="$(curl "${curl_args[@]}")"; then
    printf '%s\n' "$resp" >&2
    exit 1
  fi
  telegram_capture_message_id "$resp"
}

# One Telegram album/message for multiple docs (layout B by default).
# - every document caption starts with the APK/file name
# - group_caption (CI/release text, may contain HTML links) is appended on
#   first/last item via TG_MEDIA_CAPTION_POSITION (default: last / footer)
# - oversized files become separate download-link messages
send_documents_group() {
  local thread=$1
  local group_caption=${2:-}
  shift 2
  local files=("$@")
  local uploadable=()
  local file size name upload_name

  if [ "${#files[@]}" -eq 0 ]; then
    if [ -n "$group_caption" ]; then
      send_message "$thread" "$group_caption"
    fi
    return 0
  fi

  for file in "${files[@]}"; do
    size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
    name=$(basename "$file")
    if [ "$size" -gt "$TG_MAX_FILESIZE" ]; then
      echo "$name is $((size / 1024 / 1024))MB, exceeds Telegram upload limit; sending download link instead."
      send_message "$thread" "$(telegram_oversize_download_link "$name" "$((size / 1024 / 1024))")"
      continue
    fi
    uploadable+=("$file")
  done

  if [ "${#uploadable[@]}" -eq 0 ]; then
    if [ -n "$group_caption" ]; then
      send_message "$thread" "$group_caption"
    fi
    return 0
  fi

  if [ "${#uploadable[@]}" -eq 1 ]; then
    name=$(basename "${uploadable[0]}")
    local single_caption
    single_caption="$(telegram_html_escape "$name")"
    if [ -n "$group_caption" ]; then
      single_caption+=$(printf '\n\n%s' "$group_caption")
    fi
    send_document "${uploadable[0]}" "$thread" "$single_caption"
    return 0
  fi

  local idx=0
  local total=${#uploadable[@]}
  local chunk_index=0
  while [ "$idx" -lt "$total" ]; do
    local chunk=("${uploadable[@]:idx:10}")
    local media_items=()
    local curl_args=(
      --fail-with-body
      -sS
      -X POST
      "$(telegram_api_url sendMediaGroup)"
      -F "chat_id=${TG_CHAT_ID}"
    )
    if [ -n "$thread" ]; then
      curl_args+=(-F "message_thread_id=$thread")
    fi

    local attach_group_caption=0
    if [ "$chunk_index" -eq 0 ] && [ -n "$group_caption" ]; then
      attach_group_caption=1
    fi

    local i=0
    local caption_target=0
    if [ "$attach_group_caption" -eq 1 ]; then
      if [ "$TG_MEDIA_CAPTION_POSITION" = "first" ]; then
        caption_target=1
      else
        caption_target=${#chunk[@]}
      fi
    fi

    for file in "${chunk[@]}"; do
      i=$((i + 1))
      name=$(basename "$file")
      upload_name=$(telegram_upload_name "$name")
      local item_caption
      # Always show the original file name under each APK.
      item_caption="$(telegram_html_escape "$name")"
      if [ "$attach_group_caption" -eq 1 ] && [ "$i" -eq "$caption_target" ]; then
        item_caption+=$(printf '\n\n%s' "$group_caption")
      fi
      item_caption=$(telegram_truncate_caption "$item_caption")
      media_items+=("$(printf '{"type":"document","media":"attach://file%d","caption":"%s","parse_mode":"HTML"}' "$i" "$(telegram_json_escape "$item_caption")")")
      curl_args+=(-F "file${i}=@${file};filename=${upload_name};type=application/octet-stream")
    done

    local media_json
    media_json="[$(IFS=,; printf '%s' "${media_items[*]}")]"
    curl_args+=(--form-string "media=${media_json}")

    echo "Sending media group with ${#chunk[@]} documents to Telegram..."
    local resp
    if ! resp="$(curl "${curl_args[@]}")"; then
      printf '%s\n' "$resp" >&2
      exit 1
    fi
    telegram_capture_message_id "$resp"
    idx=$((idx + ${#chunk[@]}))
    chunk_index=$((chunk_index + 1))
  done
}

PROJECT_TAG="${PROJECT_TAG:?PROJECT_TAG is required}"
CI_BRANCH="${CI_BRANCH:-beta}"
RELEASE_NOTES_SOURCE="${RELEASE_NOTES_SOURCE:-docs/CHANGELOG.md}"
PROJECT_NAME="${PROJECT_TAG##*#}"

if [ -n "${WF_RUN_ID:-}" ]; then
  if [ "${WF_RUN_CONCLUSION:-}" != "success" ]; then
    exit 0
  fi

  if [ "${WF_RUN_NAME:-}" = "Release" ]; then
    if [[ "${WF_RUN_BRANCH:-}" != v* ]]; then
      exit 0
    fi

    RELEASE_TAG="${WF_RUN_BRANCH}"
    if ! ASSETS_JSON="$(gh release view "$RELEASE_TAG" --repo "$WF_RUN_REPO" --json assets --jq '.assets')"; then
      echo "Release $RELEASE_TAG not found, skip Telegram release notification."
      exit 0
    fi
  elif [ "${WF_RUN_NAME:-}" = "CI" ]; then
    if [ "${WF_RUN_BRANCH:-}" != "${CI_BRANCH}" ]; then
      exit 0
    fi

    if [ -n "${WF_RUN_SHA:-}" ] && git tag --points-at "$WF_RUN_SHA" 2>/dev/null | grep -q .; then
      echo "Commit $WF_RUN_SHA has tags, skipping CI notification (Release will notify)."
      exit 0
    fi

    if [ -n "${PROJECT_VERSION:-}" ]; then
      CI_MSG="✅ $(telegram_html_escape "${PROJECT_NAME}")：$(telegram_html_escape "${PROJECT_VERSION}")"
    else
      CI_MSG="✅ $(telegram_html_escape "${PROJECT_NAME}")"
    fi
    if [ -n "$PROJECT_TAG" ]; then
      CI_MSG+=$'\n'"$(telegram_html_escape "$PROJECT_TAG")"
    fi
    if [ -n "${CI_COMMIT_TITLE:-}" ]; then
      CI_MSG+=$'\n'"📋 $(telegram_html_link "${WF_RUN_URL:-}" "${CI_COMMIT_TITLE}")"
    fi

    if [ -d "artifacts" ]; then
      mapfile -d '' ci_apks < <(
        find artifacts -type f \( -name '*arm64-v8a*.apk' -o -name '*arm64-v8a*.zip' \) -print0 | sort -z
      )
      if [ "${#ci_apks[@]}" -eq 0 ]; then
        echo "No arm64-v8a APK or ZIP artifacts found; skip text-only CI notify."
      else
        # One album message: APK file names + CI caption on first/last item
        send_documents_group "${TG_CI_THREAD_ID:-}" "$CI_MSG" "${ci_apks[@]}"
        telegram_pin_latest "${TG_CI_THREAD_ID:-}" ci
      fi
    else
      echo "No downloaded artifacts directory found; skip text-only CI notify."
    fi
    exit 0
  else
    exit 0
  fi
fi

if [ -z "${RELEASE_TAG:-}" ]; then
  if [ -n "${GITHUB_REF_NAME:-}" ] && [ "${EVENT_NAME:-}" = "release" ]; then
    RELEASE_TAG="${GITHUB_REF_NAME}"
  else
    RELEASE_TAG="manual"
  fi
fi

if [ "${EVENT_NAME:-}" = "release" ] && [[ "${RELEASE_TAG}" == v* ]]; then
  echo "Full release notification (tag ${RELEASE_TAG}) is handled by Release workflow_run; skipping release event to avoid duplicates."
  exit 0
fi

RELEASE_NOTES_FILE="release-notes.md"
release_name="$RELEASE_TAG"
if [[ "$release_name" != v* ]]; then
  release_name="v$release_name"
fi
if awk -v version="$release_name" '
  $0 == "---" && found { exit }
  found { print; next }
  index($0, "## [" version "]") == 1 { found = 1; print; next }
  END { if (!found) exit 1 }
' "$RELEASE_NOTES_SOURCE" > "$RELEASE_NOTES_FILE"; then
  RELEASE_NOTES_CONTENT="$(cat "$RELEASE_NOTES_FILE")"
else
  RELEASE_NOTES_CONTENT="Release notes not found in $RELEASE_NOTES_SOURCE for $release_name"
fi
RELEASE_NOTES_HTML="$(printf '%s' "$RELEASE_NOTES_CONTENT" | telegram_markdown_to_html)"

RELEASE_PAGE_URL="${RELEASE_PAGE_URL:-https://github.com/${GITHUB_REPOSITORY:-}/releases/tag/${RELEASE_TAG}}"
CAPTION="📦 $(telegram_html_escape "$PROJECT_NAME")：$(telegram_html_link "$RELEASE_PAGE_URL" "$RELEASE_TAG")"
if [ -n "$PROJECT_TAG" ]; then
  CAPTION+=$'\n'"$(telegram_html_escape "$PROJECT_TAG")"
fi
if [ -n "$RELEASE_NOTES_HTML" ]; then
  CAPTION+=$'\n\n'"$RELEASE_NOTES_HTML"
fi

if [ "${ASSETS_JSON:-null}" != "null" ]; then
  mkdir -p downloads
  release_assets=()
  while read -r asset; do
    name=$(echo "$asset" | jq -r '.name')
    url=$(echo "$asset" | jq -r '.browser_download_url // .url')
    if [[ "$name" == *arm64-v8a*.apk || "$name" == *arm64-v8a*.zip ]]; then
      echo "Downloading $name..."
      curl --fail-with-body -L -sS -o "downloads/$name" "$url"
      release_assets+=("downloads/$name")
    fi
  done < <(echo "$ASSETS_JSON" | jq -c '.[]')
  if [ "${#release_assets[@]}" -gt 0 ]; then
    # One album message: release notes as group caption
    send_documents_group "${TG_THREAD_ID:-}" "$CAPTION" "${release_assets[@]}"
  else
    send_message "${TG_THREAD_ID:-}" "$CAPTION"
  fi
else
  send_message "${TG_THREAD_ID:-}" "$CAPTION"
fi
telegram_pin_latest "${TG_THREAD_ID:-}" release
