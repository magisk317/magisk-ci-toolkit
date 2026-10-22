#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
loop_script="$(cd "$script_dir/.." && pwd)/renovate_serial_loop.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf -- "$tmp_root"' EXIT

mock_bin="$tmp_root/bin"
mkdir -p "$mock_bin"

cat >"$mock_bin/renovate" <<'MOCK_RENOVATE'
#!/usr/bin/env bash
set -euo pipefail
count="$(cat "$MOCK_RENOVATE_COUNT_FILE")"
count=$((count + 1))
printf '%s\n' "$count" >"$MOCK_RENOVATE_COUNT_FILE"
case "$MOCK_SCENARIO:$count" in
  two-rounds:1 | locked-race:1)
    printf '%s\n' "open" >"$MOCK_STATE_FILE"
    ;;
  two-rounds:2 | locked-race:2)
    printf '%s\n' "done" >"$MOCK_STATE_FILE"
    ;;
  already-merged:1)
    printf '%s\n' "done" >"$MOCK_STATE_FILE"
    ;;
  backlog-after-scan:1)
    printf '%s\n' "backlog" >"$MOCK_STATE_FILE"
    ;;
  backlog-after-scan:2)
    printf '%s\n' "done" >"$MOCK_STATE_FILE"
    ;;
  backlog-before-round:1 | backlog-partial:1 | locked-backlog:1)
    printf '%s\n' "done" >"$MOCK_STATE_FILE"
    ;;
  *)
    :
    ;;
esac
MOCK_RENOVATE
chmod +x "$mock_bin/renovate"

cat >"$mock_bin/git" <<'MOCK_GIT'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  fetch | checkout) exit 0 ;;
  rev-parse)
    if [[ "$(cat "$MOCK_STATE_FILE")" == "done" || "$(cat "$MOCK_STATE_FILE")" == "merged" ]]; then
      printf '%s\n' "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    else
      printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    fi
    ;;
  *) echo "mock git: unsupported argument $1" >&2; exit 64 ;;
esac
MOCK_GIT
chmod +x "$mock_bin/git"

cat >"$mock_bin/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"$MOCK_SLEEP_LOG"
MOCK_SLEEP
chmod +x "$mock_bin/sleep"

cat >"$mock_bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail

# Commit model. aaa... is the target branch tip before this run merges, bbb...
# the merge commit that lands on it, ccc... a Renovate request HEAD (branched
# off aaa, so it contains the tip - until MOCK_BEHIND=1 moves main forward by
# eee...), ddd... the same request after the rebase landed, eee... the commit
# that reached the target branch while the request sat open.
readonly BASE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
readonly MERGE_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
readonly MR_SHA="${MOCK_MR_SHA:-cccccccccccccccccccccccccccccccccccccccc}"
readonly MR_REBASED_SHA="${MOCK_REBASED_SHA:-dddddddddddddddddddddddddddddddddddddddd}"
readonly NEW_TARGET_SHA="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

# The request HEAD the mock reports: the rebased one once a rebase has been
# served, the original one before that.
mr_is_rebased() { [[ -n "${MOCK_REBASED_FILE:-}" && -e "$MOCK_REBASED_FILE" ]]; }
mr_head_sha() {
  if mr_is_rebased; then
    printf '%s' "$MR_REBASED_SHA"
  else
    printf '%s' "$MR_SHA"
  fi
}

# Merge-request body helpers. A behind request keeps reporting the reassuring
# merge_status/detailed_merge_status pair, which is exactly the trap: neither
# field says the fast-forward merge will be refused.
mr_opened_json() {
  jq -nc \
    --argjson iid "$1" \
    --arg branch "$2" \
    --argjson conflicts "$3" \
    --arg sha "$(mr_head_sha)" \
    '{iid:$iid,state:"opened",source_project_id:123,source_branch:$branch,
      target_branch:"beta",sha:$sha,
      draft:false,has_conflicts:$conflicts,merge_when_pipeline_succeeds:false,
      rebase_in_progress:false,merge_error:null,
      merge_status:(if $conflicts then "cannot_be_merged" else "can_be_merged" end),
      detailed_merge_status:(if $conflicts then "conflicts" else "mergeable" end)}'
}

# GitLab reports "locked" while a merge is being processed; every consumer of
# an MR response must treat it as transient.
mr_locked_json() {
  jq -nc --argjson iid "$1" --arg sha "$(mr_head_sha)" '{iid:$iid,state:"locked",source_project_id:123,source_branch:("renovate/dep-"+($iid|tostring)),target_branch:"beta",sha:$sha,draft:false,has_conflicts:false,merge_when_pipeline_succeeds:false}'
}

