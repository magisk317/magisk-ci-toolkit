#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
controller_script="$(cd "$script_dir/.." && pwd)/cancel_older_mr_pipelines.sh"
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

if [[ "$url" == */api/graphql ]]; then
  echo "unexpected GraphQL request" >&2
  exit 64
fi

if [[ "$method" == "GET" && "$url" =~ /projects/[0-9]+/pipelines$ ]]; then
  printf '%s\n' "$page" >>"$MOCK_PAGE_LOG"
  start=$(((page - 1) * per_page))
  stop=$((start + per_page))
  jq \
    --slurpfile canceled "$MOCK_STATE_FILE" \
    --argjson start "$start" \
    --argjson stop "$stop" '
      map(
        . as $pipeline
        | if (($canceled[0] | index($pipeline.id)) != null)
          then .status = "canceled"
          else .
          end
        | .created_at = (.created_at // ("2026-01-01T00:00:00." + (.id | tostring) + "Z"))
      )
      | .[$start:$stop]
    ' "$MOCK_PIPELINES_FILE" >"$output_file"
  exit 0
fi

if [[ "$method" == "GET" && "$url" =~ /projects/[0-9]+/pipelines/([0-9]+)$ ]]; then
  pipeline_id="${BASH_REMATCH[1]}"
  jq \
    --argjson id "$pipeline_id" \
    --argjson iid "$MAGISK_UPSTREAM_PIPELINE_IID" \
    --argjson project_id "$MAGISK_UPSTREAM_PROJECT_ID" \
    --arg ref "$MAGISK_UPSTREAM_REF" \
    'map(select(.id == $id)) | .[0] + {iid: $iid, project_id: $project_id, ref: $ref, created_at: (.[0].created_at // ("2026-01-01T00:00:00." + ($id | tostring) + "Z"))}' \
    "$MOCK_PIPELINES_FILE" >"$output_file"
  exit 0
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

echo "mock curl: unsupported request ${method} ${url}" >&2
exit 64
MOCK_CURL
chmod +x "$mock_bin/curl"

case_dir=""
run_status=0

start_case() {
  local name="$1"
  case_dir="$tmp_root/$name"
  mkdir -p "$case_dir"
  printf '[]\n' >"$case_dir/state.json"
  : >"$case_dir/pages.log"
  : >"$case_dir/cancel-attempts.log"
}

write_graphql() {
  local upstream_id="$1"
  local upstream_iid="$2"
  local upstream_source="$3"
  local upstream_ref="$4"
  local upstream_project_id="$5"
  local upstream_project_path="$6"

  cat >"$case_dir/upstream.env" <<EOF
MAGISK_UPSTREAM_PROJECT_ID=$upstream_project_id
MAGISK_UPSTREAM_PROJECT_PATH=$upstream_project_path
MAGISK_UPSTREAM_PIPELINE_ID=$upstream_id
MAGISK_UPSTREAM_PIPELINE_IID=$upstream_iid
MAGISK_UPSTREAM_PIPELINE_SOURCE=$upstream_source
MAGISK_UPSTREAM_REF=$upstream_ref
EOF

  jq -n \
    --arg upstream_id "gid://gitlab/Ci::Pipeline/${upstream_id}" \
    --arg upstream_iid "$upstream_iid" \
    --arg upstream_source "$upstream_source" \
    --arg upstream_ref "$upstream_ref" \
    --arg upstream_project_id "gid://gitlab/Project/${upstream_project_id}" \
    --arg upstream_project_path "$upstream_project_path" '
      {
        data: {
          project: {
            pipeline: {
              id: "gid://gitlab/Ci::Pipeline/9000",
              iid: "42",
              source: "pipeline",
              ref: "main",
              project: {
                id: "gid://gitlab/Project/83955109",
                fullPath: "magisk3171/shared/magisk-ci-toolkit"
              },
              upstream: {
                id: $upstream_id,
                iid: $upstream_iid,
                source: $upstream_source,
                ref: $upstream_ref,
                project: {
                  id: $upstream_project_id,
                  fullPath: $upstream_project_path
                }
              }
            }
          }
        }
      }
    ' >"$case_dir/graphql.json"
}

write_pipelines() {
  printf '%s\n' "$1" | jq . >"$case_dir/pipelines.json"
}

run_controller() {
  local fail_ids="${1:-}"
  # shellcheck disable=SC1091
  source "$case_dir/upstream.env"
  set +e
  env \
    PATH="$mock_bin:$PATH" \
    MOCK_GRAPHQL_FILE="$case_dir/graphql.json" \
    MOCK_PIPELINES_FILE="$case_dir/pipelines.json" \
    MOCK_STATE_FILE="$case_dir/state.json" \
    MOCK_PAGE_LOG="$case_dir/pages.log" \
    MOCK_CANCEL_ATTEMPT_LOG="$case_dir/cancel-attempts.log" \
    MOCK_FAIL_CANCEL_IDS="$fail_ids" \
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

start_case "pagination-and-filtering"
write_graphql 200 20 merge_request_event refs/merge-requests/20/head 83955143 magisk3171/MiPushFramework
write_pipelines '[
  {"id":200,"source":"merge_request_event","ref":"refs/merge-requests/20/head","status":"running"},
  {"id":199,"source":"merge_request_event","ref":"refs/merge-requests/20/head","status":"pending"},
  {"id":198,"source":"merge_request_event","ref":"refs/merge-requests/20/head","status":"success"},
  {"id":197,"source":"merge_request_event","ref":"refs/merge-requests/20/head","status":"manual"},
  {"id":196,"source":"merge_request_event","ref":"refs/merge-requests/20/head","status":"failed"}
]'
run_controller
assert_success
assert_state '[197,199]'
page_requests="$(wc -l <"$case_dir/pages.log")"
((page_requests >= 3)) || {
  echo "Expected pagination to request at least three pages" >&2
  exit 1
}

start_case "push-cancels-older-mr"
write_graphql 600 60 push main 83955143 magisk3171/MiPushFramework
write_pipelines '[
  {"id":600,"source":"push","ref":"main","status":"running","created_at":"2026-01-01T00:01:00Z"},
  {"id":599,"source":"push","ref":"main","status":"running","created_at":"2026-01-01T00:00:59Z"},
  {"id":598,"source":"merge_request_event","ref":"refs/merge-requests/58/head","status":"running","created_at":"2026-01-01T00:00:58Z"}
]'
run_controller
assert_success
assert_state '[599]'
grep -F "Canceling older MR/push pipeline 599" "$case_dir/output.log" >/dev/null

