#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
controller_script="$(cd "$script_dir/.." && pwd)/cancel_older_renovate_pipelines.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf -- "$tmp_root"' EXIT

mock_bin="$tmp_root/bin"
mkdir -p "$mock_bin"

# Keep the project added for the UI consumer covered by the same allowlist
# used by the production controller.
# shellcheck disable=SC1091
source "$(cd "$script_dir/.." && pwd)/trusted_projects.sh"
[[ "$(trusted_project_id "magisk3171/napgram-ecosystem/napgram-ui-dist")" == "84583731" ]] || exit 1
[[ "$(trusted_target_branch "magisk3171/napgram-ecosystem/napgram-ui-dist")" == "beta" ]] || exit 1
for trusted_path in \
  magisk3171/MiPushFramework \
  magisk3171/XposedSmsCode \
  magisk3171/xinyi-relay \
  magisk3171/napgram-ecosystem/NapGram \
  magisk3171/napgram-ecosystem/napgram-ui-dist \
  magisk3171/SerialBridge \
  magisk3171/MiPushZygisk \
  magisk3171/MiPushConfigurations \
  magisk3171/napgram-ecosystem/NapLink \
  magisk3171/android-host-tools-arm64; do
  [[ "$(trusted_target_branch "$trusted_path")" == "beta" ]] || exit 1
done

cat >"$mock_bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail

output_file=""
method="GET"
url=""
write_out=""
while (($# > 0)); do
  case "$1" in
    --output)
      output_file="$2"
      shift 2
      ;;
    --request)
      method="$2"
      shift 2
      ;;
    --write-out)
      write_out="$2"
      shift 2
      ;;
    --data-urlencode | --header)
      shift 2
      ;;
    --get | --fail | --silent | --show-error | --location)
      shift
      ;;
    http://* | https://*)
      url="$1"
      shift
      ;;
    *)
      echo "mock curl: unsupported argument $1" >&2
      exit 64
      ;;
  esac
done

[[ -n "$output_file" ]] || {
  echo "mock curl: --output is required" >&2
  exit 64
}