mr_merged_json() {
  jq -nc \
    --argjson iid "$1" \
    --arg sha "$(mr_head_sha)" \
    --arg merge_sha "$MERGE_SHA" \
    '{iid:$iid,state:"merged",source_project_id:123,
      source_branch:("renovate/dep-"+($iid|tostring)),target_branch:"beta",
      sha:$sha,merge_commit_sha:$merge_sha}'
}

output_file=""
method="GET"
url=""
requested_state=""
write_out=""
merge_sha=""
compare_from=""
skip_ci=""
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
        state=*) requested_state="${2#state=}" ;;
        sha=*) merge_sha="${2#sha=}" ;;
        from=*) compare_from="${2#from=}" ;;
        skip_ci=*) skip_ci="${2#skip_ci=}" ;;
      esac
      shift 2
      ;;
    --header)
      shift 2
      ;;
    --write-out)
      write_out="$2"
      shift 2
      ;;
    --get | --fail | --silent | --show-error | --location)
      shift
      ;;
    # Transient-error retry flags: the mock never fails transiently, so it
    # only has to accept them (values discarded).
    --retry | --retry-delay | --retry-max-time)
      shift 2
      ;;
    --retry-connrefused)
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

if [[ "$method" == "PUT" ]]; then
  iid="${url##*/merge_requests/}"
  iid="${iid%%/*}"

  if [[ "$url" == */rebase ]]; then
    [[ "${MOCK_BEHIND:-}" == "1" ]] || { echo "mock curl: unexpected rebase in this scenario" >&2; exit 64; }
    # Rewriting a Renovate branch must not queue a second pipeline for it.
    [[ "$skip_ci" == "true" ]] || { echo "mock curl: rebase must pass skip_ci=true" >&2; exit 64; }
    if [[ -n "${MOCK_REBASE_HTTP_STATUS:-}" ]]; then
      jq -n '{message:"rebase rejected by mock"}' >"$output_file"
      printf '%s' "$MOCK_REBASE_HTTP_STATUS"
      exit 0
    fi
    : >"${MOCK_REBASED_FILE:?MOCK_REBASED_FILE is required to serve a rebase}"
    jq -n '{rebase_in_progress:true,merge_error:null}' >"$output_file"
    printf '202'
    exit 0
  fi

  [[ "$url" == */merge ]] || { echo "mock curl: unsupported PUT URL $url" >&2; exit 64; }
  if [[ -n "${MOCK_MERGE_HTTP_STATUS:-}" ]]; then
    jq -n '{message:"merge rejected by mock"}' >"$output_file"
    printf '%s' "$MOCK_MERGE_HTTP_STATUS"
    exit 0
  fi
  if [[ "${MOCK_BEHIND:-}" == "1" ]] && ! mr_is_rebased; then
    # merge_method=ff refuses a request that does not already contain the
    # target tip. The refusal is a 422 no status field predicts, and it only
    # clears when the rebase moves the branch: this is the whole point of the
    # scenario, so a merge PUT issued against the un-rebased HEAD must fail.
    jq -n '{message:"Branch cannot be merged"}' >"$output_file"
    printf '422'
    exit 0
  fi
  if [[ "${MOCK_BEHIND:-}" == "1" && "$merge_sha" != "$(mr_head_sha)" ]]; then
    # The sha-pinned PUT must name the moved HEAD; the pre-rebase commit is
    # gone, and merging it anyway would silently drop the rebase.
    jq -n '{message:"Branch cannot be merged"}' >"$output_file"
    printf '409'
    exit 0
  fi
  if grep -qx "$iid" "$MOCK_MERGED_FILE" 2>/dev/null; then
    jq -n '{message:"already merged"}' >"$output_file"
    printf '405'
    exit 0
  fi
  printf '%s\n' "$iid" >>"$MOCK_MERGED_FILE"
  if [[ "$(cat "$MOCK_STATE_FILE")" == "backlog" ]] \
    && grep -qx 101 "$MOCK_MERGED_FILE" && grep -qx 102 "$MOCK_MERGED_FILE"; then
    printf '%s\n' "merged" >"$MOCK_STATE_FILE"
  fi
  # A direct merge (the wait-timeout fallback) lands the merge commit on the
  # target branch: model the branch moving forward for the waiting states.
  if [[ "$(cat "$MOCK_STATE_FILE")" == "open" || "$(cat "$MOCK_STATE_FILE")" == "stuck" ]]; then
    printf '%s\n' "merged" >"$MOCK_STATE_FILE"
  fi
  mr_merged_json "$iid" >"$output_file"
  printf '200'
  exit 0
