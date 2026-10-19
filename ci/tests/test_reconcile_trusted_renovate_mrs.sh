#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
reconcile_script="$(cd "$script_dir/.." && pwd)/reconcile_trusted_renovate_mrs.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf -- "$tmp_root"' EXIT

mock_bin="$tmp_root/bin"
mkdir -p "$mock_bin"

cat >"$mock_bin/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"${MOCK_SLEEP_LOG:?}"
MOCK_SLEEP
chmod +x "$mock_bin/sleep"

# The mock emulates curl's contract with the shared retry ladder: HTTP errors
# surface as exit 22 with the status on stdout (--write-out), transport
# failures as exit 28 with no status, and --fail is accepted but ignored.
cat >"$mock_bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail

output_file=""
method="GET"
url=""
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
    --header | --write-out)
      shift 2
      ;;
    --get | --fail | --silent | --show-error | --location)
      shift
      ;;
    # The retry ladder's flags: the mock classifies failures itself.
    --retry | --retry-delay | --retry-max-time)
      shift 2
      ;;
    --retry-connrefused)
      shift
      ;;
    --data-urlencode)
      shift 2
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

[[ -n "$url" ]] || { echo "mock curl: no URL" >&2; exit 64; }

if [[ "$url" =~ /projects/([0-9]+)/merge_requests/([0-9]+)/merge$ ]]; then
  [[ "$method" == "PUT" ]] || { echo "mock curl: expected PUT for $url" >&2; exit 64; }
  pid="${BASH_REMATCH[1]}"
  iid="${BASH_REMATCH[2]}"
  if [[ -n "${MOCK_TRANSPORT_DEAD_MERGE:-}" ]]; then
    # curl exit 28 (operation timeout): the ladder retries and gives up with 000.
    exit 28
  fi
  if [[ -n "${MOCK_MERGE_HTTP_STATUS:-}" ]]; then
    jq -n '{message:"merge rejected by mock"}' >"$output_file"
    printf '%s' "$MOCK_MERGE_HTTP_STATUS"
    exit 22
  fi
  if grep -qx "${pid}-${iid}" "$MOCK_MERGED_FILE" 2>/dev/null; then
    jq -n '{message:"already merged"}' >"$output_file"
    printf '405'
    exit 22
  fi
  printf '%s\n' "${pid}-${iid}" >>"$MOCK_MERGED_FILE"
  jq -nc --argjson iid "$iid" --argjson pid "$pid" \
    '{iid:$iid,state:"merged",project_id:$pid,target_project_id:$pid,
      source_project_id:$pid,source_branch:"renovate/dep",target_branch:"main",
      sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      draft:false,has_conflicts:false}' >"$output_file"
  printf '200'
  exit 0
fi

if [[ "$url" =~ /projects/([0-9]+)/merge_requests/([0-9]+)$ ]]; then
  pid="${BASH_REMATCH[1]}"
  iid="${BASH_REMATCH[2]}"
  mr_file="$MOCK_CASE_DIR/mrs/${pid}-${iid}.json"
  if [[ -f "$mr_file" ]]; then
    cp "$mr_file" "$output_file"
    exit 0
  fi
  jq -n '{message:"404 not found"}' >"$output_file"
  printf '404'
  exit 22
fi

if [[ "$url" =~ /projects/([0-9]+)/merge_requests$ ]]; then
  pid="${BASH_REMATCH[1]}"
  if [[ -n "${MOCK_FAIL_LIST_PID:-}" && "$pid" == "$MOCK_FAIL_LIST_PID" ]]; then
    jq -n '{message:"404 not found"}' >"$output_file"
    printf '404'
    exit 22
  fi
  list_file="$MOCK_CASE_DIR/lists/${pid}.json"
  if [[ -f "$list_file" ]]; then
    cp "$list_file" "$output_file"
  else
    printf '[]' >"$output_file"
  fi
  exit 0
fi

echo "mock curl: unsupported URL $url" >&2
exit 64
MOCK_CURL
chmod +x "$mock_bin/curl"

# list_entry <iid> <source_branch> <project_id> [source_project_id] [target_branch]:
# one raw GitLab list entry, before the sweep's jq filtering.
list_entry() {
  jq -nc \
    --argjson iid "$1" \
    --arg branch "$2" \
    --argjson pid "$3" \
    --argjson source_pid "${4:-$3}" \
    --arg target "${5:-main}" \
    '{iid:$iid,state:"opened",source_branch:$branch,source_project_id:$source_pid,
      target_branch:$target,title:"chore: dependency update"}'
}

