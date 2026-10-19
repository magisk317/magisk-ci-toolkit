#!/usr/bin/env bash
# Serial Renovate orchestrator.
#
# The loop keeps exactly one Renovate merge request in flight per round: it
# runs Renovate, waits for the toolkit controller to merge the request through
# the merge-request pipeline bridge, then starts the next round.
#
# A backlog (more than one open Renovate merge request) means the controller
# merge path left requests unmerged - for instance a broken consumer pipeline
# prevents the merge-request pipeline from bridging into the controller. When
# a backlog is detected the loop drains it itself: the open list is already
# restricted to renovate/ branches of this project targeting the default
# branch, so every entry is verified to be a Renovate request, and each one is
# merged directly with RENOVATE_TOKEN (the same token that creates them).
# Draining restores the one-request-at-a-time invariant, so the schedule
# pipeline self-heals instead of failing with "more than one open Renovate
# merge request exists". Set MAGISK_RENOVATE_BACKLOG_MERGE=false to restore
# the strict fail behaviour.
#
# The same drain is the last resort for a single request the controller never
# merged: when the wait for the controller exhausts its poll window - a bridge
# that never fired, a controller job that died during get_sources (2026-10-18
# TLS drop), or GitLab's post-rebase merge_status recheck window answering 422
# to every controller merge attempt (2026-10-19, build-logic !21) - the loop
# merges the request directly before failing the schedule run. One dead
# controller then costs seconds instead of a day of dependency updates.
set -euo pipefail

readonly HARD_MAX_ROUNDS=50
readonly DEFAULT_POLL_INTERVAL_SECONDS=5
readonly DEFAULT_MAX_POLLS=120
readonly DEFAULT_NO_MR_GRACE_POLLS=3
readonly DEFAULT_MERGE_ATTEMPTS=6
readonly DEFAULT_MERGE_DELAY_SECONDS=2

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_unsigned_integer() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "$name must be an unsigned integer"
}

: "${CI_API_V4_URL:?CI_API_V4_URL is required}"
: "${CI_PROJECT_ID:?CI_PROJECT_ID is required}"
: "${CI_PROJECT_DIR:?CI_PROJECT_DIR is required}"
: "${CI_COMMIT_REF_NAME:?CI_COMMIT_REF_NAME is required}"
: "${CI_DEFAULT_BRANCH:?CI_DEFAULT_BRANCH is required}"
: "${CI_PIPELINE_SOURCE:?CI_PIPELINE_SOURCE is required}"
: "${RENOVATE_TOKEN:?RENOVATE_TOKEN is required}"

[[ "$CI_PIPELINE_SOURCE" == "schedule" || "$CI_PIPELINE_SOURCE" == "web" || "$CI_PIPELINE_SOURCE" == "api" ]] || \
  fail "serial Renovate must run from a schedule, web, or API pipeline"
[[ "$CI_COMMIT_REF_NAME" == "$CI_DEFAULT_BRANCH" ]] || \
  fail "serial Renovate must run on the default branch"
[[ "${MAGISK_CANCEL_OLDER_MR_PIPELINES:-}" == "true" ]] || \
  fail "MAGISK_CANCEL_OLDER_MR_PIPELINES=true is required for serial Renovate"
require_unsigned_integer "CI_PROJECT_ID" "$CI_PROJECT_ID"

poll_interval="${MAGISK_RENOVATE_MR_POLL_INTERVAL_SECONDS:-$DEFAULT_POLL_INTERVAL_SECONDS}"
max_polls="${MAGISK_RENOVATE_MR_MAX_POLLS:-$DEFAULT_MAX_POLLS}"
no_mr_grace_polls="${MAGISK_RENOVATE_NO_MR_GRACE_POLLS:-$DEFAULT_NO_MR_GRACE_POLLS}"
max_rounds="${MAGISK_RENOVATE_MAX_ROUNDS:-$HARD_MAX_ROUNDS}"
require_unsigned_integer "MAGISK_RENOVATE_MR_POLL_INTERVAL_SECONDS" "$poll_interval"
require_unsigned_integer "MAGISK_RENOVATE_MR_MAX_POLLS" "$max_polls"
require_unsigned_integer "MAGISK_RENOVATE_NO_MR_GRACE_POLLS" "$no_mr_grace_polls"
require_unsigned_integer "MAGISK_RENOVATE_MAX_ROUNDS" "$max_rounds"
((max_polls > 0)) || fail "MAGISK_RENOVATE_MR_MAX_POLLS must be greater than zero"
((no_mr_grace_polls > 0 && no_mr_grace_polls <= max_polls)) || \
  fail "MAGISK_RENOVATE_NO_MR_GRACE_POLLS must be between 1 and MAGISK_RENOVATE_MR_MAX_POLLS"