# maybe_fail_call <count-file> <failures-spec>: emulates curl for a GET whose
# per-attempt behaviour is scripted, then never returns. Each spec entry is
# `ok` (serve the real response), `curl:<exit>` (network-level failure: no
# body, curl prints 000 for %{http_code}) or an HTTP status (curl --fail
# exits 22 and prints the status). The last entry repeats once exceeded.
maybe_fail_call() {
  local count_file="$1"
  local failures="$2"
  local count index behavior
  local -a behaviors=()

  count="$(cat "$count_file")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$count_file"
  IFS=',' read -r -a behaviors <<<"$failures"
  index=$((count - 1))
  if ((index >= ${#behaviors[@]})); then
    index=$((${#behaviors[@]} - 1))
  fi
  behavior="${behaviors[$index]}"
  case "$behavior" in
    ok)
      return 0
      ;;
    curl:*)
      if [[ "$write_out" == "%{http_code}" ]]; then printf '000'; fi
      echo "curl: (${behavior#curl:}) simulated connection failure" >&2
      exit "${behavior#curl:}"
      ;;
    *)
      if [[ "$write_out" == "%{http_code}" ]]; then printf '%s' "$behavior"; fi
      exit 22
      ;;
  esac
}

if [[ "$method" == "GET" && "$url" == */pipelines/9000 ]]; then
  maybe_fail_call "$MOCK_UPSTREAM_PIPELINE_COUNT_FILE" "${MOCK_UPSTREAM_PIPELINE_GET_FAILURES:-ok}"
  jq -n '{id:9000,iid:90,project_id:83955143,source:"schedule",ref:"beta",created_at:"2026-01-01T00:00:10Z"}' >"$output_file"
  exit 0
fi

if [[ "$method" == "GET" && "$url" =~ /pipelines/([0-9]+)/jobs$ ]]; then
  maybe_fail_call "$MOCK_JOBS_LIST_COUNT_FILE" "${MOCK_JOBS_LIST_GET_FAILURES:-ok}"
  pipeline_id="${BASH_REMATCH[1]}"
  if [[ "$pipeline_id" == "8998" || "$pipeline_id" == "8999" || "$pipeline_id" == "9000" || "$pipeline_id" == "9001" ]]; then
    jq -n '[{name:"renovate:gitlab"}]' >"$output_file"
  else
    jq -n '[{name:"android:build"}]' >"$output_file"
  fi
  exit 0
fi

if [[ "$method" == "GET" && "$url" == */pipelines ]]; then
  maybe_fail_call "$MOCK_PIPELINES_LIST_COUNT_FILE" "${MOCK_PIPELINES_LIST_GET_FAILURES:-ok}"
  jq --slurpfile canceled "$MOCK_CANCELED_FILE" '
    map(. as $pipeline | if ($canceled[0] | index($pipeline.id)) != null then .status = "canceled" else . end)
  ' "$MOCK_PIPELINES_FILE" >"$output_file"
  exit 0
fi

if [[ "$method" == "POST" && "$url" =~ /pipelines/([0-9]+)/cancel$ ]]; then
  pipeline_id="${BASH_REMATCH[1]}"
  jq --argjson id "$pipeline_id" '. + [$id] | unique' "$MOCK_CANCELED_FILE" >"$MOCK_CANCELED_FILE.tmp"
  mv "$MOCK_CANCELED_FILE.tmp" "$MOCK_CANCELED_FILE"
  jq -n --argjson id "$pipeline_id" '{id:$id,status:"canceled"}' >"$output_file"
  exit 0
fi

echo "mock curl: unsupported request ${method} ${url}" >&2
exit 64
MOCK_CURL
chmod +x "$mock_bin/curl"

cat >"$mock_bin/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"$MOCK_SLEEP_LOG"
MOCK_SLEEP
chmod +x "$mock_bin/sleep"

case_dir=""
run_status=0

# start_case <name> <fixture> <upstream-failures> <list-failures> <jobs-failures>
#
# <fixture> selects the pipeline set (older / newer). The failure specs are
# per-attempt behaviours for the mock curl (see maybe_fail_call): `ok` keeps
# the happy path, `curl:<exit>` emulates a network-level failure and a bare
# HTTP status an HTTP-layer one (curl --fail exit 22); the last entry repeats
# once exceeded.
start_case() {
  local name="$1"
  local fixture="$2"
  local upstream_failures="${3:-ok}"
  local list_failures="${4:-ok}"
  local jobs_failures="${5:-ok}"
  case_dir="$tmp_root/$name"
  mkdir -p "$case_dir"
  printf '[]\n' >"$case_dir/canceled.json"
  printf '0\n' >"$case_dir/upstream-pipeline-count"
  printf '0\n' >"$case_dir/pipelines-list-count"
  printf '0\n' >"$case_dir/jobs-list-count"
  : >"$case_dir/sleep.log"
  case "$fixture" in
    older)
      jq -n '[
        {id:9000,source:"schedule",ref:"beta",status:"running",created_at:"2026-01-01T00:00:10Z"},
        {id:8999,source:"schedule",ref:"beta",status:"running",created_at:"2026-01-01T00:00:09Z"},
        {id:8998,source:"schedule",ref:"beta",status:"running",created_at:"2026-01-01T00:00:08Z"},
        {id:8996,source:"schedule",ref:"beta",status:"running",created_at:"2026-01-01T00:00:06Z"},
        {id:8997,source:"push",ref:"beta",status:"running",created_at:"2026-01-01T00:00:07Z"}
      ]' >"$case_dir/pipelines.json"
      ;;
    newer)
      jq -n '[
        {id:9001,source:"schedule",ref:"beta",status:"running",created_at:"2026-01-01T00:00:11Z"},
        {id:9000,source:"schedule",ref:"beta",status:"running",created_at:"2026-01-01T00:00:10Z"}
      ]' >"$case_dir/pipelines.json"
      ;;
  esac

  set +e
  env \
    PATH="$mock_bin:$PATH" \
    MOCK_PIPELINES_FILE="$case_dir/pipelines.json" \
    MOCK_CANCELED_FILE="$case_dir/canceled.json" \
    MOCK_UPSTREAM_PIPELINE_COUNT_FILE="$case_dir/upstream-pipeline-count" \
    MOCK_PIPELINES_LIST_COUNT_FILE="$case_dir/pipelines-list-count" \
    MOCK_JOBS_LIST_COUNT_FILE="$case_dir/jobs-list-count" \
    MOCK_UPSTREAM_PIPELINE_GET_FAILURES="$upstream_failures" \
    MOCK_PIPELINES_LIST_GET_FAILURES="$list_failures" \
    MOCK_JOBS_LIST_GET_FAILURES="$jobs_failures" \
    MOCK_SLEEP_LOG="$case_dir/sleep.log" \
    CI_API_V4_URL="https://gitlab.example/api/v4" \
    CI_PROJECT_ID="83955109" \
    CI_PROJECT_PATH="magisk3171/shared/magisk-ci-toolkit" \
    CI_PIPELINE_ID="9000" \
    CI_PIPELINE_IID="42" \
    CI_PIPELINE_SOURCE="pipeline" \
    CI_COMMIT_REF_NAME="main" \
    CI_DEFAULT_BRANCH="main" \
    CI_COMMIT_REF_PROTECTED="true" \
    MAGISK_CI_PIPELINE_CONTROL_TOKEN="test-token" \
    MAGISK_UPSTREAM_PROJECT_ID="83955143" \
    MAGISK_UPSTREAM_PROJECT_PATH="magisk3171/MiPushFramework" \
    MAGISK_UPSTREAM_PIPELINE_ID="9000" \
    MAGISK_UPSTREAM_PIPELINE_IID="90" \
    MAGISK_UPSTREAM_PIPELINE_SOURCE="schedule" \
    MAGISK_UPSTREAM_REF="beta" \
    MAGISK_CI_PIPELINE_PAGE_SIZE="100" \
    MAGISK_CI_PIPELINE_MAX_PAGES="2" \
    MAGISK_CI_PIPELINE_RECONCILE_PASSES="2" \
    MAGISK_CI_PIPELINE_RECONCILE_DELAY_SECONDS="0" \
    bash "$controller_script" >"$case_dir/output.log" 2>&1
  run_status=$?
  set -e
  printf '%s\n' "$run_status" >"$case_dir/status"
}