# write_list <case_dir> <project_id> <entry-json>...: the raw list response.
write_list() {
  local case_dir="$1"
  local pid="$2"
  shift 2
  mkdir -p "$case_dir/lists"
  {
    printf '['
    local first=1
    local entry
    for entry in "$@"; do
      ((first)) || printf ','
      first=0
      printf '%s' "$entry"
    done
    printf ']'
  } >"$case_dir/lists/${pid}.json"
}

# write_mr <case_dir> <project_id> <iid> <state> <source_branch>
#          [draft] [conflicts] [mwps] [merge_status] [detailed_merge_status]:
# the merge-request detail response, as the sweep re-reads it per request.
write_mr() {
  local case_dir="$1"
  local pid="$2"
  local iid="$3"
  local state="$4"
  local branch="$5"
  local draft="${6:-false}"
  local conflicts="${7:-false}"
  local mwps="${8:-false}"
  local merge_status="${9:-can_be_merged}"
  local detailed="${10:-mergeable}"
  mkdir -p "$case_dir/mrs"
  jq -nc \
    --argjson pid "$pid" \
    --argjson iid "$iid" \
    --arg state "$state" \
    --arg branch "$branch" \
    --argjson draft "$draft" \
    --argjson conflicts "$conflicts" \
    --argjson mwps "$mwps" \
    --arg merge_status "$merge_status" \
    --arg detailed "$detailed" \
    '{iid:$iid,state:$state,project_id:$pid,target_project_id:$pid,
      source_project_id:$pid,source_branch:$branch,target_branch:"main",
      sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      draft:$draft,has_conflicts:$conflicts,merge_when_pipeline_succeeds:$mwps,
      merge_status:$merge_status,detailed_merge_status:$detailed}' \
    >"$case_dir/mrs/${pid}-${iid}.json"
}

BUILD_LOGIC_PATH="magisk3171/shared/magisk-build-logic"
BUILD_LOGIC_ID="83955125"
TOOLKIT_PATH="magisk3171/shared/magisk-ci-toolkit"
TOOLKIT_ID="83955109"

run_case() {
  local scenario="$1"
  local case_dir="$tmp_root/$scenario"
  mkdir -p "$case_dir/lists" "$case_dir/mrs"
  : >"$case_dir/merged.log"
  : >"$case_dir/sleep.log"

  set +e
  env \
    PATH="$mock_bin:$PATH" \
    MOCK_CASE_DIR="$case_dir" \
    MOCK_MERGED_FILE="$case_dir/merged.log" \
    MOCK_SLEEP_LOG="$case_dir/sleep.log" \
    MOCK_MERGE_HTTP_STATUS="${MOCK_MERGE_HTTP_STATUS:-}" \
    MOCK_TRANSPORT_DEAD_MERGE="${MOCK_TRANSPORT_DEAD_MERGE:-}" \
    MOCK_FAIL_LIST_PID="${MOCK_FAIL_LIST_PID:-}" \
    CI_API_V4_URL="https://gitlab.example/api/v4" \
    CI_PROJECT_ID="${CI_PROJECT_ID_OVERRIDE:-$TOOLKIT_ID}" \
    CI_PROJECT_PATH="${CI_PROJECT_PATH_OVERRIDE:-$TOOLKIT_PATH}" \
    CI_COMMIT_REF_NAME="${CI_COMMIT_REF_NAME_OVERRIDE:-main}" \
    CI_DEFAULT_BRANCH="main" \
    MAGISK_CI_MR_AUTOMERGE_TOKEN="test-token" \
    bash "$reconcile_script" >"$case_dir/output.log" 2>&1
  run_status=$?
  set -e
  printf '%s\n' "$run_status" >"$case_dir/status"
}

expect_status() {
  local case_dir="$1"
  local expected="$2"
  local actual
  actual="$(cat "$case_dir/status")"
  if [[ "$actual" != "$expected" ]]; then
    echo "expected exit ${expected}, got ${actual}" >&2
    cat "$case_dir/output.log" >&2
    exit 1
  fi
}

expect_log() {
  local case_dir="$1"
  local needle="$2"
  if ! grep -F "$needle" "$case_dir/output.log" >/dev/null; then
    echo "expected in log: ${needle}" >&2
    cat "$case_dir/output.log" >&2
    exit 1
  fi
}

