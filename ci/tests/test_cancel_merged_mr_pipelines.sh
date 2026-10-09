#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
controller_script="$(cd "$script_dir/.." && pwd)/cancel_merged_mr_pipelines.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

mock_bin="$tmp_root/bin"
mkdir -p "$mock_bin"

cat >"$mock_bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail

output_file=""
method="GET"
url=""
page=1
per_page=100
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
    --data-urlencode)
      case "$2" in
        page=*) page="${2#page=}" ;;
        per_page=*) per_page="${2#per_page=}" ;;
      esac
      shift 2
      ;;
    --header | --data)
      shift 2
      ;;
    --fail | --silent | --show-error | --location | --get)
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

# maybe_fail_call <count-file> <failures-spec>: emulates curl for a call whose
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

if [[ "$url" == */api/graphql ]]; then
  echo "unexpected GraphQL request" >&2
  exit 64
fi

if [[ "$method" == "POST" && "$url" =~ /projects/[0-9]+/pipelines/([0-9]+)/cancel$ ]]; then
  pipeline_id="${BASH_REMATCH[1]}"
  printf '%s\n' "$pipeline_id" >>"$MOCK_CANCEL_ATTEMPT_LOG"
  if [[ ",${MOCK_FAIL_CANCEL_IDS:-}," == *",${pipeline_id},"* ]]; then
    echo "mock cancel failure for ${pipeline_id}" >&2
    exit 22
  fi

  state_tmp="${MOCK_STATE_FILE}.tmp"
  jq --argjson id "$pipeline_id" '. + [$id] | unique' "$MOCK_STATE_FILE" >"$state_tmp"
  mv "$state_tmp" "$MOCK_STATE_FILE"
  jq -n --argjson id "$pipeline_id" '{id: $id, status: "canceled"}' >"$output_file"
  exit 0
fi

if [[ "$method" == "GET" && "$url" =~ /projects/[0-9]+/merge_requests/([0-9]+)/pipelines$ ]]; then
  maybe_fail_call "$MOCK_MR_PIPELINES_COUNT_FILE" "${MOCK_MR_PIPELINES_GET_FAILURES:-ok}"
  mr_iid="${BASH_REMATCH[1]}"
  start=$(((page - 1) * per_page))
  stop=$((start + per_page))
  jq --arg iid "$mr_iid" --argjson start "$start" --argjson stop "$stop" \
    --slurpfile canceled "$MOCK_STATE_FILE" \
    '(.[$iid] // []) | .[$start:$stop]
     | map(. as $pipeline
         | if (($canceled[0] | index($pipeline.id)) != null)
           then .status = "canceled"
           else .
           end)' \
    "$MOCK_MR_PIPELINES_FILE" >"$output_file"
  exit 0
fi

if [[ "$method" == "GET" && "$url" =~ /projects/[0-9]+/merge_requests$ ]]; then
  maybe_fail_call "$MOCK_MERGE_REQUESTS_COUNT_FILE" "${MOCK_MERGE_REQUESTS_GET_FAILURES:-ok}"
  printf '%s\n' "$page" >>"$MOCK_PAGE_LOG"
  start=$(((page - 1) * per_page))
  stop=$((start + per_page))
  jq --argjson start "$start" --argjson stop "$stop" '.[$start:$stop]' "$MOCK_MERGE_REQUESTS_FILE" >"$output_file"
  exit 0
fi

if [[ "$method" == "GET" && "$url" =~ /projects/[0-9]+/pipelines/([0-9]+)$ ]]; then
  maybe_fail_call "$MOCK_UPSTREAM_PIPELINE_COUNT_FILE" "${MOCK_UPSTREAM_PIPELINE_GET_FAILURES:-ok}"
  pipeline_id="${BASH_REMATCH[1]}"
  jq -n \
    --argjson id "$pipeline_id" \
    --argjson iid "$MAGISK_UPSTREAM_PIPELINE_IID" \
    --argjson project_id "$MAGISK_UPSTREAM_PROJECT_ID" \
    --arg ref "$MAGISK_UPSTREAM_REF" \
    --arg created_at "${MOCK_UPSTREAM_CREATED_AT:-2026-10-09T15:32:58.057Z}" \
    '{id: $id, iid: $iid, project_id: $project_id, source: "push", ref: $ref, created_at: $created_at, sha: "merge-sha"}' \
    >"$output_file"
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

