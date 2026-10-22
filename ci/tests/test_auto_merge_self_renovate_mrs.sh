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
compare_from=""
merge_sha=""
skip_ci=""
token=""

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
        from=*) compare_from="${2#from=}" ;;
        sha=*) merge_sha="${2#sha=}" ;;
        skip_ci=*) skip_ci="${2#skip_ci=}" ;;
      esac
      shift 2
      ;;
    --write-out)
      write_out="$2"
      shift 2
      ;;
    --header)
      case "$2" in
        'PRIVATE-TOKEN: '*) token="${2#'PRIVATE-TOKEN: '}" ;;
      esac
      shift 2
      ;;
    --data)
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

# The stored merge request file is the single source of truth for the request
# HEAD: the rebase route rewrites it, so every later read - and the sha-pinned
# merge - sees the new branch tip the way GitLab does.
readonly MR_REBASED_SHA="${MOCK_REBASED_SHA:-dddddddddddddddddddddddddddddddddddddddd}"
mr_is_rebased() { [[ -e "$MOCK_REBASED_FILE" ]]; }

# Transient-failure injection: when the URL matches MOCK_CURL_FAIL_URL_MATCH
# (an ERE) and this case's failure count is still below MOCK_CURL_FAIL_TIMES,
# simulate a curl transport failure - default exit 7, the "connection refused"
# class the 2026-10-14 clash container recreation produced - before the
# request is routed, so no state is recorded for the failed attempt.
if [[ -n "${MOCK_CURL_FAIL_URL_MATCH:-}" && "$url" =~ ${MOCK_CURL_FAIL_URL_MATCH} ]]; then
  if [[ -n "${MOCK_CURL_FAIL_COUNT_FILE:-}" ]]; then
    fail_count="$(cat "$MOCK_CURL_FAIL_COUNT_FILE")"
    printf '%s\n' "$((fail_count + 1))" >"$MOCK_CURL_FAIL_COUNT_FILE"
    if ((fail_count < ${MOCK_CURL_FAIL_TIMES:-1})); then
      exit "${MOCK_CURL_FAIL_EXIT:-7}"
    fi
  fi
fi

respond() {
  printf '%s' "$1" >"$output_file"
  if [[ "$write_out" == "%{http_code}" ]]; then printf '200'; fi
}

# respond_with <http-status> <jq-object>: write the body and report the status
# through --write-out, the way a GitLab 4xx answers with a JSON body instead of
# a curl-level failure.
respond_with() {
  printf '%s' "$(jq -nc "$2")" >"$output_file"
  if [[ "$write_out" == "%{http_code}" ]]; then printf '%s' "$1"; fi
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

# Behindness is modelled with the only signal a fast-forward project gives the
# controller: the compare against the target branch. MOCK_BEHIND=1 keeps the
# request missing a commit until its rebase lands (the marker file), which is
# the state merge_method=ff refuses to merge.
if [[ "$method" == "GET" && "$url" =~ /repository/compare$ ]]; then
  if [[ "${MOCK_BEHIND:-}" == "1" ]] && ! mr_is_rebased; then
    respond "$(jq -nc '{compare_timeout: false, commits: [{id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", title: "a commit the request is missing"}]}')"
  else
    respond "$(jq -nc '{compare_timeout: false, commits: []}')"
  fi
  exit 0
fi

if [[ "$method" == "PUT" && "$url" =~ /merge_requests/([0-9]+)/rebase$ ]]; then
  iid="${BASH_REMATCH[1]}"
  detail_file="$MOCK_MR_DETAILS_DIR/${iid}.json"
  count="$(cat "$MOCK_REBASE_COUNT_FILE")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$MOCK_REBASE_COUNT_FILE"
  [[ "$skip_ci" == "true" ]] || {
    echo "mock curl: a branch rewrite must be queued with skip_ci=true" >&2
    exit 64
  }
  if [[ "${MOCK_BEHIND:-}" != "1" ]]; then
    echo "mock curl: rebasing a request that is not behind is a controller bug" >&2
    exit 64
  fi
  if [[ -n "${MOCK_REBASE_FORBIDDEN_TOKENS:-}" ]] &&
    [[ ",${MOCK_REBASE_FORBIDDEN_TOKENS}," == *",${token},"* ]]; then
    # The merge rights a request needs and the push rights a branch rewrite
    # needs are different grants: this is the merge-only token being turned
    # away while the request stays behind.
    respond_with 403 '{message: "Cannot push to source branch."}'
    exit 0
  fi
  status="${MOCK_REBASE_HTTP_STATUS:-202}"
  case "$status" in
    202)
      jq -c --arg sha "$MR_REBASED_SHA" '.sha = $sha' "$detail_file" >"$detail_file.new"
      mv "$detail_file.new" "$detail_file"
      : >"$MOCK_REBASED_FILE"
      respond_with 202 '{rebase_in_progress: true}'
      ;;
    *)
      respond_with "$status" '{message: "rebase rejected by mock"}'
      ;;
  esac
  exit 0
