#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
merger_script="$(cd "$script_dir/.." && pwd)/auto_merge_self_renovate_mrs.sh"
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
write_out=""
state=""

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
    --data-urlencode)
      case "$2" in
        state=*) state="${2#state=}" ;;
      esac
      shift 2
      ;;
    --write-out)
      write_out="$2"
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

respond() {
  printf '%s' "$1" >"$output_file"
  if [[ "$write_out" == "%{http_code}" ]]; then printf '200'; fi
}

if [[ "$method" == "GET" && "$url" =~ /pipelines/([0-9]+)/jobs ]]; then
  pipeline_id="${BASH_REMATCH[1]}"
  if [[ "$pipeline_id" == "$MOCK_CURRENT_PIPELINE_ID" ]]; then
    call_count="$(cat "$MOCK_SIBLING_CALLS_FILE")"
    call_count=$((call_count + 1))
    printf '%s\n' "$call_count" >"$MOCK_SIBLING_CALLS_FILE"
    total_lines="$(wc -l <"$MOCK_SIBLING_STATUS_FILE")"
    if ((call_count >= total_lines)); then
      line="$total_lines"
    else
      line="$call_count"
    fi
    status="$(sed -n "${line}p" "$MOCK_SIBLING_STATUS_FILE")"
    respond "$(jq -nc --arg status "$status" '[{id: 1, name: "renovate:gitlab", status: $status}]')"
    exit 0
  fi
  if [[ -f "$MOCK_CANDIDATE_JOBS_DIR/${pipeline_id}.json" ]]; then
    respond "$(cat "$MOCK_CANDIDATE_JOBS_DIR/${pipeline_id}.json")"
  else
    respond '[]'
  fi
  exit 0
fi

if [[ "$method" == "GET" && "$url" =~ /merge_requests/([0-9]+)$ ]]; then
  iid="${BASH_REMATCH[1]}"
  if [[ -f "$MOCK_MR_DETAILS_DIR/${iid}.json" ]]; then
    respond "$(cat "$MOCK_MR_DETAILS_DIR/${iid}.json")"
  else
    respond "$(cat "$MOCK_MR_FILE")"
  fi
  exit 0
fi

if [[ "$method" == "GET" && "$url" =~ /merge_requests ]]; then
  call_count="$(cat "$MOCK_MR_LIST_CALLS_FILE")"
  call_count=$((call_count + 1))
  printf '%s\n' "$call_count" >"$MOCK_MR_LIST_CALLS_FILE"
  total_lines="$(wc -l <"$MOCK_MR_LIST_SEQ_FILE")"
  if ((call_count >= total_lines)); then
    line="$total_lines"
  else
    line="$call_count"
  fi
  body="$(sed -n "${line}p" "$MOCK_MR_LIST_SEQ_FILE")"
  if [[ "$state" == "opened" ]]; then
    respond "$(printf '%s' "$body" | jq -c 'map(select(.state == "opened"))')"
  else
    respond "$body"
  fi
  exit 0
fi

if [[ "$method" == "GET" && "$url" =~ /pipelines ]]; then
  respond "$(cat "$MOCK_PIPELINES_FILE")"
  exit 0
fi

