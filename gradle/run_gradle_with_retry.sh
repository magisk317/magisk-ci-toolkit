#!/usr/bin/env bash
set -euo pipefail

GRADLEW_BIN="${GRADLEW_BIN:-./gradlew}"
GRADLE_RETRY_MAX_ATTEMPTS="${GRADLE_RETRY_MAX_ATTEMPTS:-3}"
GRADLE_RETRY_SLEEP_SECONDS="${GRADLE_RETRY_SLEEP_SECONDS:-5}"

if ! [[ "$GRADLE_RETRY_MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: GRADLE_RETRY_MAX_ATTEMPTS must be a positive integer." >&2
  exit 2
fi

if ! [[ "$GRADLE_RETRY_SLEEP_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: GRADLE_RETRY_SLEEP_SECONDS must be a non-negative integer." >&2
  exit 2
fi

if [ "$#" -eq 0 ]; then
  echo "ERROR: at least one Gradle argument is required." >&2
  exit 2
fi

if [[ -n "${MAGISK_ANDROID_AAPT2_OVERRIDE:-}" ]]; then
  set -- "$@" "-Pandroid.aapt2FromMavenOverride=${MAGISK_ANDROID_AAPT2_OVERRIDE}"
fi

# Machine-wide Gradle build slots. Enabled only when the runner exports
# MAGISK_GRADLE_LOCK_DIR (a directory on the gradle-cache bind mount shared by
# every job container on the same host), which makes the semaphore global per
# machine regardless of project.
acquire_gradle_slot() {
  local slots="${MAGISK_GRADLE_BUILD_SLOTS:-2}"
  local wait_seconds="${MAGISK_GRADLE_LOCK_WAIT_SECONDS:-5400}"
  local deadline=$(( $(date +%s) + wait_seconds ))
  local slot_i
  local lock_dir="$MAGISK_GRADLE_LOCK_DIR"

  # The shared lock dir may be root-owned; if we can't even create our own
  # files there, fall back to a project-local dir (machine-wide serialization
  # is lost, but at least the job doesn't die).
  mkdir -p "$lock_dir" 2>/dev/null || true
  local test_file="$lock_dir/.write-test-$$"
  if ! ( : >"$test_file" ) 2>/dev/null; then
    lock_dir="$CI_PROJECT_DIR/.locks"
    mkdir -p "$lock_dir" 2>/dev/null || true
  fi
  rm -f "$test_file" 2>/dev/null || true

  while true; do
    for (( slot_i = 0; slot_i < slots; slot_i++ )); do
      local lock_path="$lock_dir/build-slot-${slot_i}.lock"
      # Guard against stale root-owned lock files: if it exists but we
      # can't open it for writing, delete it so the next create succeeds.
      if [[ -f "$lock_path" && ! -w "$lock_path" ]]; then
        rm -f "$lock_path" 2>/dev/null || true
      fi
      # exec under set +e so a redirect failure doesn't exit the script;
      # bash treats `exec N>>file` as fatal even inside `if` under set -e.
      set +e
      exec 9>>"$lock_path" 2>/dev/null
      local exec_rc=$?
      set -e
      if (( exec_rc == 0 )) && flock -n 9; then
        echo "Acquired Gradle build slot ${slot_i}/${slots}." >&2
        return 0
      fi
      exec 9>&- 2>/dev/null || true
    done
    if (( $(date +%s) >= deadline )); then
      echo "ERROR: no free Gradle build slot (slots=${slots}) after ${wait_seconds}s." >&2
      return 1
    fi
    sleep 30
  done
}

if [[ -n "${MAGISK_GRADLE_LOCK_DIR:-}" ]]; then
  acquire_gradle_slot || exit 3
  trap 'exec 9>&- 2>/dev/null || true' EXIT
fi

is_retryable_gradle_failure() {
  local log_file="$1"

  grep -Eiq \
    'Remote host terminated the handshake|The server may not support the client.s requested TLS protocol versions|Read timed out|Link timed out|AAPT2[^[:space:]]*[[:space:]].*timed out|Connection reset|Connection refused|connect timed out|Temporary failure in name resolution|Name or service not known|No route to host|Network is unreachable|unexpected end of file from server|502 Bad Gateway|503 Service Unavailable|504 Gateway Timeout|status code 5[0-9]{2}|timeout waiting for connection from the connection pool|Gradle build daemon disappeared unexpectedly' \
    "$log_file"
}

current_gradle_pid=""
terminate_gradle() {
  local signal="${1:-TERM}"
  if [[ -n "$current_gradle_pid" ]] && kill -0 "$current_gradle_pid" 2>/dev/null; then
    kill -"$signal" -- "-$current_gradle_pid" 2>/dev/null || kill -"$signal" "$current_gradle_pid" 2>/dev/null || true
  fi
}

trap 'terminate_gradle TERM; exit 143' TERM INT HUP

attempt=1
while (( attempt <= GRADLE_RETRY_MAX_ATTEMPTS )); do
  log_file="$(mktemp)"

  echo "Running Gradle attempt ${attempt}/${GRADLE_RETRY_MAX_ATTEMPTS}: ${GRADLEW_BIN} $*"

  set +e
  setsid "$GRADLEW_BIN" "$@" >"$log_file" 2>&1 &
  current_gradle_pid="$!"
  # Stream log in background so CI shows real-time progress.
  tail -f "$log_file" &
  tail_pid=$!
  wait "$current_gradle_pid"
  status=$?
  kill "$tail_pid" 2>/dev/null || true
  wait "$tail_pid" 2>/dev/null || true
  current_gradle_pid=""
  set -e
  # tail -f may have missed the last lines; print the full log to be safe.
  cat "$log_file"

  if (( status == 0 )); then
    rm -f "$log_file"
    exit 0
  fi

  if (( attempt == GRADLE_RETRY_MAX_ATTEMPTS )); then
    echo "Gradle failed after ${attempt} attempts." >&2
    rm -f "$log_file"
    exit "$status"
  fi

  if ! is_retryable_gradle_failure "$log_file"; then
    echo "Gradle failed with a non-retryable error on attempt ${attempt}; not retrying." >&2
    rm -f "$log_file"
    exit "$status"
  fi

  echo "Detected a transient Gradle dependency/network failure. Retrying in ${GRADLE_RETRY_SLEEP_SECONDS}s..." >&2
  rm -f "$log_file"
  sleep "$GRADLE_RETRY_SLEEP_SECONDS"
  attempt=$((attempt + 1))
done
