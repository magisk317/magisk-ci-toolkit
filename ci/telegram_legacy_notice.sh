#!/usr/bin/env bash
# Relay a pointer for a delivered .magisk_telegram_ci drop into a legacy room.
#
# Enabled by the consumer through CI variables (project level typically):
#   MAGISK_TELEGRAM_LEGACY_NOTICE_CHAT    target chat id (setting it enables the notice)
#   MAGISK_TELEGRAM_LEGACY_NOTICE_THREAD  optional forum topic id in that chat
#   MAGISK_TELEGRAM_LEGACY_NOTICE_TZ      timestamp zone (default Asia/Shanghai)
#
# Reads .telegram_ci_state (ids + chat written by the ci template after a
# successful delivery) and posts into the legacy room:
#   #CI 最新ci: https://t.me/c/<internal>/<first_id>
#   <full timestamp>
set -euo pipefail

state="${CI_PROJECT_DIR:-.}/.telegram_ci_state"
[ -f "$state" ] || exit 0
# shellcheck disable=SC1090
. "$state"
[ -n "${ids:-}" ] && [ -n "${chat:-}" ] || exit 0

notice_chat="${MAGISK_TELEGRAM_LEGACY_NOTICE_CHAT:-}"
[ -n "$notice_chat" ] || { echo "MAGISK_TELEGRAM_LEGACY_NOTICE_CHAT not set; legacy notice skipped." >&2; exit 0; }

TG_API_BASE="${TG_API_BASE:-https://api.telegram.org}"
TG_API_BASE="${TG_API_BASE%/}"
token="${TG_BOT_TOKEN:?TG_BOT_TOKEN is required}"

first_id="${ids%%,*}"
case "$chat" in
  -100*) internal="${chat#-100}" ;;
  *) internal="${chat#-}" ;;
esac
link="https://t.me/c/${internal}/${first_id}"
stamp="$(TZ="${MAGISK_TELEGRAM_LEGACY_NOTICE_TZ:-Asia/Shanghai}" date '+%Y-%m-%d %H:%M:%S %Z')"

text="#CI 最新ci: ${link}
${stamp}"

thread_args=()
if [ -n "${MAGISK_TELEGRAM_LEGACY_NOTICE_THREAD:-}" ]; then
  thread_args=(-d "message_thread_id=${MAGISK_TELEGRAM_LEGACY_NOTICE_THREAD}")
fi

resp="$(curl -sS -X POST "${TG_API_BASE}/bot${token}/sendMessage" \
  -d "chat_id=${notice_chat}" \
  "${thread_args[@]}" \
  --data-urlencode "text=${text}")" || exit 1
printf '%s\n' "$resp"
printf '%s' "$resp" | grep -q '"ok":true' || {
  echo "legacy-topic notice failed: $resp" >&2
  exit 1
}
echo "legacy-topic notice sent: $link"