refuse_log() {
  local case_dir="$1"
  local needle="$2"
  if grep -F "$needle" "$case_dir/output.log" >/dev/null; then
    echo "must not appear in log: ${needle}" >&2
    cat "$case_dir/output.log" >&2
    exit 1
  fi
}

# A ready request is merged; non-Renovate branches, forks and foreign target
# branches are filtered from the list before any request is read.
case_dir="$tmp_root/merge-ready"
write_list "$case_dir" "$BUILD_LOGIC_ID" \
  "$(list_entry 21 "renovate/firebase.bom" "$BUILD_LOGIC_ID")" \
  "$(list_entry 22 "chore/other" "$BUILD_LOGIC_ID")" \
  "$(list_entry 23 "renovate/forked" "$BUILD_LOGIC_ID" 999)" \
  "$(list_entry 24 "renovate/wrong-target" "$BUILD_LOGIC_ID" "$BUILD_LOGIC_ID" beta)"
write_mr "$case_dir" "$BUILD_LOGIC_ID" 21 opened "renovate/firebase.bom"
run_case merge-ready
expect_status "$case_dir" 0
expect_log "$case_dir" "${BUILD_LOGIC_PATH}: 1 open Renovate merge request(s) targeting main (!21)."
expect_log "$case_dir" "Merged ${BUILD_LOGIC_PATH}!21 at aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa without waiting for pipeline success."
expect_log "$case_dir" "Renovate reconcile sweep complete: 12 projects visited, 1 merged, 0 left for a later sweep."
[[ "$(cat "$case_dir/merged.log")" == "83955125-21" ]] || exit 1

# The post-rebase recheck window: merge_status reads "unchecked" while
# detailed_merge_status already claims "mergeable" (build-logic !21,
# 2026-10-19). The sweep trusts the coarse field, stops before the newer
# request and leaves both for the next sweep 15 minutes later.
case_dir="$tmp_root/not-ready-window"
write_list "$case_dir" "$BUILD_LOGIC_ID" \
  "$(list_entry 31 "renovate/a" "$BUILD_LOGIC_ID")" \
  "$(list_entry 32 "renovate/b" "$BUILD_LOGIC_ID")"
write_mr "$case_dir" "$BUILD_LOGIC_ID" 31 opened "renovate/a" false false false unchecked mergeable
write_mr "$case_dir" "$BUILD_LOGIC_ID" 32 opened "renovate/b"
run_case not-ready-window
expect_status "$case_dir" 0
expect_log "$case_dir" "${BUILD_LOGIC_PATH}!31 is not mergeable yet (merge_status: unchecked, detailed_merge_status: mergeable); the rest of ${BUILD_LOGIC_PATH} waits for a later sweep."
refuse_log "$case_dir" "Merged ${BUILD_LOGIC_PATH}!32"
expect_log "$case_dir" "Renovate reconcile sweep complete: 12 projects visited, 0 merged, 2 left for a later sweep."
[[ -z "$(cat "$case_dir/merged.log")" ]] || exit 1

# Draft, pipeline-gated and concurrently-merged requests are skipped without
# stopping the sweep; the request behind them is still merged.
case_dir="$tmp_root/detail-skip"
write_list "$case_dir" "$TOOLKIT_ID" \
  "$(list_entry 51 "renovate/a" "$TOOLKIT_ID")" \
  "$(list_entry 52 "renovate/b" "$TOOLKIT_ID")" \
  "$(list_entry 53 "renovate/c" "$TOOLKIT_ID")" \
  "$(list_entry 54 "renovate/d" "$TOOLKIT_ID")"
write_mr "$case_dir" "$TOOLKIT_ID" 51 opened "renovate/a" true
write_mr "$case_dir" "$TOOLKIT_ID" 52 opened "renovate/b" false false true
write_mr "$case_dir" "$TOOLKIT_ID" 53 merged "renovate/c"
write_mr "$case_dir" "$TOOLKIT_ID" 54 opened "renovate/d"
run_case detail-skip
expect_status "$case_dir" 0
expect_log "$case_dir" "${TOOLKIT_PATH}!51 is a draft; skipping."
expect_log "$case_dir" "${TOOLKIT_PATH}!52 has a pipeline-gated auto-merge armed; it will merge itself."
expect_log "$case_dir" "${TOOLKIT_PATH}!53 is already merged."
expect_log "$case_dir" "Merged ${TOOLKIT_PATH}!54 at aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa without waiting for pipeline success."
expect_log "$case_dir" "Renovate reconcile sweep complete: 12 projects visited, 2 merged, 0 left for a later sweep."
[[ "$(cat "$case_dir/merged.log")" == "83955109-54" ]] || exit 1