fi

if [[ "$method" == "PUT" && "$url" =~ /merge_requests/([0-9]+)/merge$ ]]; then
  iid="${BASH_REMATCH[1]}"
  detail_file="$MOCK_MR_DETAILS_DIR/${iid}.json"
  if [[ -n "$merge_sha" && "$merge_sha" != "$(jq -r '.sha' "$detail_file")" ]]; then
    # The controller pinned a sha the branch no longer points at: it merged
    # without re-reading after a rewrite.
    respond_with 409 '{message: "The merged sha does not match the source branch HEAD."}'
    exit 0
  fi
  if [[ "${MOCK_BEHIND:-}" == "1" ]] && ! mr_is_rebased; then
    respond_with 422 '{message: "Branch cannot be merged"}'
    exit 0
  fi
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
    printf '%s' "$(jq -c '.state = "merged"' "$detail_file")" >"$output_file"
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
  printf '0\n' >"$case_dir/rebase-count"
  printf '0\n' >"$case_dir/cancel-count"
  printf '0\n' >"$case_dir/sibling-calls"
  printf '0\n' >"$case_dir/mr-list-calls"
  printf '0\n' >"$case_dir/curl-fail-count"
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
    MOCK_REBASE_COUNT_FILE="$case_dir/rebase-count" \
    MOCK_REBASED_FILE="$case_dir/rebased" \
    MOCK_BEHIND="${MOCK_BEHIND:-}" \
    MOCK_REBASE_HTTP_STATUS="${MOCK_REBASE_HTTP_STATUS:-}" \
    MOCK_REBASE_FORBIDDEN_TOKENS="${MOCK_REBASE_FORBIDDEN_TOKENS:-}" \
    MOCK_CANCEL_COUNT_FILE="$case_dir/cancel-count" \
    MOCK_SLEEP_LOG="$case_dir/sleep.log" \
    MOCK_MERGE_STATUSES="${MOCK_MERGE_STATUSES:-200}" \
    MOCK_CURL_FAIL_TIMES="${MOCK_CURL_FAIL_TIMES:-1}" \
    MOCK_CURL_FAIL_URL_MATCH="${MOCK_CURL_FAIL_URL_MATCH:-}" \
    MOCK_CURL_FAIL_EXIT="${MOCK_CURL_FAIL_EXIT:-7}" \
    MOCK_CURL_FAIL_COUNT_FILE="$case_dir/curl-fail-count" \
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
    MAGISK_SELF_MERGE_AUTOREBASE="${MAGISK_SELF_MERGE_AUTOREBASE:-true}" \
    MAGISK_SELF_MERGE_REBASE_POLLS="${SELF_MERGE_TEST_REBASE_POLLS:-2}" \
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

assert_rebase_count() {
  local expected="$1"
  [[ "$(cat "$case_dir/rebase-count")" == "$expected" ]] || {
    echo "Expected ${expected} rebase calls" >&2
    cat "$case_dir/rebase-count" >&2
    exit 1
  }
}