fi

[[ "$method" == "GET" && -n "$output_file" ]] || {
  echo "mock curl: expected GET with output file" >&2
  exit 64
}

state="$(cat "$MOCK_STATE_FILE")"
if [[ "$url" == */repository/branches/* ]]; then
  if [[ "$state" == "done" || "$state" == "merged" ]]; then
    sha="$MERGE_SHA"
  else
    sha="$BASE_SHA"
  fi
  jq -n --arg sha "$sha" '{commit:{id:$sha}}' >"$output_file"
  exit 0
fi

if [[ "$url" == */repository/commits ]]; then
  jq -n --arg sha "$MERGE_SHA" '[{id:$sha}]' >"$output_file"
  exit 0
fi

if [[ "$url" == */repository/compare ]]; then
  if [[ "$compare_from" == "$(mr_head_sha)" ]]; then
    # The loop asking what the request HEAD still lacks from the target branch,
    # the only read that can see a fast-forward refusal coming.
    if [[ "${MOCK_BEHIND:-}" == "1" ]] && ! mr_is_rebased; then
      jq -n --arg sha "$NEW_TARGET_SHA" '{compare_timeout:false,commits:[{id:$sha}]}' >"$output_file"
    else
      jq -n '{compare_timeout:false,commits:[]}' >"$output_file"
    fi
  else
    # The loop confirming a merge commit reached the target branch.
    jq -n --arg sha "$MERGE_SHA" '{compare_timeout:false,commits:[{id:$sha}]}' >"$output_file"
  fi
  exit 0
fi

if [[ "$url" == */merge_requests && "$requested_state" == "opened" ]]; then
  if [[ "$state" == "open" || "$state" == "stuck" ]]; then
    printf '[%s]' "$(mr_opened_json 101 "renovate/agp" false)" >"$output_file"
  elif [[ "$state" == "backlog" ]]; then
    # Backlog set {!101, !102}; entries already merged by the drain drop out.
    entries=()
    for iid in 102 101; do
      grep -qx "$iid" "$MOCK_MERGED_FILE" 2>/dev/null || entries+=("$iid")
    done
    {
      printf '['
      first=1
      for iid in ${entries[@]+"${entries[@]}"}; do
        ((first)) || printf ','
        first=0
        conflicts=false
        [[ "$iid" == "${MOCK_CONFLICT_IID:-}" ]] && conflicts=true
        mr_opened_json "$iid" "renovate/dep-${iid}" "$conflicts"
      done
      printf ']'
    } >"$output_file"
  else
    jq -n '[]' >"$output_file"
  fi
  exit 0
fi

if [[ "$url" == */merge_requests && "$requested_state" == "merged" ]]; then
  if [[ -s "$MOCK_MERGED_FILE" ]]; then
    {
      printf '['
      first=1
      while IFS= read -r iid; do
        [[ -n "$iid" ]] || continue
        ((first)) || printf ','
        first=0
        mr_merged_json "$iid"
      done <"$MOCK_MERGED_FILE"
      printf ']'
    } >"$output_file"
  elif [[ "$state" == "done" || "$state" == "merged" ]]; then
    jq -n '[{iid:101,state:"merged",source_project_id:123,source_branch:"renovate/agp",target_branch:"beta",merge_commit_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]' >"$output_file"
  else
    jq -n '[]' >"$output_file"
  fi
  exit 0
fi