# A conflicting request stops the sweep for its project: everything behind it
# keeps its order and waits for a later sweep.
case_dir="$tmp_root/conflict-stops"
write_list "$case_dir" "$BUILD_LOGIC_ID" \
  "$(list_entry 41 "renovate/a" "$BUILD_LOGIC_ID")" \
  "$(list_entry 42 "renovate/b" "$BUILD_LOGIC_ID")"
write_mr "$case_dir" "$BUILD_LOGIC_ID" 41 opened "renovate/a" false true
write_mr "$case_dir" "$BUILD_LOGIC_ID" 42 opened "renovate/b"
run_case conflict-stops
expect_status "$case_dir" 0
expect_log "$case_dir" "${BUILD_LOGIC_PATH}!41 has conflicts; the rest of ${BUILD_LOGIC_PATH} waits for a later sweep."
refuse_log "$case_dir" "Merged ${BUILD_LOGIC_PATH}!42"
expect_log "$case_dir" "Renovate reconcile sweep complete: 12 projects visited, 0 merged, 2 left for a later sweep."
[[ -z "$(cat "$case_dir/merged.log")" ]] || exit 1

# A token rejection fails loudly: a misconfigured merge token must turn the
# pipeline red instead of silently skipping every request forever.
case_dir="$tmp_root/token-rejected"
write_list "$case_dir" "$BUILD_LOGIC_ID" \
  "$(list_entry 21 "renovate/firebase.bom" "$BUILD_LOGIC_ID")"
write_mr "$case_dir" "$BUILD_LOGIC_ID" 21 opened "renovate/firebase.bom"
MOCK_MERGE_HTTP_STATUS=403 run_case token-rejected
expect_status "$case_dir" 1
expect_log "$case_dir" "MAGISK_CI_MR_AUTOMERGE_TOKEN cannot merge ${BUILD_LOGIC_PATH}!21 (HTTP 403: merge rejected by mock)"

# A dead transport on the merge PUT is absorbed by the retry ladder and then
# left for the next sweep; the sweep itself stays green.
case_dir="$tmp_root/transport-dead"
write_list "$case_dir" "$BUILD_LOGIC_ID" \
  "$(list_entry 21 "renovate/firebase.bom" "$BUILD_LOGIC_ID")"
write_mr "$case_dir" "$BUILD_LOGIC_ID" 21 opened "renovate/firebase.bom"
MOCK_TRANSPORT_DEAD_MERGE=1 run_case transport-dead
expect_status "$case_dir" 0
expect_log "$case_dir" "Transient failure calling"
expect_log "$case_dir" "kept failing at the transport level; the rest of ${BUILD_LOGIC_PATH} waits for a later sweep"
expect_log "$case_dir" "Renovate reconcile sweep complete: 12 projects visited, 0 merged, 1 left for a later sweep."
[[ -s "$case_dir/sleep.log" ]] || {
  echo "the retry ladder must have backed off between attempts" >&2
  exit 1
}
[[ -z "$(cat "$case_dir/merged.log")" ]] || exit 1

# A failing list response skips only that project and never fails the sweep.
case_dir="$tmp_root/list-failure"
MOCK_FAIL_LIST_PID="$BUILD_LOGIC_ID" run_case list-failure
expect_status "$case_dir" 0
expect_log "$case_dir" "failed to list open merge requests for ${BUILD_LOGIC_PATH}; skipping it in this sweep"
expect_log "$case_dir" "Renovate reconcile sweep complete: 12 projects visited, 0 merged, 0 left for a later sweep."

# Guards: the sweep must run on the toolkit's protected default branch, where
# the merge token is available.
case_dir="$tmp_root/default-branch-guard"
CI_COMMIT_REF_NAME_OVERRIDE=beta run_case default-branch-guard
expect_status "$case_dir" 1
expect_log "$case_dir" "reconcile must run on the default branch"

case_dir="$tmp_root/wrong-project-guard"
CI_PROJECT_ID_OVERRIDE=83955143 run_case wrong-project-guard
expect_status "$case_dir" 1
expect_log "$case_dir" "this script only runs in the toolkit project"

echo "reconcile sweep tests passed"