start_case() {
  local name="$1"
  case_dir="$tmp_root/$name"
  mkdir -p "$case_dir"
  printf '[]\n' >"$case_dir/state.json"
  printf '{}\n' >"$case_dir/mr-pipelines.json"
  printf '[]\n' >"$case_dir/merge-requests.json"
  : >"$case_dir/pages.log"
  : >"$case_dir/cancel-attempts.log"
  : >"$case_dir/sleep.log"
  printf '0\n' >"$case_dir/upstream-pipeline-count"
  printf '0\n' >"$case_dir/merge-requests-count"
  printf '0\n' >"$case_dir/mr-pipelines-count"
}

# write_upstream <pipeline_id> <iid> <source> <ref> <project_id> <project_path>
write_upstream() {
  cat >"$case_dir/upstream.env" <<EOF
MAGISK_UPSTREAM_PROJECT_ID=$5
MAGISK_UPSTREAM_PROJECT_PATH=$6
MAGISK_UPSTREAM_PIPELINE_ID=$1
MAGISK_UPSTREAM_PIPELINE_IID=$2
MAGISK_UPSTREAM_PIPELINE_SOURCE=$3
MAGISK_UPSTREAM_REF=$4
EOF
}

write_merge_requests() {
  printf '%s\n' "$1" | jq . >"$case_dir/merge-requests.json"
}

write_mr_pipelines() {
  printf '%s\n' "$1" | jq . >"$case_dir/mr-pipelines.json"
}

run_controller() {
  local fail_ids="${1:-}"
  # shellcheck disable=SC1091
  source "$case_dir/upstream.env"
  set +e
  env \
    PATH="$mock_bin:$PATH" \
    MOCK_STATE_FILE="$case_dir/state.json" \
    MOCK_MERGE_REQUESTS_FILE="$case_dir/merge-requests.json" \
    MOCK_MR_PIPELINES_FILE="$case_dir/mr-pipelines.json" \
    MOCK_PAGE_LOG="$case_dir/pages.log" \
    MOCK_CANCEL_ATTEMPT_LOG="$case_dir/cancel-attempts.log" \
    MOCK_UPSTREAM_PIPELINE_COUNT_FILE="$case_dir/upstream-pipeline-count" \
    MOCK_MERGE_REQUESTS_COUNT_FILE="$case_dir/merge-requests-count" \
    MOCK_MR_PIPELINES_COUNT_FILE="$case_dir/mr-pipelines-count" \
    MOCK_UPSTREAM_PIPELINE_GET_FAILURES="${MOCK_UPSTREAM_PIPELINE_GET_FAILURES:-ok}" \
    MOCK_MERGE_REQUESTS_GET_FAILURES="${MOCK_MERGE_REQUESTS_GET_FAILURES:-ok}" \
    MOCK_MR_PIPELINES_GET_FAILURES="${MOCK_MR_PIPELINES_GET_FAILURES:-ok}" \
    MOCK_UPSTREAM_CREATED_AT="${MOCK_UPSTREAM_CREATED_AT:-2026-10-09T15:32:58.057Z}" \
    MOCK_SLEEP_LOG="$case_dir/sleep.log" \
    MOCK_FAIL_CANCEL_IDS="$fail_ids" \
    CI_API_V4_URL="https://gitlab.example/api/v4" \
    CI_SERVER_URL="https://gitlab.example" \
    CI_PROJECT_ID="83955109" \
    CI_PROJECT_PATH="magisk3171/shared/magisk-ci-toolkit" \
    CI_PIPELINE_ID="9000" \
    CI_PIPELINE_IID="42" \
    CI_PIPELINE_SOURCE="pipeline" \
    CI_COMMIT_REF_NAME="main" \
    CI_DEFAULT_BRANCH="main" \
    CI_COMMIT_REF_PROTECTED="true" \
    MAGISK_CI_PIPELINE_CONTROL_TOKEN="test-token" \
    MAGISK_UPSTREAM_PROJECT_ID="$MAGISK_UPSTREAM_PROJECT_ID" \
    MAGISK_UPSTREAM_PROJECT_PATH="$MAGISK_UPSTREAM_PROJECT_PATH" \
    MAGISK_UPSTREAM_PIPELINE_ID="$MAGISK_UPSTREAM_PIPELINE_ID" \
    MAGISK_UPSTREAM_PIPELINE_IID="$MAGISK_UPSTREAM_PIPELINE_IID" \
    MAGISK_UPSTREAM_PIPELINE_SOURCE="$MAGISK_UPSTREAM_PIPELINE_SOURCE" \
    MAGISK_UPSTREAM_REF="$MAGISK_UPSTREAM_REF" \
    MAGISK_CI_PIPELINE_PAGE_SIZE="2" \
    MAGISK_CI_PIPELINE_MAX_PAGES="20" \
    MAGISK_CI_PIPELINE_RECONCILE_PASSES="2" \
    MAGISK_CI_PIPELINE_RECONCILE_DELAY_SECONDS="0" \
    bash "$controller_script" >"$case_dir/output.log" 2>&1
  run_status=$?
  set -e
}