if [[ "$url" =~ /merge_requests/([0-9]+)$ ]]; then
  iid="${BASH_REMATCH[1]}"
  if grep -qx "$iid" "$MOCK_MERGED_FILE" 2>/dev/null; then
    mr_merged_json "$iid" >"$output_file"
    exit 0
  fi

  # Locked interception: MOCK_LOCKED_IID selects the request, MOCK_LOCKED_ONCE
  # serves the lock exactly once (the marker file disarms it); without ONCE the
  # lock persists for the whole run (timeout scenario).
  lock_marker="${MOCK_LOCK_MARKER:-${MOCK_STATE_FILE:-.}/.lock-marker}"
  if [[ -n "${MOCK_LOCKED_IID:-}" && "$iid" == "$MOCK_LOCKED_IID" ]]; then
    if [[ "${MOCK_LOCKED_ONCE:-}" != "1" || ! -e "$lock_marker" ]]; then
      if [[ "${MOCK_LOCKED_ONCE:-}" == "1" && ! -e "$lock_marker" ]]; then
        : >"$lock_marker"
      fi
      mr_locked_json "$iid" >"$output_file"
      exit 0
    fi
  fi

  if [[ "$state" == "backlog" ]]; then
    # In a backlog the open/merged state of {!101, !102} is owned by the
    # drain: opened until the merge PUT lands in the merged log.
    conflicts=false
    [[ "$iid" == "${MOCK_CONFLICT_IID:-}" ]] && conflicts=true
    mr_opened_json "$iid" "renovate/dep-${iid}" "$conflicts" >"$output_file"
    exit 0
  fi
  if [[ "$state" == "stuck" ]]; then
    # The controller never merged (a dead bridge or job): every read reports
    # the request still open, which is the wait-timeout fallback scenario.
    conflicts=false
    [[ "$iid" == "${MOCK_CONFLICT_IID:-}" ]] && conflicts=true
    mr_opened_json "$iid" "renovate/dep-${iid}" "$conflicts" >"$output_file"
    exit 0
  fi
  if [[ "$iid" == "101" ]]; then
    # Reading !101 while the scan produced it transitions the target branch.
    if [[ "$state" == "open" ]]; then
      printf '%s\n' "merged" >"$MOCK_STATE_FILE"
    fi
    mr_merged_json "$iid" >"$output_file"
    exit 0
  fi
  conflicts=false
  [[ "$iid" == "${MOCK_CONFLICT_IID:-}" ]] && conflicts=true
  mr_opened_json "$iid" "renovate/dep-${iid}" "$conflicts" >"$output_file"
  exit 0
fi

if [[ "$url" == */merge_requests ]]; then
  jq -n '[]' >"$output_file"
  exit 0
fi

echo "mock curl: unsupported URL $url" >&2
exit 64
MOCK_CURL
chmod +x "$mock_bin/curl"

run_case() {
  local scenario="$1"
  local case_dir="$tmp_root/$scenario"
  mkdir -p "$case_dir/project"
  printf '%s\n' "${2:-none}" >"$case_dir/state"
  printf '0\n' >"$case_dir/renovate-count"
  : >"$case_dir/merged.log"
  : >"$case_dir/sleep.log"

  set +e
  env \
    PATH="$mock_bin:$PATH" \
    MOCK_SCENARIO="$scenario" \
    MOCK_STATE_FILE="$case_dir/state" \
    MOCK_RENOVATE_COUNT_FILE="$case_dir/renovate-count" \
    MOCK_MERGED_FILE="$case_dir/merged.log" \
    MOCK_SLEEP_LOG="$case_dir/sleep.log" \
    MOCK_CONFLICT_IID="${MOCK_CONFLICT_IID:-}" \
    MOCK_MERGE_HTTP_STATUS="${MOCK_MERGE_HTTP_STATUS:-}" \
    MOCK_LOCKED_IID="${MOCK_LOCKED_IID:-}" \
    MOCK_LOCKED_ONCE="${MOCK_LOCKED_ONCE:-}" \
    MOCK_LOCK_MARKER="$case_dir/lock-marker" \
    MOCK_BEHIND="${MOCK_BEHIND:-}" \
    MOCK_REBASED_FILE="$case_dir/rebased" \
    MOCK_REBASE_HTTP_STATUS="${MOCK_REBASE_HTTP_STATUS:-}" \
    CI_API_V4_URL="https://gitlab.example/api/v4" \
    CI_PROJECT_ID="123" \
    CI_PROJECT_DIR="$case_dir/project" \
    CI_COMMIT_REF_NAME="beta" \
    CI_DEFAULT_BRANCH="beta" \
    CI_PIPELINE_SOURCE="schedule" \
    RENOVATE_TOKEN="test-token" \
    MAGISK_CANCEL_OLDER_MR_PIPELINES="true" \
    MAGISK_RENOVATE_MR_POLL_INTERVAL_SECONDS="0" \
    MAGISK_RENOVATE_MR_MAX_POLLS="4" \
    MAGISK_RENOVATE_NO_MR_GRACE_POLLS="2" \
    MAGISK_RENOVATE_MAX_ROUNDS="2" \
    MAGISK_RENOVATE_MERGE_ATTEMPTS="${MAGISK_RENOVATE_MERGE_ATTEMPTS:-2}" \
    MAGISK_RENOVATE_MERGE_DELAY_SECONDS="${MAGISK_RENOVATE_MERGE_DELAY_SECONDS:-0}" \
    MAGISK_RENOVATE_BACKLOG_MERGE="${MAGISK_RENOVATE_BACKLOG_MERGE:-true}" \
    MAGISK_RENOVATE_AUTOREBASE="${MAGISK_RENOVATE_AUTOREBASE:-true}" \
    bash "$loop_script" >"$case_dir/output.log" 2>&1
  run_status=$?
  set -e
  printf '%s\n' "$run_status" >"$case_dir/status"
}

