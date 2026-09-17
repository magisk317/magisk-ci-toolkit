#!/usr/bin/env bash
set -euo pipefail

readonly HARD_MAX_ROUNDS=50
readonly DEFAULT_POLL_INTERVAL_SECONDS=5
readonly DEFAULT_MAX_POLLS=120
readonly DEFAULT_NO_MR_GRACE_POLLS=3

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

api_base="${CI_API_V4_URL%/}/projects/${CI_PROJECT_ID}"
auth_header=(--header "PRIVATE-TOKEN: ${RENOVATE_TOKEN}")
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

api_curl() {
  curl --fail --silent --show-error --location "${auth_header[@]}" "$@"
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

  for ((poll = 1; poll <= max_polls; poll++)); do
    mr_file="$tmp_dir/mr-${iid}-${poll}.json"
    get_merge_request "$iid" "$mr_file"
    state="$(jq -r '.state' "$mr_file")"
    case "$state" in
      opened)
        echo "Waiting for Renovate merge request !${iid} to be merged (${poll}/${max_polls})."
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

  fail "Renovate merge request !${iid} was not merged into ${CI_COMMIT_REF_NAME} after ${max_polls} polls"
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
    open_file="$tmp_dir/open-after-scan-${poll}.json"
    list_renovate_mrs opened "$open_file"
    open_count="$(jq 'length' "$open_file")"
    ((open_count <= 1)) || fail "more than one open Renovate merge request exists"
    if ((open_count == 1)); then
      iid="$(jq -r '.[0].iid' "$open_file")"
      wait_for_merge "$iid" "$pre_round_sha"
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
  open_file="$tmp_dir/open-before-${round}.json"
  list_renovate_mrs opened "$open_file"
  open_count="$(jq 'length' "$open_file")"
  ((open_count <= 1)) || fail "more than one open Renovate merge request exists before round ${round}"

  echo "Starting Renovate serial round ${round}/${max_rounds} from ${pre_round_sha}."
  if ((open_count == 1)); then
    iid="$(jq -r '.[0].iid' "$open_file")"
    echo "Continuing with existing Renovate merge request !${iid}."
    wait_for_merge "$iid" "$pre_round_sha"
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
