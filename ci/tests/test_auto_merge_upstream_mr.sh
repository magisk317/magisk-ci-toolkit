#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
controller_script="$(cd "$script_dir/.." && pwd)/auto_merge_upstream_mr.sh"
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
sha=""
merge_message=""

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
        sha=*) sha="${2#sha=}" ;;
        merge_commit_message=*) merge_message="${2#merge_commit_message=}" ;;
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

if [[ "$url" == */api/graphql ]]; then
  echo "unexpected GraphQL request" >&2
  exit 64
fi

if [[ "$method" == "GET" && "$url" =~ /projects/[0-9]+/pipelines/[0-9]+$ ]]; then
  jq '. + {created_at: (.created_at // "2026-01-01T00:00:00.200Z")}' "$MOCK_PIPELINE_FILE" >"$output_file"
  exit 0
fi

if [[ "$method" == "GET" && "$url" =~ /projects/[0-9]+/pipelines$ ]]; then
  jq '[.[] | . as $pipeline | $pipeline + {created_at: ($pipeline.created_at // "2026-01-01T00:00:00.200Z")}]' "$MOCK_PIPELINES_FILE" >"$output_file"
  exit 0
fi

if [[ "$method" == "GET" && "$url" =~ /projects/[0-9]+/merge_requests/[0-9]+$ ]]; then
  cp "$MOCK_MR_FILE" "$output_file"
  exit 0
fi

if [[ "$method" == "POST" && "$url" =~ /projects/[0-9]+/merge_requests/[0-9]+/cancel_merge_when_pipeline_succeeds$ ]]; then
  count="$(cat "$MOCK_CANCEL_AUTO_MERGE_COUNT_FILE")"
  printf '%s\n' "$((count + 1))" >"$MOCK_CANCEL_AUTO_MERGE_COUNT_FILE"
  case "${MOCK_CANCEL_AUTO_MERGE_STATUS:-200}" in
    200 | 201)
      jq '.merge_when_pipeline_succeeds = false' "$MOCK_MR_FILE" >"$output_file"
      ;;
    204)
      : >"$output_file"
      ;;
    *)
      jq -n '{message: "cancel failed"}' >"$output_file"
      ;;
  esac
  [[ "$write_out" == "%{http_code}" ]] && printf '%s' "${MOCK_CANCEL_AUTO_MERGE_STATUS:-200}"
  exit 0
fi

if [[ "$method" == "PUT" && "$url" =~ /projects/[0-9]+/merge_requests/[0-9]+/merge$ ]]; then
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
    jq --arg sha "$sha" --arg message "$merge_message" \
      '.state = "merged" | .merge_when_pipeline_succeeds = false | .merge_commit_sha = $sha | .merge_message = $message' \
      "$MOCK_MR_FILE" >"$output_file"
  else
    jq -n --arg message "merge is not ready" '{message: $message}' >"$output_file"
  fi
  [[ "$write_out" == "%{http_code}" ]] && printf '%s' "$status"
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
  printf '0\n' >"$case_dir/merge-count"
  printf '0\n' >"$case_dir/cancel-auto-merge-count"
  : >"$case_dir/sleep.log"
  printf '%s\n' "{
    \"data\": {\"project\": {\"pipeline\": {
      \"id\": \"gid://gitlab/Ci::Pipeline/9000\", \"iid\": \"42\", \"source\": \"pipeline\", \"ref\": \"main\",
      \"project\": {\"id\": \"gid://gitlab/Project/83955109\", \"fullPath\": \"magisk3171/shared/magisk-ci-toolkit\"},
      \"upstream\": {
        \"id\": \"gid://gitlab/Ci::Pipeline/200\", \"iid\": \"20\", \"source\": \"merge_request_event\", \"ref\": \"refs/merge-requests/20/head\",
        \"project\": {\"id\": \"gid://gitlab/Project/83955143\", \"fullPath\": \"magisk3171/MiPushFramework\"}
      }
    }}}}
  " >"$case_dir/graphql.json"
  jq -n '{id:200,iid:20,project_id:83955143,source:"merge_request_event",ref:"refs/merge-requests/20/head",status:"canceled",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' >"$case_dir/pipeline.json"
  jq -n '[{id:200,iid:20,project_id:83955143,source:"merge_request_event",ref:"refs/merge-requests/20/head",status:"running",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]' >"$case_dir/pipelines.json"
  jq -n '{iid:20,project_id:83955143,target_project_id:83955143,source_project_id:83955143,state:"opened",draft:false,sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",has_conflicts:false,source_branch:"ci/skip-post-merge/policy",target_branch:"beta",title:"policy smoke",merge_when_pipeline_succeeds:false}' >"$case_dir/mr.json"
}