run_case two-rounds none
[[ "$(cat "$tmp_root/two-rounds/status")" == "0" ]] || {
  cat "$tmp_root/two-rounds/output.log" >&2
  exit 1
}
[[ "$(cat "$tmp_root/two-rounds/renovate-count")" == "2" ]] || exit 1
grep -F "Starting Renovate serial round 1/2" "$tmp_root/two-rounds/output.log" >/dev/null
grep -F "Starting Renovate serial round 2/2" "$tmp_root/two-rounds/output.log" >/dev/null

run_case already-merged none
[[ "$(cat "$tmp_root/already-merged/status")" == "0" ]] || {
  cat "$tmp_root/already-merged/output.log" >&2
  exit 1
}
[[ "$(cat "$tmp_root/already-merged/renovate-count")" == "2" ]] || exit 1
grep -F "Detected already-merged Renovate merge request !101" "$tmp_root/already-merged/output.log" >/dev/null

run_case existing open
[[ "$(cat "$tmp_root/existing/renovate-count")" == "1" ]] || exit 1

# Backlog before the round: the loop merges the extra Renovate requests itself
# (oldest first) and continues with the round instead of failing.
run_case backlog-before-round backlog
[[ "$(cat "$tmp_root/backlog-before-round/status")" == "0" ]] || {
  cat "$tmp_root/backlog-before-round/output.log" >&2
  exit 1
}
grep -F "Renovate backlog detected: 2 open Renovate merge requests (!102, !101) targeting beta; merging them directly before continuing." "$tmp_root/backlog-before-round/output.log" >/dev/null
grep -F "Merged Renovate merge request !101 at cccccccccccccccccccccccccccccccccccccccc" "$tmp_root/backlog-before-round/output.log" >/dev/null
grep -F "Merged Renovate merge request !102 at cccccccccccccccccccccccccccccccccccccccc" "$tmp_root/backlog-before-round/output.log" >/dev/null
grep -F "Starting Renovate serial round 1/2" "$tmp_root/backlog-before-round/output.log" >/dev/null
[[ "$(cat "$tmp_root/backlog-before-round/renovate-count")" == "2" ]] || exit 1
grep -Fx "101" "$tmp_root/backlog-before-round/merged.log" >/dev/null
grep -Fx "102" "$tmp_root/backlog-before-round/merged.log" >/dev/null

# Backlog after the scan: Renovate itself produced two open requests; the drain
# runs inside wait_for_scan_result and the round completes normally.
run_case backlog-after-scan none
[[ "$(cat "$tmp_root/backlog-after-scan/status")" == "0" ]] || {
  cat "$tmp_root/backlog-after-scan/output.log" >&2
  exit 1
}
grep -F "Renovate backlog detected: 2 open Renovate merge requests (!102, !101)" "$tmp_root/backlog-after-scan/output.log" >/dev/null
grep -F "Merged Renovate merge request !101 at cccccccccccccccccccccccccccccccccccccccc" "$tmp_root/backlog-after-scan/output.log" >/dev/null
grep -F "Merged Renovate merge request !102 at cccccccccccccccccccccccccccccccccccccccc" "$tmp_root/backlog-after-scan/output.log" >/dev/null
grep -F "Detected already-merged Renovate merge request !101" "$tmp_root/backlog-after-scan/output.log" >/dev/null

# A rejected merge (no merge permission) fails loudly with an actionable
# message instead of silently leaving the backlog in place.
MOCK_MERGE_HTTP_STATUS=403 run_case backlog-merge-rejected backlog
[[ "$(cat "$tmp_root/backlog-merge-rejected/status")" == "1" ]] || {
  cat "$tmp_root/backlog-merge-rejected/output.log" >&2
  exit 1
}
grep -F "RENOVATE_TOKEN cannot merge !101 (HTTP 403: merge rejected by mock)" "$tmp_root/backlog-merge-rejected/output.log" >/dev/null

# The strict behaviour is restorable per repository.
MAGISK_RENOVATE_BACKLOG_MERGE=false run_case backlog-merge-disabled backlog
[[ "$(cat "$tmp_root/backlog-merge-disabled/status")" == "1" ]] || {
  cat "$tmp_root/backlog-merge-disabled/output.log" >&2
  exit 1
}
grep -F "more than one open Renovate merge request exists before round 1" "$tmp_root/backlog-merge-disabled/output.log" >/dev/null