((max_rounds > 0 && max_rounds <= HARD_MAX_ROUNDS)) || \
  fail "MAGISK_RENOVATE_MAX_ROUNDS must be between 1 and ${HARD_MAX_ROUNDS}"

backlog_merge="${MAGISK_RENOVATE_BACKLOG_MERGE:-true}"
case "$backlog_merge" in
  true | false) ;;
  *) fail "MAGISK_RENOVATE_BACKLOG_MERGE must be true or false" ;;
esac
merge_attempts="${MAGISK_RENOVATE_MERGE_ATTEMPTS:-$DEFAULT_MERGE_ATTEMPTS}"
merge_delay="${MAGISK_RENOVATE_MERGE_DELAY_SECONDS:-$DEFAULT_MERGE_DELAY_SECONDS}"
require_unsigned_integer "MAGISK_RENOVATE_MERGE_ATTEMPTS" "$merge_attempts"
require_unsigned_integer "MAGISK_RENOVATE_MERGE_DELAY_SECONDS" "$merge_delay"
((merge_attempts > 0)) || fail "MAGISK_RENOVATE_MERGE_ATTEMPTS must be greater than zero"

api_base="${CI_API_V4_URL%/}/projects/${CI_PROJECT_ID}"
auth_header=(--header "PRIVATE-TOKEN: ${RENOVATE_TOKEN}")
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

api_curl() {
  # GitLab answers 503/429 while a rate-limit window is active: a single
  # transient failure used to abort the whole Renovate run (October 2026).
  # curl retries 5xx/429 and connection errors only, so 4xx semantics,
  # including the already-merged replies, stay unchanged.
  curl --fail --silent --show-error --location \
    --retry "${MAGISK_RENOVATE_API_RETRIES:-3}" \
    --retry-delay "${MAGISK_RENOVATE_API_RETRY_DELAY_SECONDS:-5}" \
    --retry-connrefused \
    "${auth_header[@]}" "$@"
}

refresh_target_checkout() {
  git fetch --no-tags origin "$CI_COMMIT_REF_NAME"
  git checkout --detach --force FETCH_HEAD
  checkout_sha="$(git rev-parse HEAD)"
  target_sha="$(get_target_branch_sha)"
  [[ "${checkout_sha,,}" == "$target_sha" ]] || \
    fail "Renovate checkout ${checkout_sha} does not match target branch ${target_sha}"
}

require_sha() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9a-fA-F]{40,64}$ ]] || fail "$name is not a commit SHA"
}

branch_path="$(printf '%s' "$CI_COMMIT_REF_NAME" | jq -sRr @uri)"

get_target_branch_sha() {
  local branch_file="$tmp_dir/branch.json"
  api_curl --output "$branch_file" \
    "${api_base}/repository/branches/${branch_path}" || \
    fail "failed to read target branch ${CI_COMMIT_REF_NAME}"
  local branch_sha
  branch_sha="$(jq -r '.commit.id // empty' "$branch_file")"
  require_sha "target branch SHA" "$branch_sha"
  printf '%s\n' "${branch_sha,,}"
}

