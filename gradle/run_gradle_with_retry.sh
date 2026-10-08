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

# Parse a proxy URL into PROXY_SCHEME / PROXY_HOST / PROXY_PORT. Accepts
# scheme://[user:password@]host[:port] (any path/query suffix is ignored) as
# well as a bare host[:port]. Returns 1 when no usable host can be extracted.
parse_proxy_url() {
  local url="$1"
  local scheme="" rest="" hostport="" port=""

  PROXY_SCHEME=""
  PROXY_HOST=""
  PROXY_PORT=""

  if [[ "$url" == *"://"* ]]; then
    scheme="${url%%://*}"
    rest="${url#*://}"
  else
    rest="$url"
  fi
  # Strip userinfo (user:password@); greedy match keeps passwords containing @.
  rest="${rest##*@}"
  hostport="${rest%%[/?#]*}"
  [[ -z "$hostport" ]] && return 1

  if [[ "$hostport" == \[*\]* ]]; then
    # Bracketed IPv6 literal: [::1]:8080
    PROXY_HOST="${hostport%%\]*}]"
    port="${hostport##*\]}"
    port="${port#:}"
  elif [[ "$hostport" == *:* ]]; then
    PROXY_HOST="${hostport%:*}"
    port="${hostport##*:}"
  else
    PROXY_HOST="$hostport"
  fi

  PROXY_SCHEME="${scheme,,}"
  if [[ -n "$port" ]]; then
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    PROXY_PORT="$port"
  else
    case "$PROXY_SCHEME" in
      https) PROXY_PORT=443 ;;
      socks4|socks4a|socks5|socks5h) PROXY_PORT=1080 ;;
      *) PROXY_PORT=80 ;;
    esac
  fi
  [[ -n "$PROXY_HOST" ]] || return 1
  return 0
}

# Gradle resolves dependencies inside the daemon JVM. The daemon inherits
# neither GRADLE_OPTS nor the ambient *_proxy environment variables (the JVM
# ignores HTTP_PROXY-style names), so on proxied runners dependency downloads
# would bypass the proxy and stall until they time out. Derive JVM proxy
# system properties from the environment and pass them on the Gradle command
# line: command-line -D flags reach the daemon, unlike GRADLE_OPTS. Runners
# that export no proxy variables (GitHub-hosted runners) get no extra flags
# and keep their previous behaviour. Set MAGISK_GRADLE_PROXY_DISABLE=1 to opt
# out explicitly.
gradle_proxy_args=()

derive_gradle_proxy_args() {
  local https_url http_url
  https_url="${https_proxy:-${HTTPS_PROXY:-}}"
  http_url="${http_proxy:-${HTTP_PROXY:-}}"

  # Each side falls back to the other scheme's variable so a runner exporting
  # only one of them still routes both HTTP and HTTPS repository traffic.
  [[ -z "$https_url" && -n "$http_url" ]] && https_url="$http_url"
  [[ -z "$http_url" && -n "$https_url" ]] && http_url="$https_url"

  local url seen_url=""
  for url in "$https_url" "$http_url"; do
    # Both variables usually carry the same value; derive the flags once.
    [[ -z "$url" || "$url" == "$seen_url" ]] && continue
    seen_url="$url"
    if ! parse_proxy_url "$url"; then
      echo "WARN: ignoring malformed proxy URL: $url" >&2
      continue
    fi
    case "$PROXY_SCHEME" in
      socks4|socks4a|socks5|socks5h)
        gradle_proxy_args+=("-DsocksProxyHost=${PROXY_HOST}" "-DsocksProxyPort=${PROXY_PORT}")
        ;;
      *)
        gradle_proxy_args+=("-Dhttps.proxyHost=${PROXY_HOST}" "-Dhttps.proxyPort=${PROXY_PORT}")
        gradle_proxy_args+=("-Dhttp.proxyHost=${PROXY_HOST}" "-Dhttp.proxyPort=${PROXY_PORT}")
        ;;
    esac
  done

  # no_proxy is comma-separated; the JVM wants |-separated wildcard patterns.
  # Only meaningful together with an actual proxy, hence the guard.
  if (( ${#gradle_proxy_args[@]} > 0 )); then
    local no_proxy_list="${no_proxy:-${NO_PROXY:-}}"
    if [[ -n "$no_proxy_list" ]]; then
      local non_proxy_hosts="" entry
      local IFS=','
      for entry in $no_proxy_list; do
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [[ -z "$entry" ]] && continue
        # A leading dot is an env-var suffix convention; the JVM wants a glob.
        [[ "$entry" == .* ]] && entry="*${entry}"
        non_proxy_hosts+="${non_proxy_hosts:+|}${entry}"
      done
      if [[ -n "$non_proxy_hosts" ]]; then
        gradle_proxy_args+=("-Dhttp.nonProxyHosts=${non_proxy_hosts}")
      fi
    fi
  fi
}

if [[ "${MAGISK_GRADLE_PROXY_DISABLE:-}" != "1" ]]; then
  derive_gradle_proxy_args
fi
if (( ${#gradle_proxy_args[@]} > 0 )); then
  # Runner/proxy topology (internal IPs, no_proxy lists) must not leak into
  # public CI logs. Values are shown only when explicitly debugging.
  if [[ "${MAGISK_CI_DEBUG:-}" == "1" ]]; then
    echo "Derived Gradle JVM proxy flags: ${gradle_proxy_args[*]}" >&2
  else
    echo "Derived Gradle JVM proxy flags: ${#gradle_proxy_args[@]} flag(s) applied (values hidden; set MAGISK_CI_DEBUG=1 to show)" >&2
  fi
  set -- "${gradle_proxy_args[@]}" "$@"
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

  # Redact injected proxy -D values (internal proxy host/port and the
  # nonProxyHosts topology list) from the echoed command; task list stays.
  display_cmd="$(printf '%s ' "${GRADLEW_BIN}" "$@" | sed -E 's/(-D(https?|socks)[A-Za-z.]*(proxyHost|proxyPort|nonProxyHosts)=)[^ ]+/\1<hidden>/g')"
  echo "Running Gradle attempt ${attempt}/${GRADLE_RETRY_MAX_ATTEMPTS}: ${display_cmd% }"

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
