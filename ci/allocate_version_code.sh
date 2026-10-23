#!/usr/bin/env bash
# Allocate one versionCode from the shared version axis.
#
# Every project draws its versionCode from the same Cloudflare Worker so CI
# artifacts, Play releases and GitHub builds sit on one monotonic axis. The
# pipeline iid used to play that role and cannot any more: Play's own scale
# (resolve_play_release.sh) runs ahead of it, and Google Play compares
# versionCode, not versionName -- which is how a 1.1.1 CI build came to be
# offered the 1.1.0 release as an "update".
#
# Retrying here is free of side effects: the worker keys allocations on
# (project, scope), so the same scope returns the same code forever. That is
# what makes a retry loop safe -- a retry never burns a number, unlike a Play
# upload, which burns the code permanently.
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }

ALLOCATOR_URL="${MAGISK_VERSION_ALLOCATOR_URL:-https://version-allocator.android16.workers.dev}"
ALLOCATOR_TOKEN="${MAGISK_VERSION_ALLOCATOR_TOKEN:-}"
ATTEMPTS="${MAGISK_VERSION_ALLOCATOR_ATTEMPTS:-4}"
SLEEP_SECONDS="${MAGISK_VERSION_ALLOCATOR_SLEEP_SECONDS:-3}"

project=""
scope=""
while (($#)); do
  case "$1" in
    --project) project="${2:-}"; shift 2 ;;
    --scope) scope="${2:-}"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -n "$project" ] || fail "--project is required"
[ -n "$scope" ] || fail "--scope is required"
[ -n "$ALLOCATOR_TOKEN" ] || fail "MAGISK_VERSION_ALLOCATOR_TOKEN is not set"
[[ "$ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || fail "MAGISK_VERSION_ALLOCATOR_ATTEMPTS must be a positive integer"
[[ "$SLEEP_SECONDS" =~ ^[0-9]+$ ]] || fail "MAGISK_VERSION_ALLOCATOR_SLEEP_SECONDS must be a non-negative integer"
command -v curl >/dev/null 2>&1 || fail "curl is required"
# No jq. This client also runs inside the Android build image, which ships curl
# but not jq, and a build that cannot read the answer it just received has to
# fail closed rather than depend on a tool the image does not carry. The
# response body is produced by our own allocator Worker, so its shape is known
# well enough to read with a bash regex.

# A scope has to identify one build attempt and nothing else: the same scope
# must map to the same code across retries, and two different builds must never
# collide. "gitlab:<project id>:<pipeline iid>" satisfies both.
[[ "$scope" =~ ^[A-Za-z0-9._:-]{1,160}$ ]] || fail "scope must match [A-Za-z0-9._:-]{1,160}"

code=""
attempt=1
while :; do
  # curl's own --retry covers transport-level failures; the loop covers a 5xx,
  # an unparsable body or a well-formed error object, and stops at the first
  # response that actually carries a code.
  body="$(curl -sS --max-time 20 --retry 3 --retry-delay 1 \
    -X POST "$ALLOCATOR_URL/allocate" \
    -H "authorization: Bearer $ALLOCATOR_TOKEN" \
    -H 'content-type: application/json' \
    -d "{\"project\":\"$project\",\"scope\":\"$scope\"}" 2>/dev/null || true)"
  # "ok" must be exactly true before a code is trusted: an error body that
  # happens to mention a number must never be read as an allocation.
  ok_re='"ok"[[:space:]]*:[[:space:]]*true'
  code_re='"code"[[:space:]]*:[[:space:]]*([0-9]+)'
  candidate=""
  if [[ "$body" =~ $ok_re ]] && [[ "$body" =~ $code_re ]]; then
    candidate="${BASH_REMATCH[1]}"
  fi
  if [[ "$candidate" =~ ^[1-9][0-9]*$ ]]; then
    code="$candidate"
    break
  fi
  if ((attempt >= ATTEMPTS)); then
    fail "version allocator returned no usable code after $ATTEMPTS attempts (project=$project scope=$scope); last body: ${body:-<empty>}"
  fi
  echo "version-allocator: attempt $attempt/$ATTEMPTS unusable (${body:-<no response>}), retrying in ${SLEEP_SECONDS}s" >&2
  attempt=$((attempt + 1))
  sleep "$SLEEP_SECONDS"
done

printf '%s\n' "$code"