list_renovate_mrs() {
  local state="$1"
  local output_file="$2"
  local response_file="$tmp_dir/merge-requests-${state}.json"

  api_curl --get \
    --data-urlencode "state=${state}" \
    --data-urlencode "target_branch=${CI_COMMIT_REF_NAME}" \
    --data-urlencode 'order_by=updated_at' \
    --data-urlencode 'sort=desc' \
    --data-urlencode 'per_page=100' \
    --output "$response_file" \
    "${api_base}/merge_requests" || fail "failed to list ${state} merge requests"
  jq -e 'type == "array"' "$response_file" >/dev/null || \
    fail "merge request list response is invalid"
  jq \
    --arg target_branch "$CI_COMMIT_REF_NAME" \
    --argjson project_id "$CI_PROJECT_ID" '
    map(select(
      (.source_branch // "") | startswith("renovate/")
    ) | select(.target_branch == $target_branch)
      | select(.source_project_id == $project_id))
  ' "$response_file" >"$output_file"
}

get_merge_request() {
  local iid="$1"
  local output_file="$2"
  require_unsigned_integer "merge request IID" "$iid"
  api_curl --output "$output_file" \
    "${api_base}/merge_requests/${iid}" || fail "failed to read merge request !${iid}"
  jq -e \
    --argjson iid "$iid" \
    --arg target_branch "$CI_COMMIT_REF_NAME" \
    --argjson project_id "$CI_PROJECT_ID" '
      .iid == $iid
      and (.state | type) == "string"
      and .target_branch == $target_branch
      and ((.source_branch // "") | startswith("renovate/"))
      and .source_project_id == $project_id
    ' "$output_file" >/dev/null || fail "merge request !${iid} response is invalid"
}

# merge_api_curl: the merge endpoint answers 4xx/5xx with a JSON body rather
# than a curl-level failure, so --fail is dropped and the HTTP status is read
# from --write-out, mirroring ci/auto_merge_upstream_mr.sh.
merge_api_curl() {
  curl --silent --show-error --location "${auth_header[@]}" "$@"
}

# merge_renovate_mr <iid>: merge one open Renovate merge request at its HEAD
# sha with the controller semantics: draft, conflicting and pipeline-gated
# requests are skipped, transient readiness (including a request locked while
# its merge is being processed) is retried with a backoff ladder, and a
# request that is already merged or closed counts as done.
merge_renovate_mr() {
  local iid="$1"
  local attempt
  local response_file
  local http_status
  local state
  local mr_sha
  local message
  local retry_delay
  local backoff

  for ((attempt = 1; attempt <= merge_attempts; attempt++)); do
    response_file="$tmp_dir/merge-mr-${iid}-${attempt}.json"
    get_merge_request "$iid" "$response_file"

    state="$(jq -r '.state' "$response_file")"
    case "$state" in
      merged)
        echo "Renovate merge request !${iid} is already merged."
        return 0
        ;;
      closed)
        echo "Renovate merge request !${iid} was closed without merging; skipping."
        return 0
        ;;
      # GitLab reports "locked" while a merge is being processed (2026-09-29
      # !178: the controller merge landed one second after a poll had already
      # failed on this state). Transient: fall through to the sha-pinned PUT,
      # which answers 405/already-merged when the concurrent merge wins.
      locked)
        echo "Renovate merge request !${iid} is locked (a merge is in progress); retrying the merge."
        ;;
      opened) ;;
      *)
        fail "Renovate merge request !${iid} has unsupported state ${state}"
        ;;
    esac

    if [[ "$(jq -r '.draft' "$response_file")" == "true" ]]; then
      echo "Renovate merge request !${iid} is a draft; backlog merge is skipped."
      return 0
    fi
    if [[ "$(jq -r '.has_conflicts // false' "$response_file")" == "true" ]]; then
      echo "Renovate merge request !${iid} has conflicts; backlog merge is skipped."
      return 0
    fi
    if [[ "$(jq -r '.merge_when_pipeline_succeeds // false' "$response_file")" == "true" ]]; then
      echo "Renovate merge request !${iid} has a pipeline-gated auto-merge armed; it will merge itself."
      return 0
    fi

    mr_sha="$(jq -r '.sha | ascii_downcase' "$response_file")"
    require_sha "merge request !${iid} HEAD sha" "$mr_sha"

    http_status="$(merge_api_curl \
      --request PUT \
      --data-urlencode "sha=${mr_sha}" \
      --output "$response_file" \
      --write-out '%{http_code}' \
      "${api_base}/merge_requests/${iid}/merge")" || fail "merge API request failed for !${iid}"

    case "$http_status" in
      200)
        jq -e --argjson iid "$iid" '.iid == $iid and .state == "merged"' "$response_file" >/dev/null || \
          fail "merge API returned an unexpected success response for !${iid}"
        echo "Merged Renovate merge request !${iid} at ${mr_sha}."
        return 0
        ;;
      401 | 403)
        message="$(jq -r '.message // .error // "token rejected"' "$response_file" 2>/dev/null || printf '%s' 'token rejected')"
        fail "RENOVATE_TOKEN cannot merge !${iid} (HTTP ${http_status}: ${message})"
        ;;
      409)
        echo "Merge request !${iid} HEAD changed while merging."
        ;;
      405 | 422 | 429 | 5??)
        message="$(jq -r '.message // .merge_error // "merge is not ready"' "$response_file" 2>/dev/null || printf '%s' 'merge is not ready')"
        echo "Merge attempt ${attempt}/${merge_attempts} for !${iid} returned HTTP ${http_status}: ${message}"
        ;;
      *)
        message="$(jq -r '.message // .error // "unexpected response"' "$response_file" 2>/dev/null || printf '%s' 'unexpected response')"
        fail "merge API returned HTTP ${http_status} for !${iid}: ${message}"
        ;;
    esac

    if ((attempt < merge_attempts)); then
      retry_delay="$merge_delay"
      for ((backoff = 1; backoff < attempt; backoff++)); do
        retry_delay=$((retry_delay * 2))
      done
      if ((retry_delay > 0)); then
        sleep "$retry_delay"
      fi
    fi
  done

  echo "Warning: merge request !${iid} did not become mergeable after ${merge_attempts} attempts; it stays in the backlog." >&2
  return 0
}