assert_success() {
  [[ "$run_status" -eq 0 ]] || {
    cat "$case_dir/output.log" >&2
    echo "Expected controller success, got ${run_status}" >&2
    exit 1
  }
}

assert_failure() {
  [[ "$run_status" -ne 0 ]] || {
    cat "$case_dir/output.log" >&2
    echo "Expected controller failure" >&2
    exit 1
  }
}

assert_state() {
  local expected="$1"
  jq -e --argjson expected "$expected" '. == $expected' "$case_dir/state.json" >/dev/null || {
    echo "Unexpected canceled pipeline state" >&2
    cat "$case_dir/state.json" >&2
    exit 1
  }
}

start_case "cancels-merged-mr-event-pipeline"
# The xinyi-relay MR195 scenario: merged 15:32:57, push pipeline created
# 15:32:58, MR pipeline's heavy job started 67 seconds after the merge.
write_upstream 600 60 push beta 84113188 magisk3171/xinyi-relay
write_merge_requests '[{"iid":195,"state":"merged","merged_at":"2026-10-09T15:32:57.498Z"}]'
write_mr_pipelines '{"195":[{"id":800,"source":"merge_request_event","ref":"refs/merge-requests/195/head","status":"running"},{"id":799,"source":"push","ref":"renovate/golang-1.x","status":"running"}]}'
run_controller
assert_success
assert_state '[800]'
grep -F "Canceling merge request !195 pipeline 800" "$case_dir/output.log" >/dev/null

start_case "keeps-finished-mr-pipelines"
write_upstream 610 61 push beta 84113188 magisk3171/xinyi-relay
write_merge_requests '[{"iid":196,"state":"merged","merged_at":"2026-10-09T15:33:04.905Z"}]'
write_mr_pipelines '{"196":[{"id":810,"source":"merge_request_event","ref":"refs/merge-requests/196/head","status":"success"}]}'
run_controller
assert_success
assert_state '[]'

start_case "ignores-push-pipelines-of-mr"
write_upstream 620 62 push beta 84113188 magisk3171/xinyi-relay
write_merge_requests '[{"iid":197,"state":"merged","merged_at":"2026-10-09T15:38:05.671Z"}]'
write_mr_pipelines '{"197":[{"id":820,"source":"push","ref":"renovate/golang-1.x","status":"running"}]}'
run_controller
assert_success
assert_state '[]'