# A conflicting request cannot be drained; it stays open and the loop falls
# back to the single-request wait, which eventually times out, attempts one
# direct merge (skipped again for the conflict) and fails with the reason.
MOCK_CONFLICT_IID=102 run_case backlog-partial backlog
[[ "$(cat "$tmp_root/backlog-partial/status")" == "1" ]] || {
  cat "$tmp_root/backlog-partial/output.log" >&2
  exit 1
}
grep -F "Renovate merge request !102 has conflicts; backlog merge is skipped." "$tmp_root/backlog-partial/output.log" >/dev/null
grep -F "Continuing with existing Renovate merge request !102." "$tmp_root/backlog-partial/output.log" >/dev/null
grep -F "Warning: Renovate merge request !102 was not merged within 4 polls; attempting a direct merge." "$tmp_root/backlog-partial/output.log" >/dev/null
grep -F "Renovate merge request !102 was not merged into beta after 4 polls and a direct merge attempt (merge_status: cannot_be_merged, detailed_merge_status: conflicts)" "$tmp_root/backlog-partial/output.log" >/dev/null
grep -Fx "101" "$tmp_root/backlog-partial/merged.log" >/dev/null

# A merge request locked mid-merge is a transient GitLab state (the
# controller merge, or this loop's own PUT, is being processed): the wait must
# keep polling instead of failing. Regression for 2026-09-29 !178, where the
# controller merge landed one second after the loop's poll had already died on
# "unsupported state locked" and failed the whole schedule pipeline.
MOCK_LOCKED_IID=101 MOCK_LOCKED_ONCE=1 run_case locked-race none
[[ "$(cat "$tmp_root/locked-race/status")" == "0" ]] || {
  cat "$tmp_root/locked-race/output.log" >&2
  exit 1
}
grep -F "Merge request !101 is locked (a merge is in progress); waiting (1/4)" "$tmp_root/locked-race/output.log" >/dev/null
grep -F "Confirmed Renovate merge request !101 is included in beta" "$tmp_root/locked-race/output.log" >/dev/null
[[ "$(cat "$tmp_root/locked-race/renovate-count")" == "2" ]] || exit 1

# The same transient lock inside the backlog drain: merge_renovate_mr must fall
# through to its sha-pinned PUT (405/already-merged counts as done), not fail.
MOCK_LOCKED_IID=101 MOCK_LOCKED_ONCE=1 run_case locked-backlog backlog
[[ "$(cat "$tmp_root/locked-backlog/status")" == "0" ]] || {
  cat "$tmp_root/locked-backlog/output.log" >&2
  exit 1
}
grep -F "Renovate merge request !101 is locked (a merge is in progress); retrying the merge." "$tmp_root/locked-backlog/output.log" >/dev/null
grep -F "Merged Renovate merge request !101 at cccccccccccccccccccccccccccccccccccccccc" "$tmp_root/locked-backlog/output.log" >/dev/null
grep -F "Starting Renovate serial round 1/2" "$tmp_root/locked-backlog/output.log" >/dev/null
[[ "$(cat "$tmp_root/locked-backlog/renovate-count")" == "2" ]] || exit 1

# A request locked for the whole poll window no longer terminates the loop:
# the wait times out, the fallback drains the request directly (its sha-pinned
# PUT wins or answers 405 against the concurrent controller merge) and the
# round completes. Regression for 2026-10-19, where a controller that never
# merged cost the whole schedule run.
MOCK_LOCKED_IID=101 run_case locked-timeout-drain open
[[ "$(cat "$tmp_root/locked-timeout-drain/status")" == "0" ]] || {
  cat "$tmp_root/locked-timeout-drain/output.log" >&2
  exit 1
}
grep -F "Merge request !101 is locked (a merge is in progress); waiting (1/4)" "$tmp_root/locked-timeout-drain/output.log" >/dev/null
grep -F "Warning: Renovate merge request !101 was not merged within 4 polls; attempting a direct merge." "$tmp_root/locked-timeout-drain/output.log" >/dev/null
grep -F "Renovate merge request !101 is locked (a merge is in progress); retrying the merge." "$tmp_root/locked-timeout-drain/output.log" >/dev/null
grep -F "Merged Renovate merge request !101 at cccccccccccccccccccccccccccccccccccccccc" "$tmp_root/locked-timeout-drain/output.log" >/dev/null
grep -F "Confirmed Renovate merge request !101 is included in beta" "$tmp_root/locked-timeout-drain/output.log" >/dev/null
grep -F "Starting Renovate serial round 2/2" "$tmp_root/locked-timeout-drain/output.log" >/dev/null
[[ "$(cat "$tmp_root/locked-timeout-drain/renovate-count")" == "1" ]] || exit 1
if grep -F "unsupported state locked" "$tmp_root/locked-timeout-drain/output.log" >/dev/null; then
  echo "a locked request must not be reported as an unsupported state" >&2
  exit 1