start_case "no-active-pipelines"
write_graphql 300 30 merge_request_event refs/merge-requests/30/head 83955172 magisk3171/XposedSmsCode
write_pipelines '[
  {"id":300,"source":"merge_request_event","ref":"refs/merge-requests/30/head","status":"success"},
  {"id":299,"source":"merge_request_event","ref":"refs/merge-requests/29/head","status":"failed"}
]'
run_controller
assert_success
assert_state '[]'

start_case "untrusted-upstream"
write_graphql 350 35 merge_request_event refs/merge-requests/35/head 99999999 untrusted/example
write_pipelines '[]'
run_controller
assert_failure
grep -F "upstream project is not in the controller allowlist" "$case_dir/output.log" >/dev/null

start_case "push-upstream-is-accepted"
write_graphql 360 36 push main 83955143 magisk3171/MiPushFramework
write_pipelines '[
  {"id":360,"source":"push","ref":"main","status":"running"}
]'
run_controller
assert_success
assert_state '[]'

start_case "invalid-merge-request-ref"
write_graphql 370 37 merge_request_event feature/test 84113188 magisk3171/xinyi-relay
write_pipelines '[]'
run_controller
assert_failure
grep -F "upstream merge request pipeline ref is invalid" "$case_dir/output.log" >/dev/null

start_case "out-of-order-controller"
write_graphql 400 40 merge_request_event refs/merge-requests/40/head 85198813 magisk3171/SerialBridge
write_pipelines '[
  {"id":410,"source":"merge_request_event","ref":"refs/merge-requests/41/head","status":"running"},
  {"id":400,"source":"merge_request_event","ref":"refs/merge-requests/40/head","status":"running"},
  {"id":390,"source":"merge_request_event","ref":"refs/merge-requests/39/head","status":"waiting_for_resource"}
]'
run_controller
assert_success
assert_state '[]'
grep -F "no older active MR/push pipelines remain" "$case_dir/output.log" >/dev/null

start_case "persistent-cancel-failure"
write_graphql 500 50 merge_request_event refs/merge-requests/50/head 83955143 magisk3171/MiPushFramework
write_pipelines '[
  {"id":500,"source":"merge_request_event","ref":"refs/merge-requests/50/head","status":"running"},
  {"id":490,"source":"merge_request_event","ref":"refs/merge-requests/50/head","status":"running"}
]'
run_controller "490"
assert_failure
assert_state '[]'
grep -F "older active MR/push pipelines remain after reconciliation: 490" "$case_dir/output.log" >/dev/null

echo "cancel_older_mr_pipelines tests passed"