assert_output_absent() {
  local unexpected="$1"
  if grep -F "$unexpected" "$case_dir/output.log" >/dev/null; then
    echo "Expected output not to contain: ${unexpected}" >&2
    cat "$case_dir/output.log" >&2
    exit 1
  fi
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

start_case "survives-transient-read-failure"
# 2026-10-14 replay: the single-shot sibling-status poll is the call that died
# when the runner's proxy refused connections. The shared ladder must absorb
# it and still merge the request in the same run.
printf '%s\n' running running success >"$case_dir/sibling-status"
MOCK_CURL_FAIL_URL_MATCH='/jobs$' run_self_merge
assert_success
assert_merge_count 1
assert_output_contains "Transient failure calling"
assert_output_contains "Merged merge request !12 at aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa without waiting for pipeline success"
grep -Fx '2' "$case_dir/sleep.log" >/dev/null

start_case "survives-transient-merge-failure"
# Same failure class on the merge PUT itself: the ladder retries the write
# instead of killing the job after the request was already validated.
printf '%s\n' running success >"$case_dir/sibling-status"
printf '%s\n' "[${default_mr}]" '[]' '[]' >"$case_dir/mr-list-seq"
MOCK_CURL_FAIL_URL_MATCH='/merge$' run_self_merge
assert_success
assert_merge_count 1
assert_output_contains "Transient failure calling"
grep -Fx '2' "$case_dir/sleep.log" >/dev/null

start_case "exhausted-merge-retries-fail"
# A transport that stays broken for the whole ladder must fail loudly with
# the 000 branch instead of silently rotating tokens or burning the window.
printf '%s\n' running success >"$case_dir/sibling-status"
printf '%s\n' "[${default_mr}]" '[]' >"$case_dir/mr-list-seq"
MOCK_CURL_FAIL_URL_MATCH='/merge$' MOCK_CURL_FAIL_TIMES="99" run_self_merge
assert_failure
assert_merge_count 0
assert_output_contains "kept failing at the transport level after 6 attempts"
grep -Fx '32' "$case_dir/sleep.log" >/dev/null


# A request that fell behind the target branch cannot be fast-forwarded merged:
# GitLab refuses every attempt with HTTP 422 "Branch cannot be merged" while
# merge_status still reads can_be_merged and detailed_merge_status mergeable.
# The controller now measures behindness with a compare and fast-forwards the
# request through the rebase endpoint, then re-reads it and merges the new HEAD
# - the deadlock that cost the toolkit its own Renovate requests every night.
start_case "merges-behind-mr-after-rebasing"
printf '%s\n' running success >"$case_dir/sibling-status"
printf '%s\n' "[${default_mr}]" '[]' '[]' '[]' >"$case_dir/mr-list-seq"
MOCK_BEHIND=1 run_self_merge
assert_success
assert_rebase_count 1
assert_merge_count 1
assert_output_contains "Merge request !12 is behind main; rebasing it before merging (1/2)."
assert_output_contains "Rebased merge request !12 onto main at dddd"
assert_output_contains "Merged merge request !12 at dddd"
assert_output_contains "No open Renovate merge requests remain for main"

# A merge-only token can land the PUT but is refused when pushing the source
# branch. The rebase has to rotate tokens the way the merge does and succeed
# with the one that can push, instead of declaring the request unfixable.
start_case "behind-mr-rebase-rotates-to-a-token-that-can-push"
printf '%s\n' running success >"$case_dir/sibling-status"
printf '%s\n' "[${default_mr}]" '[]' '[]' '[]' >"$case_dir/mr-list-seq"
MOCK_BEHIND=1 MOCK_REBASE_FORBIDDEN_TOKENS="merge-token" run_self_merge
assert_success
assert_rebase_count 2
assert_output_contains "Rebase request for !12 with the current token returned HTTP 403: Cannot push to source branch."
assert_output_contains "Rebased merge request !12 onto main at dddd"
assert_merge_count 1

# Only when every token is turned away is the refusal permanent: the controller
# stops rewriting and reports the state an operator has to fix (a token without
# push rights), instead of burning rebases on a branch it cannot move.
start_case "behind-mr-rebase-refused-by-every-token"
printf '%s\n' running success >"$case_dir/sibling-status"
printf '%s\n' "[${default_mr}]" "[${default_mr}]" "[${default_mr}]" '[]' >"$case_dir/mr-list-seq"
MOCK_BEHIND=1 MOCK_REBASE_HTTP_STATUS=403 run_self_merge
assert_failure
assert_output_contains "No available token can rebase merge request !12 (HTTP 403: rebase rejected by mock); it stays behind main."
assert_output_absent "(2/2)"
assert_output_contains "open Renovate merge requests remain and need a manual merge: !12"

# MAGISK_SELF_MERGE_AUTOREBASE=false restores the pre-fix behaviour, and the
# request stays open: the 422 is still classified as transient readiness, the
# attempts still run out, and the final sweep reports it for a human.
start_case "behind-mr-is-not-rebased-when-autorebase-is-off"
printf '%s\n' running success >"$case_dir/sibling-status"
printf '%s\n' "[${default_mr}]" "[${default_mr}]" "[${default_mr}]" '[]' >"$case_dir/mr-list-seq"
MOCK_BEHIND=1 MAGISK_SELF_MERGE_AUTOREBASE=false run_self_merge
assert_failure
assert_rebase_count 0
assert_output_absent "rebasing it before merging"
assert_output_contains "Merge attempt 6/6 for !12 returned HTTP 422: Branch cannot be merged"
assert_output_contains "open Renovate merge requests remain and need a manual merge: !12"

echo "auto_merge_self_renovate_mrs tests passed"