fi

# The fallback drain is the last resort: a single request the controller never
# merged (dead bridge, dead controller job) is merged directly and the round
# continues instead of burning the whole schedule run.
run_case controller-dead stuck
[[ "$(cat "$tmp_root/controller-dead/status")" == "0" ]] || {
  cat "$tmp_root/controller-dead/output.log" >&2
  exit 1
}
grep -F "Continuing with existing Renovate merge request !101." "$tmp_root/controller-dead/output.log" >/dev/null
grep -F "Warning: Renovate merge request !101 was not merged within 4 polls; attempting a direct merge." "$tmp_root/controller-dead/output.log" >/dev/null
grep -F "Merged Renovate merge request !101 at cccccccccccccccccccccccccccccccccccccccc" "$tmp_root/controller-dead/output.log" >/dev/null
grep -F "Confirmed Renovate merge request !101 is included in beta" "$tmp_root/controller-dead/output.log" >/dev/null
grep -F "Starting Renovate serial round 2/2" "$tmp_root/controller-dead/output.log" >/dev/null
[[ "$(cat "$tmp_root/controller-dead/renovate-count")" == "1" ]] || exit 1
grep -Fx "101" "$tmp_root/controller-dead/merged.log" >/dev/null

# When the direct merge cannot land either - GitLab's post-rebase
# merge_status recheck window answers 422 to every PUT (build-logic !21,
# 2026-10-19) - the loop fails, but the reason now reports both status fields
# instead of the misleading detailed_merge_status alone.
MOCK_MERGE_HTTP_STATUS=422 run_case controller-dead-still-stuck stuck
[[ "$(cat "$tmp_root/controller-dead-still-stuck/status")" == "1" ]] || {
  cat "$tmp_root/controller-dead-still-stuck/output.log" >&2
  exit 1
}
grep -F "Merge attempt 1/2 for !101 returned HTTP 422: merge rejected by mock" "$tmp_root/controller-dead-still-stuck/output.log" >/dev/null
grep -F "Warning: merge request !101 did not become mergeable after 2 attempts; it stays in the backlog." "$tmp_root/controller-dead-still-stuck/output.log" >/dev/null
grep -F "Renovate merge request !101 was not merged into beta after 4 polls and a direct merge attempt (merge_status: can_be_merged, detailed_merge_status: mergeable)" "$tmp_root/controller-dead-still-stuck/output.log" >/dev/null
[[ "$(cat "$tmp_root/controller-dead-still-stuck/renovate-count")" == "0" ]] || exit 1

# The structural half of the !21 failure class (2026-10-19..22): with
# merge_method=ff a request that fell behind the target branch can never merge,
# and neither merge_status nor detailed_merge_status says so - the mock reports
# the same reassuring pair here. Before the fix every one of these runs re-fired
# the identical PUT until the ladder ran out; now the loop measures behindness
# against the target branch and fast-forwards the request through the rebase
# endpoint, then merges the moved HEAD.
MOCK_BEHIND=1 run_case backlog-behind backlog
[[ "$(cat "$tmp_root/backlog-behind/status")" == "0" ]] || {
  cat "$tmp_root/backlog-behind/output.log" >&2
  exit 1
}
grep -F "Renovate merge request !101 is behind beta; rebasing it before merging (1/2)." "$tmp_root/backlog-behind/output.log" >/dev/null
grep -F "Rebased Renovate merge request !101 onto beta at dddddddddddddddddddddddddddddddddddddddd" "$tmp_root/backlog-behind/output.log" >/dev/null
grep -F "Merged Renovate merge request !101 at dddddddddddddddddddddddddddddddddddddddd" "$tmp_root/backlog-behind/output.log" >/dev/null
grep -F "Merged Renovate merge request !102 at dddddddddddddddddddddddddddddddddddddddd" "$tmp_root/backlog-behind/output.log" >/dev/null
grep -Fx "101" "$tmp_root/backlog-behind/merged.log" >/dev/null
grep -Fx "102" "$tmp_root/backlog-behind/merged.log" >/dev/null
# The mock moves both branches with one rebase marker, so !102 is already
# up to date; a second rebase in the same run would mean the loop did not
# re-read the moved HEAD.
if grep -F "rebasing it before merging (2/2)" "$tmp_root/backlog-behind/output.log" >/dev/null; then
  echo "a rebased request must be merged without rebasing again" >&2
  exit 1