if [[ "$method" == "PUT" && "$url" =~ /merge_requests/([0-9]+)/merge$ ]]; then
  iid="${BASH_REMATCH[1]}"
  count="$(cat "$MOCK_MERGE_COUNT_FILE")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$MOCK_MERGE_COUNT_FILE"
  IFS=',' read -r -a statuses <<<"${MOCK_MERGE_STATUSES:-200}"
  index=$((count - 1))
  if ((index >= ${#statuses[@]})); then
    index=$((${#statuses[@]} - 1))
  fi
  status="${statuses[$index]}"
  if [[ "$status" == "200" ]]; then
    printf '%s' "$(jq -c '.state = "merged"' "$MOCK_MR_DETAILS_DIR/${iid}.json")" >"$output_file"
  else
    printf '%s' "$(jq -nc '{message: "merge is not ready"}')" >"$output_file"
  fi
  if [[ "$write_out" == "%{http_code}" ]]; then printf '%s' "$status"; fi
  exit 0
fi

if [[ "$method" == "POST" && "$url" =~ /pipelines/([0-9]+)/cancel$ ]]; then
  count="$(cat "$MOCK_CANCEL_COUNT_FILE")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$MOCK_CANCEL_COUNT_FILE"
  respond "$(jq -nc '{id: 5000, status: "canceled"}')"
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

readonly default_mr='{"iid":12,"source_branch":"renovate/renovate-44.x","target_branch":"main","source_project_id":83955109,"state":"opened","draft":false,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'

case_dir=""
run_status=0

start_case() {
  local name="$1"
  case_dir="$tmp_root/$name"
  mkdir -p "$case_dir/mr-details" "$case_dir/candidate-jobs"
  printf '0\n' >"$case_dir/merge-count"
  printf '0\n' >"$case_dir/cancel-count"
  printf '0\n' >"$case_dir/sibling-calls"
  printf '0\n' >"$case_dir/mr-list-calls"
  : >"$case_dir/sleep.log"
  printf '%s\n' running running success >"$case_dir/sibling-status"
  printf '%s\n' \
    "[${default_mr}]" \
    '[]' '[]' '[]' '[]' >"$case_dir/mr-list-seq"
  jq -n '{
    iid: 12, project_id: 83955109, target_project_id: 83955109, source_project_id: 83955109,
    state: "opened", draft: false, sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    has_conflicts: false, merge_when_pipeline_succeeds: false,
    source_branch: "renovate/renovate-44.x", target_branch: "main", title: "chore(deps): update renovate"
  }' >"$case_dir/mr-details/12.json"
  jq -n '[]' >"$case_dir/pipelines.json"
  jq -n '[{id: 1, name: "renovate:gitlab", status: "running"}]' >"$case_dir/candidate-jobs/5000.json"
}

run_self_merge() {
  set +e
  env \
    PATH="$mock_bin:$PATH" \
    MOCK_CURRENT_PIPELINE_ID="9000" \
    MOCK_SIBLING_CALLS_FILE="$case_dir/sibling-calls" \
    MOCK_SIBLING_STATUS_FILE="$case_dir/sibling-status" \
    MOCK_MR_LIST_CALLS_FILE="$case_dir/mr-list-calls" \
    MOCK_MR_LIST_SEQ_FILE="$case_dir/mr-list-seq" \
    MOCK_MR_DETAILS_DIR="$case_dir/mr-details" \
    MOCK_MR_FILE="$case_dir/mr-details/12.json" \
    MOCK_PIPELINES_FILE="$case_dir/pipelines.json" \
    MOCK_CANDIDATE_JOBS_DIR="$case_dir/candidate-jobs" \
    MOCK_MERGE_COUNT_FILE="$case_dir/merge-count" \
    MOCK_CANCEL_COUNT_FILE="$case_dir/cancel-count" \
    MOCK_SLEEP_LOG="$case_dir/sleep.log" \
    MOCK_MERGE_STATUSES="${MOCK_MERGE_STATUSES:-200}" \
    CI_API_V4_URL="https://gitlab.example/api/v4" \
    CI_PROJECT_ID="${SELF_MERGE_TEST_PROJECT_ID:-83955109}" \
    CI_PROJECT_PATH="magisk3171/shared/magisk-ci-toolkit" \
    CI_PIPELINE_ID="9000" \
    CI_PIPELINE_IID="42" \
    CI_PIPELINE_SOURCE="${SELF_MERGE_TEST_SOURCE:-schedule}" \
    CI_COMMIT_REF_NAME="${SELF_MERGE_TEST_REF:-main}" \
    CI_DEFAULT_BRANCH="main" \
    MAGISK_CI_MR_AUTOMERGE_TOKEN="merge-token" \
    MAGISK_CI_PIPELINE_CONTROL_TOKEN="${SELF_MERGE_TEST_CONTROL_TOKEN-control-token}" \
    RENOVATE_TOKEN="renovate-token" \
    MAGISK_SELF_MERGE_POLL_INTERVAL_SECONDS="0" \
    MAGISK_SELF_MERGE_DELAY_SECONDS="${SELF_MERGE_TEST_MERGE_DELAY:-0}" \
    bash "$merger_script" >"$case_dir/output.log" 2>&1
  run_status=$?
  set -e
}

assert_success() {
  [[ "$run_status" -eq 0 ]] || {
    cat "$case_dir/output.log" >&2
    echo "Expected self-merge success, got ${run_status}" >&2
    exit 1
  }
}

assert_failure() {
  [[ "$run_status" -ne 0 ]] || {
    cat "$case_dir/output.log" >&2
    echo "Expected self-merge failure" >&2
    exit 1
  }
}

assert_merge_count() {
  local expected="$1"
  [[ "$(cat "$case_dir/merge-count")" == "$expected" ]] || {
    echo "Expected ${expected} merge calls" >&2
    cat "$case_dir/merge-count" >&2
    exit 1
  }
}

assert_cancel_count() {
  local expected="$1"
  [[ "$(cat "$case_dir/cancel-count")" == "$expected" ]] || {
    echo "Expected ${expected} cancel calls" >&2
    cat "$case_dir/cancel-count" >&2
    exit 1
  }
}

assert_output_contains() {
  local expected="$1"
  grep -F "$expected" "$case_dir/output.log" >/dev/null || {
    echo "Expected output to contain: ${expected}" >&2
    cat "$case_dir/output.log" >&2
    exit 1
  }
}

start_case "rejects-non-renovate-pipeline-source"
SELF_MERGE_TEST_SOURCE="merge_request_event" run_self_merge
assert_failure
assert_output_contains "self Renovate must run from a schedule, web, or API pipeline"

start_case "rejects-non-default-branch"
SELF_MERGE_TEST_REF="beta" run_self_merge
assert_failure
assert_output_contains "self Renovate must run on the default branch"

start_case "rejects-foreign-project"
SELF_MERGE_TEST_PROJECT_ID="83955143" run_self_merge
assert_failure
assert_output_contains "this script only runs in the toolkit project"

start_case "merges-open-mr-while-loop-runs"
run_self_merge
assert_success
assert_merge_count 1
assert_output_contains "Merged merge request !12 at aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa without waiting for pipeline success"
assert_output_contains "No open Renovate merge requests remain for main"

start_case "already-merged-mr-is-a-noop"
jq '.state = "merged"' "$case_dir/mr-details/12.json" >"$case_dir/mr.tmp"
mv "$case_dir/mr.tmp" "$case_dir/mr-details/12.json"
run_self_merge
assert_success
assert_merge_count 0
assert_output_contains "Merge request !12 is already merged"

start_case "draft-mr-is-skipped"
jq '.draft = true' "$case_dir/mr-details/12.json" >"$case_dir/mr.tmp"
mv "$case_dir/mr.tmp" "$case_dir/mr-details/12.json"
printf '%s\n' "[${default_mr}]" "[${default_mr}]" "[${default_mr}]" "[${default_mr}]" "[${default_mr}]" >"$case_dir/mr-list-seq"
run_self_merge
assert_failure
assert_merge_count 0
assert_output_contains "is a draft; automatic merge is skipped"
assert_output_contains "need a manual merge"

start_case "conflicted-mr-is-skipped"
jq '.has_conflicts = true' "$case_dir/mr-details/12.json" >"$case_dir/mr.tmp"
mv "$case_dir/mr.tmp" "$case_dir/mr-details/12.json"
printf '%s\n' "[${default_mr}]" "[${default_mr}]" "[${default_mr}]" "[${default_mr}]" "[${default_mr}]" >"$case_dir/mr-list-seq"
run_self_merge
assert_failure
assert_merge_count 0
assert_output_contains "has conflicts; automatic merge is skipped"

start_case "pipeline-gated-mr-is-skipped"
jq '.merge_when_pipeline_succeeds = true' "$case_dir/mr-details/12.json" >"$case_dir/mr.tmp"
mv "$case_dir/mr.tmp" "$case_dir/mr-details/12.json"
printf '%s\n' "[${default_mr}]" "[${default_mr}]" "[${default_mr}]" "[${default_mr}]" "[${default_mr}]" >"$case_dir/mr-list-seq"
run_self_merge
assert_failure
assert_merge_count 0
assert_output_contains "pipeline-gated auto-merge armed"

start_case "retry-on-transient-mergeability"
printf '%s\n' running success >"$case_dir/sibling-status"
printf '%s\n' "[${default_mr}]" '[]' >"$case_dir/mr-list-seq"
MOCK_MERGE_STATUSES="405,200" SELF_MERGE_TEST_MERGE_DELAY="2" run_self_merge
assert_success
assert_merge_count 2
grep -Fx '2' "$case_dir/sleep.log" >/dev/null

start_case "merge-token-rejection-fails"
printf '%s\n' running success >"$case_dir/sibling-status"
printf '%s\n' "[${default_mr}]" '[]' >"$case_dir/mr-list-seq"
MOCK_MERGE_STATUSES="401" run_self_merge
assert_failure
assert_merge_count 3
assert_output_contains "no available token can merge merge request !12"
assert_output_contains "HTTP 401"

start_case "cancels-obsolete-renovate-pipeline"
jq -n '[
  {id: 9000, source: "schedule", ref: "main", status: "running"},
  {id: 5000, source: "schedule", ref: "main", status: "running"}
]' >"$case_dir/pipelines.json"
printf '%s\n' running success >"$case_dir/sibling-status"
printf '%s\n' '[]' '[]' >"$case_dir/mr-list-seq"
run_self_merge
assert_success
assert_cancel_count 1
assert_output_contains "Canceling obsolete Renovate pipeline 5000"

start_case "newer-pipeline-wins-cleanup"
jq -n '[
  {id: 9500, source: "schedule", ref: "main", status: "running"}
]' >"$case_dir/pipelines.json"
printf '%s\n' running success >"$case_dir/sibling-status"
printf '%s\n' '[]' '[]' >"$case_dir/mr-list-seq"
run_self_merge
assert_success
assert_cancel_count 0
assert_output_contains "no longer the latest orchestrator"

start_case "non-renovate-pipeline-is-not-canceled"
jq -n '[
  {id: 4800, source: "api", ref: "main", status: "running"}
]' >"$case_dir/pipelines.json"
jq -n '[{id: 1, name: "shell:test", status: "success"}]' >"$case_dir/candidate-jobs/4800.json"
printf '%s\n' running success >"$case_dir/sibling-status"
printf '%s\n' '[]' '[]' >"$case_dir/mr-list-seq"
run_self_merge
assert_success
assert_cancel_count 0
assert_output_contains "No obsolete active Renovate pipelines to cancel"

start_case "cleanup-survives-missing-control-token"
SELF_MERGE_TEST_CONTROL_TOKEN="" run_self_merge
assert_success
assert_cancel_count 0
assert_output_contains "No obsolete active Renovate pipelines to cancel"

echo "auto_merge_self_renovate_mrs tests passed"