expect_success() {
  [[ "$(cat "$case_dir/status")" == "0" ]] || {
    cat "$case_dir/output.log" >&2
    echo "Expected controller success, got $(cat "$case_dir/status")" >&2
    exit 1
  }
}

expect_failure() {
  [[ "$(cat "$case_dir/status")" != "0" ]] || {
    cat "$case_dir/output.log" >&2
    echo "Expected controller failure" >&2
    exit 1
  }
}

expect_canceled() {
  jq -e --argjson expected "$1" '. == $expected' "$case_dir/canceled.json" >/dev/null || {
    cat "$case_dir/output.log" >&2
    cat "$case_dir/canceled.json" >&2
    exit 1
  }
}

start_case older older ok ok ok
[[ "$(cat "$tmp_root/older/status")" == "0" ]] || {
  cat "$tmp_root/older/output.log" >&2
  exit 1
}
jq -e '. == [8998,8999]' "$tmp_root/older/canceled.json" >/dev/null || {
  cat "$tmp_root/older/output.log" >&2
  cat "$tmp_root/older/canceled.json" >&2
  exit 1
}
grep -F "older Renovate pipeline 8999" "$tmp_root/older/output.log" >/dev/null
if grep -F "android:build" "$tmp_root/older/output.log" >/dev/null; then
  echo "ordinary pipelines must not be inspected as Renovate pipelines" >&2
  exit 1
fi