run_controller() {
  set +e
  env \
    PATH="$mock_bin:$PATH" \
    MOCK_GRAPHQL_FILE="$case_dir/graphql.json" \
    MOCK_PIPELINE_FILE="$case_dir/pipeline.json" \
    MOCK_PIPELINES_FILE="$case_dir/pipelines.json" \
    MOCK_MR_FILE="$case_dir/mr.json" \
    MOCK_MERGE_COUNT_FILE="$case_dir/merge-count" \
    MOCK_CANCEL_AUTO_MERGE_COUNT_FILE="$case_dir/cancel-auto-merge-count" \
    MOCK_SLEEP_LOG="$case_dir/sleep.log" \
    MOCK_CANCEL_AUTO_MERGE_STATUS="${MOCK_CANCEL_AUTO_MERGE_STATUS:-200}" \
    MOCK_MERGE_STATUSES="${MOCK_MERGE_STATUSES:-200}" \
    CI_API_V4_URL="https://gitlab.example/api/v4" \
    CI_API_GRAPHQL_URL="https://gitlab.example/api/graphql" \
    CI_SERVER_URL="https://gitlab.example" \
    CI_PROJECT_ID="83955109" \
    CI_PROJECT_PATH="magisk3171/shared/magisk-ci-toolkit" \
    CI_PIPELINE_ID="9000" \
    CI_PIPELINE_IID="42" \
    CI_PIPELINE_SOURCE="pipeline" \
    CI_COMMIT_REF_NAME="main" \
    CI_DEFAULT_BRANCH="main" \
    CI_COMMIT_REF_PROTECTED="true" \
    MAGISK_CI_PIPELINE_CONTROL_TOKEN="pipeline-token" \
    MAGISK_CI_MR_AUTOMERGE_TOKEN="merge-token" \
    MAGISK_UPSTREAM_PROJECT_ID="83955143" \
    MAGISK_UPSTREAM_PROJECT_PATH="magisk3171/MiPushFramework" \
    MAGISK_UPSTREAM_PIPELINE_ID="200" \
    MAGISK_UPSTREAM_PIPELINE_IID="20" \
    MAGISK_UPSTREAM_PIPELINE_SOURCE="merge_request_event" \
    MAGISK_UPSTREAM_REF="refs/merge-requests/20/head" \
    bash "$controller_script" >"$case_dir/output.log" 2>&1
  run_status=$?
  set -e
}

assert_success() {
  [[ "$run_status" -eq 0 ]] || {
    cat "$case_dir/output.log" >&2
    echo "Expected auto-merge success, got ${run_status}" >&2
    exit 1
  }
}

