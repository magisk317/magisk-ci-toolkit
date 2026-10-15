#!/usr/bin/env bash
# Shared transient-failure retry ladder for the controller's GitLab API calls.
#
# Sourced by auto_merge_upstream_mr.sh, auto_merge_self_renovate_mrs.sh,
# cancel_older_mr_pipelines.sh and cancel_older_renovate_pipelines.sh so one
# implementation serves every read and state-changing call.
#
# 2026-09-29, MiPush pipeline 2892824485: a single `curl: (35) Recv failure:
# Connection reset by peer` on the merge-request read killed the controller
# before it ever merged, and the serial loop then burned its full 120-poll
# window while the merge request sat healthy and green. The cancel phase's
# reads carried the same single-shot exposure — a transient failure there only
# downgraded cross-family cancellation to a warning, silently leaving stale
# pipelines running.

readonly api_retry_attempts=6
readonly api_retry_delay=2

# Curl exit codes that justify another try: DNS failure (6), connection
# refused/reset (7), operation timeout (28), SSL/TLS handshake trouble (35,
# 60), empty reply from the server (52) and send/receive failures (55, 56).
# HTTP-layer failures (curl 22) are classified by status code instead.
curl_exit_is_transient() {
  case "$1" in
    6 | 7 | 28 | 35 | 52 | 55 | 56 | 60) return 0 ;;
    *) return 1 ;;
  esac
}

http_status_is_retryable() {
  case "$1" in
    408 | 429 | 5??) return 0 ;;
    *) return 1 ;;
  esac
}

# _api_call_with_retry <curl_fn> <output_file> [curl args...] <url>
#
# Run one API call through the retry ladder and print the final HTTP status
# code to stdout. Transient failures (curl exit 6/7/28/35/52/55/56/60 or HTTP
# 408/429/5xx) are retried with exponential backoff (api_retry_delay doubling,
# api_retry_attempts attempts); everything else — 404, 401/403, malformed
# requests — fails immediately, because retrying those only delays a
# deterministic error.
#
# Returns 0 when curl itself succeeded (with `--fail` that means any 2xx) and
# 1 once retries are exhausted or the failure is not retryable; in both cases
# the final HTTP status (or 000 when the status is unknown) is on stdout, so
# state-changing callers can branch on it.
#
# Callers must invoke this (through api_get_with_retry / api_write_with_retry)
# from a condition context — `if ! ...; then fail ...; fi` — because a failing
# command substitution assignment would otherwise trip `set -e` before the
# ladder can inspect the exit code.
_api_call_with_retry() {
  local curl_fn="$1"
  local output_file="$2"
  shift 2
  local url="${*: -1}"
  local extra_args=("${@:1:$(($# - 1))}")

  local attempt=1
  local http_code
  local curl_rc
  local retryable
  local delay="$api_retry_delay"
  local attempts_note

  while :; do
    http_code="$("$curl_fn" --fail --silent --show-error \
      --output "$output_file" \
      --write-out '%{http_code}' \
      "${extra_args[@]}" \
      "$url")"
    curl_rc=$?

    if ((curl_rc == 0)); then
      printf '%s\n' "$http_code"
      return 0
    fi

    retryable=0
    if ((curl_rc == 22)) && http_status_is_retryable "$http_code"; then
      retryable=1
    elif ((curl_rc != 22)) && curl_exit_is_transient "$curl_rc"; then
      retryable=1
    fi

    if ((retryable == 0)) || ((attempt >= api_retry_attempts)); then
      # Note: keying the suffix on `attempt > 1` rather than a `:+` expansion
      # of a flag — `retryable=0` is non-null, so `${retryable:+...}` would
      # misreport a first-attempt 404 as "after 1 attempts".
      attempts_note=""
      if ((attempt > 1)); then
        attempts_note=" after ${attempt} attempts"
      fi
      echo "Error: API call to ${url} failed (curl exit ${curl_rc}, HTTP ${http_code:-none}${attempts_note})" >&2
      printf '%s\n' "${http_code:-000}"
      return 1
    fi

    echo "Transient failure calling ${url} (curl exit ${curl_rc}, HTTP ${http_code:-none}); retrying in ${delay}s (${attempt}/${api_retry_attempts})." >&2
    sleep "$delay"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
}

# api_get_with_retry <curl_fn> <output_file> [curl args...] <url>
#
# Read-only convenience wrapper: same ladder, HTTP status discarded — GET
# callers treat any failure as fatal. `--fail` is added inside the ladder, so
# HTTP errors surface as curl exit 22 and are classified by status code.
api_get_with_retry() {
  _api_call_with_retry "$@" >/dev/null
}

# api_write_with_retry <curl_fn> <output_file> [curl args...] <url>
#
# State-changing convenience wrapper: the final HTTP status stays on stdout so
# the caller can branch on 200/201/204 versus anything else.
api_write_with_retry() {
  _api_call_with_retry "$@"
}