# drain_renovate_backlog <open-mrs-file>: merge every open Renovate merge
# request, oldest first (the API list is sorted newest-updated first). Every
# entry was pre-filtered to a renovate/ branch of this project targeting the
# default branch, so a backlog at this point is always Renovate's.
drain_renovate_backlog() {
  local open_file="$1"
  local count
  local iids
  local iid

  count="$(jq 'length' "$open_file")"
  iids="$(jq -r '[.[].iid | tostring] | join(", !")' "$open_file")"
  echo "Renovate backlog detected: ${count} open Renovate merge requests (!${iids}) targeting ${CI_COMMIT_REF_NAME}; merging them directly before continuing."
  while IFS= read -r iid; do
    [[ -n "$iid" ]] || continue
    require_unsigned_integer "open merge request IID" "$iid"
    merge_renovate_mr "$iid"
  done < <(jq -r 'reverse | .[].iid' "$open_file")
}

# enforce_single_open_mr <context>: ensure at most one open Renovate merge
# request remains, draining a detected backlog first. On return the refreshed
# count is in SINGLE_OPEN_COUNT and the sole request IID, when present, in
# SINGLE_OPEN_IID; fails when a backlog cannot be cleared.
SINGLE_OPEN_COUNT=0
SINGLE_OPEN_IID=""
enforce_single_open_mr() {
  local context="$1"
  local open_file="$tmp_dir/open-check.json"

  SINGLE_OPEN_COUNT=0
  SINGLE_OPEN_IID=""
  list_renovate_mrs opened "$open_file"
  SINGLE_OPEN_COUNT="$(jq 'length' "$open_file")"
  if ((SINGLE_OPEN_COUNT <= 1)); then
    if ((SINGLE_OPEN_COUNT == 1)); then
      SINGLE_OPEN_IID="$(jq -r '.[0].iid' "$open_file")"
      require_unsigned_integer "open merge request IID" "$SINGLE_OPEN_IID"
    fi
    return 0
  fi

  if [[ "$backlog_merge" != "true" ]]; then
    fail "more than one open Renovate merge request exists ${context}"
  fi

  drain_renovate_backlog "$open_file"
  list_renovate_mrs opened "$open_file"
  SINGLE_OPEN_COUNT="$(jq 'length' "$open_file")"
  ((SINGLE_OPEN_COUNT <= 1)) || \
    fail "Renovate merge request backlog could not be cleared ${context}; !$(jq -r '[.[].iid | tostring] | join(", !")' "$open_file") remain open"
  if ((SINGLE_OPEN_COUNT == 1)); then
    SINGLE_OPEN_IID="$(jq -r '.[0].iid' "$open_file")"
    require_unsigned_integer "open merge request IID" "$SINGLE_OPEN_IID"
  fi
}