assert_failure() {
  [[ "$run_status" -ne 0 ]] || {
    cat "$case_dir/output.log" >&2
    echo "Expected auto-merge failure" >&2
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

assert_cancel_auto_merge_count() {
  local expected="$1"
  [[ "$(cat "$case_dir/cancel-auto-merge-count")" == "$expected" ]] || {
    echo "Expected ${expected} cancel-auto-merge calls" >&2
    cat "$case_dir/cancel-auto-merge-count" >&2
    exit 1
  }
}

start_case "canceled-pipeline-merges-immediately"
run_controller
assert_success
assert_merge_count 1
grep -F "without waiting for pipeline success" "$case_dir/output.log" >/dev/null
grep -F "Post-merge pipeline will be skipped" "$case_dir/output.log" >/dev/null

start_case "newer-push-does-not-block-mr-merge"
jq '. + [{id:201,iid:21,project_id:83955143,source:"push",ref:"beta",status:"running",sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",created_at:"2026-01-01T00:00:01Z"}]' "$case_dir/pipelines.json" >"$case_dir/pipelines.tmp"
mv "$case_dir/pipelines.tmp" "$case_dir/pipelines.json"
run_controller
assert_success
assert_merge_count 1
grep -F "pipeline status is intentionally not a merge gate" "$case_dir/output.log" >/dev/null

start_case "pipeline-gated-auto-merge-is-replaced"
jq '.merge_when_pipeline_succeeds = true' "$case_dir/mr.json" >"$case_dir/mr.tmp"
mv "$case_dir/mr.tmp" "$case_dir/mr.json"
run_controller
assert_success
assert_merge_count 1
assert_cancel_auto_merge_count 1
grep -F "Canceled the existing pipeline-gated auto-merge" "$case_dir/output.log" >/dev/null

start_case "pipeline-gated-auto-merge-201-is-replaced"
jq '.merge_when_pipeline_succeeds = true' "$case_dir/mr.json" >"$case_dir/mr.tmp"
mv "$case_dir/mr.tmp" "$case_dir/mr.json"
MOCK_CANCEL_AUTO_MERGE_STATUS=201 run_controller
assert_success
assert_merge_count 1
assert_cancel_auto_merge_count 1
grep -F "Canceled the existing pipeline-gated auto-merge" "$case_dir/output.log" >/dev/null

start_case "pipeline-gated-auto-merge-204-is-replaced"
jq '.merge_when_pipeline_succeeds = true' "$case_dir/mr.json" >"$case_dir/mr.tmp"
mv "$case_dir/mr.tmp" "$case_dir/mr.json"
MOCK_CANCEL_AUTO_MERGE_STATUS=204 run_controller
assert_success
assert_merge_count 1
assert_cancel_auto_merge_count 1
grep -F "Canceled the existing pipeline-gated auto-merge" "$case_dir/output.log" >/dev/null

start_case "retry-on-transient-mergeability"
MOCK_MERGE_STATUSES="405,200" run_controller
assert_success
assert_merge_count 2
grep -Fx '2' "$case_dir/sleep.log" >/dev/null

start_case "retry-sequence-is-bounded"
MOCK_MERGE_STATUSES="405,422,429,500,502,503" run_controller
assert_failure
assert_merge_count 6
printf '2\n4\n8\n16\n32\n' | diff -u - "$case_dir/sleep.log"
grep -F "did not become mergeable after 6 attempts" "$case_dir/output.log" >/dev/null

start_case "draft-is-not-merged"
jq '.draft = true' "$case_dir/mr.json" >"$case_dir/mr.tmp"
mv "$case_dir/mr.tmp" "$case_dir/mr.json"
run_controller
assert_success
assert_merge_count 0
grep -F "is Draft" "$case_dir/output.log" >/dev/null

start_case "fork-is-not-merged"
jq '.source_project_id = 123456' "$case_dir/mr.json" >"$case_dir/mr.tmp"
mv "$case_dir/mr.tmp" "$case_dir/mr.json"
run_controller
assert_success
assert_merge_count 0
grep -F "comes from another project" "$case_dir/output.log" >/dev/null

start_case "stale-head-fails-safe"
jq '.sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$case_dir/mr.json" >"$case_dir/mr.tmp"
mv "$case_dir/mr.tmp" "$case_dir/mr.json"
run_controller
assert_failure
assert_merge_count 0
grep -F "HEAD no longer matches" "$case_dir/output.log" >/dev/null

start_case "conflicted-mr-is-skipped"
jq '.has_conflicts = true' "$case_dir/mr.json" >"$case_dir/mr.tmp"
mv "$case_dir/mr.tmp" "$case_dir/mr.json"
run_controller
assert_success
assert_merge_count 0
grep -F "has conflicts; automatic merge is skipped" "$case_dir/output.log" >/dev/null

echo "auto_merge_upstream_mr tests passed"