start_case newer newer ok ok ok
[[ "$(cat "$tmp_root/newer/status")" == "0" ]] || {
  cat "$tmp_root/newer/output.log" >&2
  exit 1
}
jq -e '. == []' "$tmp_root/newer/canceled.json" >/dev/null
grep -F "newer Renovate pipeline 9001 wins" "$tmp_root/newer/output.log" >/dev/null

start_case "upstream-read-retries-transient-network-failure" older "curl:35,ok" ok ok
expect_success
expect_canceled '[8998,8999]'
grep -F "Transient failure calling" "$case_dir/output.log" >/dev/null
grep -F "(curl exit 35, HTTP 000)" "$case_dir/output.log" >/dev/null
grep -F "retrying in 2s (1/6)" "$case_dir/output.log" >/dev/null
grep -Fx '2' "$case_dir/sleep.log" >/dev/null

start_case "upstream-read-retries-transient-http-503" older 503,ok ok ok
expect_success
expect_canceled '[8998,8999]'
grep -F "(curl exit 22, HTTP 503)" "$case_dir/output.log" >/dev/null
grep -Fx '2' "$case_dir/sleep.log" >/dev/null

start_case "upstream-read-persistent-transient-is-bounded" older curl:35 ok ok
expect_failure
expect_canceled '[]'
printf '2\n4\n8\n16\n32\n' | diff -u - "$case_dir/sleep.log"
grep -F "failed to read upstream pipeline 9000" "$case_dir/output.log" >/dev/null
grep -F "after 6 attempts" "$case_dir/output.log" >/dev/null

start_case "pipelines-list-read-retries-transient-network-failure" older ok "curl:35,ok" ok
expect_success
expect_canceled '[8998,8999]'
grep -F "Transient failure calling" "$case_dir/output.log" >/dev/null
grep -F "(curl exit 35, HTTP 000)" "$case_dir/output.log" >/dev/null
grep -F "retrying in 2s (1/6)" "$case_dir/output.log" >/dev/null
grep -Fx '2' "$case_dir/sleep.log" >/dev/null

start_case "pipelines-list-read-retries-transient-http-503" older ok 503,ok ok
expect_success
expect_canceled '[8998,8999]'
grep -F "(curl exit 22, HTTP 503)" "$case_dir/output.log" >/dev/null
grep -Fx '2' "$case_dir/sleep.log" >/dev/null

start_case "pipelines-list-read-persistent-transient-is-bounded" older ok curl:35 ok
expect_failure
expect_canceled '[]'
printf '2\n4\n8\n16\n32\n' | diff -u - "$case_dir/sleep.log"
grep -F "failed to list pipelines on page 1" "$case_dir/output.log" >/dev/null
grep -F "after 6 attempts" "$case_dir/output.log" >/dev/null

start_case "jobs-list-read-retries-transient-network-failure" older ok ok "curl:35,ok"
expect_success
expect_canceled '[8998,8999]'
grep -F "Transient failure calling" "$case_dir/output.log" >/dev/null
grep -F "(curl exit 35, HTTP 000)" "$case_dir/output.log" >/dev/null
grep -F "retrying in 2s (1/6)" "$case_dir/output.log" >/dev/null
grep -Fx '2' "$case_dir/sleep.log" >/dev/null

start_case "jobs-list-read-retries-transient-http-503" older ok ok 503,ok
expect_success
expect_canceled '[8998,8999]'
grep -F "(curl exit 22, HTTP 503)" "$case_dir/output.log" >/dev/null
grep -Fx '2' "$case_dir/sleep.log" >/dev/null

start_case "jobs-list-read-persistent-transient-is-bounded" older ok ok curl:35
expect_failure
expect_canceled '[]'
printf '2\n4\n8\n16\n32\n' | diff -u - "$case_dir/sleep.log"
grep -F "failed to list jobs for Renovate pipeline 8999" "$case_dir/output.log" >/dev/null
grep -F "after 6 attempts" "$case_dir/output.log" >/dev/null

echo "Renovate pipeline cancellation tests passed"