start_case "ignores-mrs-merged-before-lookback"
write_upstream 630 63 push beta 84113188 magisk3171/xinyi-relay
write_merge_requests '[{"iid":194,"state":"merged","merged_at":"2026-10-09T12:00:00.000Z"}]'
write_mr_pipelines '{"194":[{"id":830,"source":"merge_request_event","ref":"refs/merge-requests/194/head","status":"running"}]}'
run_controller
assert_success
assert_state '[]'

start_case "batched-merges-all-canceled"
write_upstream 640 64 push beta 84113188 magisk3171/xinyi-relay
write_merge_requests '[
  {"iid":196,"state":"merged","merged_at":"2026-10-09T15:33:04.905Z"},
  {"iid":195,"state":"merged","merged_at":"2026-10-09T15:32:57.498Z"}
]'
write_mr_pipelines '{
  "195":[{"id":840,"source":"merge_request_event","status":"running"}],
  "196":[{"id":841,"source":"merge_request_event","status":"pending"},{"id":842,"source":"merge_request_event","status":"success"}]
}'
run_controller
assert_success
assert_state '[840,841]'

start_case "skew-window-catches-merge-after-pipeline-creation"
write_upstream 650 65 push beta 84113188 magisk3171/xinyi-relay
write_merge_requests '[{"iid":198,"state":"merged","merged_at":"2026-10-09T15:33:20.000Z"}]'
write_mr_pipelines '{"198":[{"id":850,"source":"merge_request_event","status":"running"}]}'
run_controller
assert_success
assert_state '[850]'

start_case "no-merged-mrs"
write_upstream 660 66 push beta 84113188 magisk3171/xinyi-relay
write_merge_requests '[]'
write_mr_pipelines '{}'
run_controller
assert_success
assert_state '[]'
grep -F "No active merge request pipelines remain" "$case_dir/output.log" >/dev/null

start_case "pagination-fetches-all-merged-mrs"
write_upstream 670 67 push beta 84113188 magisk3171/xinyi-relay
write_merge_requests '[
  {"iid":201,"state":"merged","merged_at":"2026-10-09T15:30:00.000Z"},
  {"iid":202,"state":"merged","merged_at":"2026-10-09T15:30:10.000Z"},
  {"iid":203,"state":"merged","merged_at":"2026-10-09T15:30:20.000Z"}
]'
write_mr_pipelines '{
  "201":[{"id":860,"source":"merge_request_event","status":"running"}],
  "202":[{"id":861,"source":"merge_request_event","status":"running"}],
  "203":[{"id":862,"source":"merge_request_event","status":"running"}]
}'
run_controller
assert_success
assert_state '[860,861,862]'
page_requests="$(wc -l <"$case_dir/pages.log")"
((page_requests >= 2)) || {
  echo "Expected pagination to request at least two pages" >&2
  exit 1
}

start_case "mr-list-retries-transient-http-503"
write_upstream 680 68 push beta 84113188 magisk3171/xinyi-relay
write_merge_requests '[{"iid":195,"state":"merged","merged_at":"2026-10-09T15:32:57.498Z"}]'
write_mr_pipelines '{"195":[{"id":870,"source":"merge_request_event","status":"running"}]}'
MOCK_MERGE_REQUESTS_GET_FAILURES="503,ok" run_controller
assert_success
assert_state '[870]'
grep -F "Transient failure calling" "$case_dir/output.log" >/dev/null
grep -F "(curl exit 22, HTTP 503)" "$case_dir/output.log" >/dev/null
grep -Fx '2' "$case_dir/sleep.log" >/dev/null