branch_contains_commit() {
  local from_sha="$1"
  local commit_sha="$2"
  local compare_file="$tmp_dir/compare-${commit_sha}.json"
  local target_sha

  require_sha "compare base SHA" "$from_sha"
  require_sha "merge commit SHA" "$commit_sha"
  target_sha="$(get_target_branch_sha)"
  [[ "$target_sha" != "${from_sha,,}" ]] || return 1
  [[ "$target_sha" == "${commit_sha,,}" ]] && return 0

  if ! api_curl --get \
    --data-urlencode "from=${from_sha}" \
    --data-urlencode "to=${CI_COMMIT_REF_NAME}" \
    --output "$compare_file" \
    "${api_base}/repository/compare"; then
    return 1
  fi
  jq -e \
    --arg commit_sha "${commit_sha,,}" '
      (.compare_timeout // false) == false
      and any(.commits[]?; ((.id // "") | ascii_downcase) == $commit_sha)
    ' "$compare_file" >/dev/null
}

wait_for_merge() {
  local iid="$1"
  local pre_round_sha="$2"
  local poll
  local mr_file
  local state
  local merge_sha
  local merge_status_now
  local detailed_status_now

  for ((poll = 1; poll <= max_polls; poll++)); do
    mr_file="$tmp_dir/mr-${iid}-${poll}.json"
    get_merge_request "$iid" "$mr_file"
    state="$(jq -r '.state' "$mr_file")"
    case "$state" in
      opened)
        echo "Waiting for Renovate merge request !${iid} to be merged (${poll}/${max_polls})."
        ;;
      # "locked" is GitLab's transient state while a merge is being processed.
      # The controller merge parks the request here for a few seconds; dying on
      # it raced the merge and failed a healthy schedule pipeline (!178).
      locked)
        echo "Merge request !${iid} is locked (a merge is in progress); waiting (${poll}/${max_polls})."
        ;;
      merged)
        merge_sha="$(jq -r '.merge_commit_sha // .squash_commit_sha // empty' "$mr_file")"
        require_sha "merge request !${iid} merge SHA" "$merge_sha"
        if branch_contains_commit "$pre_round_sha" "$merge_sha"; then
          echo "Confirmed Renovate merge request !${iid} is included in ${CI_COMMIT_REF_NAME}."
          return 0
        fi
        echo "Merge request !${iid} is merged, but ${CI_COMMIT_REF_NAME} has not caught up yet."
        ;;
      closed)
        fail "Renovate merge request !${iid} was closed without merging"
        ;;
      *)
        fail "Renovate merge request !${iid} has unsupported state ${state}"
        ;;
    esac
    ((poll < max_polls && poll_interval > 0)) && sleep "$poll_interval"
  done

  # The controller did not merge within the poll window. Drain the request
  # directly through the same merge_renovate_mr path a backlog uses before
  # failing the run: the failure classes above are exactly the ones the
  # backlog drain exists for, and a single request is just a backlog of one.
  echo "Warning: Renovate merge request !${iid} was not merged within ${max_polls} polls; attempting a direct merge."
  merge_renovate_mr "$iid"

  mr_file="$tmp_dir/mr-${iid}-fallback.json"
  get_merge_request "$iid" "$mr_file"
  state="$(jq -r '.state' "$mr_file")"
  if [[ "$state" == "merged" ]]; then
    merge_sha="$(jq -r '.merge_commit_sha // .squash_commit_sha // empty' "$mr_file")"
    require_sha "merge request !${iid} merge SHA" "$merge_sha"
    if branch_contains_commit "$pre_round_sha" "$merge_sha"; then
      echo "Confirmed Renovate merge request !${iid} is included in ${CI_COMMIT_REF_NAME}."
      return 0
    fi
    echo "Merge request !${iid} is merged, but ${CI_COMMIT_REF_NAME} has not caught up yet."
  fi

  # Report both status fields: detailed_merge_status alone claimed "mergeable"
  # for build-logic !21 on 2026-10-19 while every merge PUT answered 422
  # inside GitLab's post-rebase recheck window, which sent the failure hunt
  # in the wrong direction.
  merge_status_now="$(jq -r '.merge_status // "unknown"' "$mr_file")"
  detailed_status_now="$(jq -r '.detailed_merge_status // "unknown"' "$mr_file")"
  fail "Renovate merge request !${iid} was not merged into ${CI_COMMIT_REF_NAME} after ${max_polls} polls and a direct merge attempt (merge_status: ${merge_status_now}, detailed_merge_status: ${detailed_status_now})"
}