fi
if grep -F "did not become mergeable" "$tmp_root/backlog-behind/output.log" >/dev/null; then
  echo "a behind request must be rebased and merged, not left in the backlog" >&2
  exit 1
fi

# The same behind request reached through the wait-timeout fallback instead of a
# backlog: one dead controller plus one busy default branch must still not cost
# the schedule run.
MOCK_BEHIND=1 run_case controller-dead-behind stuck
[[ "$(cat "$tmp_root/controller-dead-behind/status")" == "0" ]] || {
  cat "$tmp_root/controller-dead-behind/output.log" >&2
  exit 1
}
grep -F "Warning: Renovate merge request !101 was not merged within 4 polls; attempting a direct merge." "$tmp_root/controller-dead-behind/output.log" >/dev/null
grep -F "Renovate merge request !101 is behind beta; rebasing it before merging (1/2)." "$tmp_root/controller-dead-behind/output.log" >/dev/null
grep -F "Merged Renovate merge request !101 at dddddddddddddddddddddddddddddddddddddddd" "$tmp_root/controller-dead-behind/output.log" >/dev/null
grep -F "Confirmed Renovate merge request !101 is included in beta." "$tmp_root/controller-dead-behind/output.log" >/dev/null
[[ "$(cat "$tmp_root/controller-dead-behind/renovate-count")" == "1" ]] || exit 1
grep -Fx "101" "$tmp_root/controller-dead-behind/merged.log" >/dev/null

# The escape hatch keeps the old behaviour restorable, and the old failure is
# still reported with GitLab's own refusal so the reason stays findable.
MOCK_BEHIND=1 MAGISK_RENOVATE_AUTOREBASE=false run_case behind-without-rebase stuck
[[ "$(cat "$tmp_root/behind-without-rebase/status")" == "1" ]] || {
  cat "$tmp_root/behind-without-rebase/output.log" >&2
  exit 1
}
grep -F "Merge attempt 1/2 for !101 returned HTTP 422: Branch cannot be merged" "$tmp_root/behind-without-rebase/output.log" >/dev/null
grep -F "Warning: merge request !101 did not become mergeable after 2 attempts; it stays in the backlog." "$tmp_root/behind-without-rebase/output.log" >/dev/null
grep -F "was not merged into beta after 4 polls and a direct merge attempt (merge_status: can_be_merged, detailed_merge_status: mergeable)" "$tmp_root/behind-without-rebase/output.log" >/dev/null
if grep -F "rebasing it before merging" "$tmp_root/behind-without-rebase/output.log" >/dev/null; then
  echo "MAGISK_RENOVATE_AUTOREBASE=false must not rebase" >&2
  exit 1
fi

# A rebase GitLab refuses for a reason that cannot change (HTTP 403: the token
# cannot push to the source branch) must not become a rebase loop: the merge
# attempt proceeds with the unchanged HEAD and the run fails as it did before.
MOCK_BEHIND=1 MOCK_REBASE_HTTP_STATUS=403 run_case behind-rebase-refused stuck
[[ "$(cat "$tmp_root/behind-rebase-refused/status")" == "1" ]] || {
  cat "$tmp_root/behind-rebase-refused/output.log" >&2
  exit 1
}
grep -F "Rebase request for !101 returned HTTP 403: rebase rejected by mock; no further rebase will be attempted." "$tmp_root/behind-rebase-refused/output.log" >/dev/null
grep -F "Merge attempt 1/2 for !101 returned HTTP 422: Branch cannot be merged" "$tmp_root/behind-rebase-refused/output.log" >/dev/null
if grep -F "rebasing it before merging (2/2)" "$tmp_root/behind-rebase-refused/output.log" >/dev/null; then
  echo "a permanently refused rebase must not be retried" >&2
  exit 1
fi

# api_curl must arm curl's transient-error retry. GitLab answers 503 while a
# rate-limit window is active, and one such reply used to abort the whole run
# (and with it the consumer sync in the next stage). curl performs the retries
# itself and only for 5xx/429 plus connection errors, so the contract asserted
# here is the flags - a mocked failure sequence would only test the mock.
grep -F -- '--retry "' "$loop_script" >/dev/null || {
  echo "api_curl must pass --retry to curl" >&2
  exit 1
}
grep -F -- "--retry-connrefused" "$loop_script" >/dev/null || {
  echo "api_curl must pass --retry-connrefused to curl" >&2
  exit 1
}

echo "serial Renovate loop tests passed"