start_case "mr-list-persistent-transient-is-bounded"
write_upstream 690 69 push beta 84113188 magisk3171/xinyi-relay
write_merge_requests '[{"iid":195,"state":"merged","merged_at":"2026-10-09T15:32:57.498Z"}]'
write_mr_pipelines '{"195":[{"id":880,"source":"merge_request_event","status":"running"}]}'
MOCK_MERGE_REQUESTS_GET_FAILURES="curl:35" run_controller
assert_failure
assert_state '[]'
printf '2\n4\n8\n16\n32\n' | diff -u - "$case_dir/sleep.log"
grep -F "failed to list merged merge requests on page 1" "$case_dir/output.log" >/dev/null
grep -F "after 6 attempts" "$case_dir/output.log" >/dev/null

start_case "mr-pipelines-read-404-is-not-retried"
write_upstream 700 70 push beta 84113188 magisk3171/xinyi-relay
write_merge_requests '[{"iid":195,"state":"merged","merged_at":"2026-10-09T15:32:57.498Z"}]'
write_mr_pipelines '{"195":[{"id":890,"source":"merge_request_event","status":"running"}]}'
MOCK_MR_PIPELINES_GET_FAILURES="404" run_controller
assert_failure
assert_state '[]'
[[ ! -s "$case_dir/sleep.log" ]] || {
  echo "Expected no retries for HTTP 404" >&2
  exit 1
}
grep -F "failed to list pipelines for merge request 195 on page 1" "$case_dir/output.log" >/dev/null

start_case "upstream-pipeline-read-retries-transient-network-failure"
write_upstream 710 71 push beta 84113188 magisk3171/xinyi-relay
write_merge_requests '[{"iid":195,"state":"merged","merged_at":"2026-10-09T15:32:57.498Z"}]'
write_mr_pipelines '{"195":[{"id":900,"source":"merge_request_event","status":"running"}]}'
MOCK_UPSTREAM_PIPELINE_GET_FAILURES="curl:35,ok" run_controller
assert_success
assert_state '[900]'
grep -F "(curl exit 35, HTTP 000)" "$case_dir/output.log" >/dev/null
grep -Fx '2' "$case_dir/sleep.log" >/dev/null

start_case "cancel-failure-is-surfaced"
write_upstream 720 72 push beta 84113188 magisk3171/xinyi-relay
write_merge_requests '[{"iid":195,"state":"merged","merged_at":"2026-10-09T15:32:57.498Z"}]'
write_mr_pipelines '{"195":[{"id":910,"source":"merge_request_event","status":"running"}]}'
run_controller "910"
assert_failure
assert_state '[]'
grep -F "failed to cancel pipeline 910" "$case_dir/output.log" >/dev/null
grep -F "active merge request pipelines remain after reconciliation: 910" "$case_dir/output.log" >/dev/null

start_case "untrusted-upstream"
write_upstream 730 73 push beta 99999999 untrusted/example
write_merge_requests '[]'
write_mr_pipelines '{}'
run_controller
assert_failure
grep -F "upstream project is not in the controller allowlist" "$case_dir/output.log" >/dev/null

start_case "merge-request-upstream-rejected"
write_upstream 740 74 merge_request_event refs/merge-requests/74/head 84113188 magisk3171/xinyi-relay
write_merge_requests '[]'
write_mr_pipelines '{}'
run_controller
assert_failure
grep -F "upstream pipeline source must be push for post-merge cleanup" "$case_dir/output.log" >/dev/null

start_case "wrong-target-branch-rejected"
write_upstream 750 75 push main 84113188 magisk3171/xinyi-relay
write_merge_requests '[]'
write_mr_pipelines '{}'
run_controller
assert_failure
grep -F "is not the trusted target branch beta" "$case_dir/output.log" >/dev/null

start_case "non-target-branch-consumer-uses-its-own-branch"
# magisk-build-logic renovates its protected default branch instead of beta.
write_upstream 760 76 push main 83955125 magisk3171/shared/magisk-build-logic
write_merge_requests '[{"iid":12,"state":"merged","merged_at":"2026-10-09T15:32:57.498Z"}]'
write_mr_pipelines '{"12":[{"id":920,"source":"merge_request_event","status":"running"}]}'
run_controller
assert_success
assert_state '[920]'

echo "cancel_merged_mr_pipelines tests passed"