find_merged_after_scan() {
  local pre_round_sha="$1"
  local merged_file="$tmp_dir/merged-after-scan.json"
  local iid
  local mr_file
  local merge_sha

  list_renovate_mrs merged "$merged_file"
  while IFS= read -r iid; do
    mr_file="$tmp_dir/merged-mr-${iid}.json"
    get_merge_request "$iid" "$mr_file"
    [[ "$(jq -r '.state' "$mr_file")" == "merged" ]] || continue
    merge_sha="$(jq -r '.merge_commit_sha // .squash_commit_sha // empty' "$mr_file")"
    [[ "$merge_sha" =~ ^[0-9a-fA-F]{40,64}$ ]] || continue
    if branch_contains_commit "$pre_round_sha" "$merge_sha"; then
      printf '%s\n' "$iid"
      return 0
    fi
  done < <(jq -r '.[].iid' "$merged_file")
  return 1
}

wait_for_scan_result() {
  local pre_round_sha="$1"
  local poll
  local open_file
  local open_count
  local iid
  local current_sha

  for ((poll = 1; poll <= max_polls; poll++)); do
    enforce_single_open_mr "after the Renovate scan"
    open_count="$SINGLE_OPEN_COUNT"
    if ((open_count == 1)); then
      wait_for_merge "$SINGLE_OPEN_IID" "$pre_round_sha"
      return 0
    fi

    current_sha="$(get_target_branch_sha)"
    if [[ "$current_sha" != "${pre_round_sha,,}" ]]; then
      if iid="$(find_merged_after_scan "$pre_round_sha")"; then
        echo "Detected already-merged Renovate merge request !${iid} after the scan."
        return 0
      fi
      echo "Target branch changed without a matching Renovate merge request; waiting for API state to converge."
    elif ((poll >= no_mr_grace_polls)); then
      echo "No new Renovate merge request was found; the serial upgrade loop is complete."
      return 10
    fi
    ((poll < max_polls && poll_interval > 0)) && sleep "$poll_interval"
  done

  fail "Renovate scan did not produce a settled merge request result after ${max_polls} polls"
}

run_renovate_round() {
  local round="$1"
  local base_dir="${RENOVATE_BASE_DIR:-${CI_PROJECT_DIR}/.renovate}"
  local round_dir="${base_dir%/}/round-${round}"

  mkdir -p "$round_dir"
  RENOVATE_BASE_DIR="$round_dir" renovate
}

command -v renovate >/dev/null 2>&1 || fail "renovate command is required"

for ((round = 1; round <= max_rounds; round++)); do
  refresh_target_checkout
  pre_round_sha="$(get_target_branch_sha)"
  enforce_single_open_mr "before round ${round}"
  open_count="$SINGLE_OPEN_COUNT"

  echo "Starting Renovate serial round ${round}/${max_rounds} from ${pre_round_sha}."
  if ((open_count == 1)); then
    echo "Continuing with existing Renovate merge request !${SINGLE_OPEN_IID}."
    wait_for_merge "$SINGLE_OPEN_IID" "$pre_round_sha"
  else
    run_renovate_round "$round"
    result_status=0
    wait_for_scan_result "$pre_round_sha" || result_status=$?
    case "$result_status" in
      0) ;;
      10)
        exit 0
        ;;
      *)
        exit "$result_status"
        ;;
    esac
  fi

  if ((round == max_rounds)); then
    echo "Reached the ${max_rounds}-round Renovate limit; no further round will be started."
    exit 0
  fi
done
