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

# Merge-request body helpers. sha aaa... is the request HEAD, bbb... the merge
# commit that lands on the target branch.
mr_opened_json() {
  jq -nc \
    --argjson iid "$1" \
    --arg branch "$2" \
    --argjson conflicts "$3" \
    '{iid:$iid,state:"opened",source_project_id:123,source_branch:$branch,
      target_branch:"beta",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      draft:false,has_conflicts:$conflicts,merge_when_pipeline_succeeds:false}'
}

mr_merged_json() {
  jq -nc \
    --argjson iid "$1" \
    '{iid:$iid,state:"merged",source_project_id:123,
      source_branch:("renovate/dep-"+($iid|tostring)),target_branch:"beta",
      sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      merge_commit_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
}

cat >"$mock_bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail

# Merge-request body helpers. sha aaa... is the request HEAD, bbb... the merge
# commit that lands on the target branch.
mr_opened_json() {
  jq -nc \
    --argjson iid "$1" \
    --arg branch "$2" \
    --argjson conflicts "$3" \
    '{iid:$iid,state:"opened",source_project_id:123,source_branch:$branch,
      target_branch:"beta",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      draft:false,has_conflicts:$conflicts,merge_when_pipeline_succeeds:false}'
}

# GitLab reports "locked" while a merge is being processed; every consumer of
# an MR response must treat it as transient.
mr_locked_json() {
  jq -nc --argjson iid "$1" '{iid:$iid,state:"locked",source_project_id:123,source_branch:("renovate/dep-"+($iid|tostring)),target_branch:"beta",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",draft:false,has_conflicts:false,merge_when_pipeline_succeeds:false}'
}

mr_merged_json() {
  jq -nc \
    --argjson iid "$1" \
    '{iid:$iid,state:"merged",source_project_id:123,
      source_branch:("renovate/dep-"+($iid|tostring)),target_branch:"beta",
      sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      merge_commit_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
}

output_file=""
method="GET"
url=""
requested_state=""
write_out=""
merge_sha=""
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
  [[ "$url" == */merge ]] || { echo "mock curl: unsupported PUT URL $url" >&2; exit 64; }
  iid="${url##*/merge_requests/}"
  iid="${iid%%/*}"
  if [[ -n "${MOCK_MERGE_HTTP_STATUS:-}" ]]; then
    jq -n '{message:"merge rejected by mock"}' >"$output_file"
    printf '%s' "$MOCK_MERGE_HTTP_STATUS"
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
    sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  else
    sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  fi
  jq -n --arg sha "$sha" '{commit:{id:$sha}}' >"$output_file"
  exit 0
fi

if [[ "$url" == */repository/commits ]]; then
  jq -n '[{id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]' >"$output_file"
  exit 0
fi

if [[ "$url" == */repository/compare ]]; then
  jq -n '{compare_timeout:false,commits:[{id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}' >"$output_file"
  exit 0
fi

if [[ "$url" == */merge_requests && "$requested_state" == "opened" ]]; then
  if [[ "$state" == "open" ]]; then
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
grep -F "Merged Renovate merge request !101 at aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$tmp_root/backlog-before-round/output.log" >/dev/null
grep -F "Merged Renovate merge request !102 at aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$tmp_root/backlog-before-round/output.log" >/dev/null
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
grep -F "Merged Renovate merge request !101 at aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$tmp_root/backlog-after-scan/output.log" >/dev/null
grep -F "Merged Renovate merge request !102 at aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$tmp_root/backlog-after-scan/output.log" >/dev/null
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
# back to the single-request wait, which eventually fails with a clear reason.
MOCK_CONFLICT_IID=102 run_case backlog-partial backlog
[[ "$(cat "$tmp_root/backlog-partial/status")" == "1" ]] || {
  cat "$tmp_root/backlog-partial/output.log" >&2
  exit 1
}
grep -F "Renovate merge request !102 has conflicts; backlog merge is skipped." "$tmp_root/backlog-partial/output.log" >/dev/null
grep -F "Continuing with existing Renovate merge request !102." "$tmp_root/backlog-partial/output.log" >/dev/null
grep -F "Renovate merge request !102 was not merged into beta after 4 polls" "$tmp_root/backlog-partial/output.log" >/dev/null
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
grep -F "Merged Renovate merge request !101 at aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$tmp_root/locked-backlog/output.log" >/dev/null
grep -F "Starting Renovate serial round 1/2" "$tmp_root/locked-backlog/output.log" >/dev/null
[[ "$(cat "$tmp_root/locked-backlog/renovate-count")" == "2" ]] || exit 1

# A permanently locked request still terminates the loop - through the normal
# timeout with the real reason - instead of the "unsupported state" dead end.
MOCK_LOCKED_IID=101 run_case locked-timeout open
[[ "$(cat "$tmp_root/locked-timeout/status")" == "1" ]] || {
  cat "$tmp_root/locked-timeout/output.log" >&2
  exit 1
}
grep -F "Renovate merge request !101 was not merged into beta after 4 polls" "$tmp_root/locked-timeout/output.log" >/dev/null
if grep -F "unsupported state locked" "$tmp_root/locked-timeout/output.log" >/dev/null; then
  echo "a locked request must not be reported as an unsupported state" >&2
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
