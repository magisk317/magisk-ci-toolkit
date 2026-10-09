#!/usr/bin/env bash
# Post-merge MR pipeline cleanup controller.
#
# GitLab cancels a redundant pipeline only when a NEW pipeline starts on the
# same ref (workflow:auto_cancel:on_new_commit), and there is no cancel-on-
# merge hook: a merge request ref (refs/merge-requests/<iid>/head) never
# receives another pipeline once the MR is merged, so the MR pipeline keeps
# running the full quality stage on code the target-branch pipeline is
# already validating. On a single-contested runner that duplicate build also
# starves the pipeline that matters.
#
# This controller closes the gap from the other direction: when a push lands
# on the protected target branch, it resolves the merge requests that push
# merged and cancels their merge_request_event pipelines. It runs inside the
# same trusted controller job as cancel_older_mr_pipelines.sh and is opt-in
# per consumer through MAGISK_CANCEL_MERGED_MR_PIPELINES=true (forwarded by
# .gitlab/ci/cancel-mr-pipelines.yml).
#
# Scope: only merge_request_event pipelines of already-merged MRs are
# canceled. Source-branch push pipelines are handled by the cross-family rule
# in cancel_older_mr_pipelines.sh, and the target-branch pipeline itself is
# the pipeline that must keep running.
set -euo pipefail

readonly CONTROLLER_PROJECT_ID="83955109"
readonly CONTROLLER_PROJECT_PATH="magisk3171/shared/magisk-ci-toolkit"
readonly ACTIVE_PIPELINE_STATUSES='["created","waiting_for_resource","preparing","pending","running","manual","scheduled"]'
# A merge lands on the target branch seconds before the push pipeline it
# triggers is created, so the window only has to absorb clock skew and a
# controller job a busy runner picked up late. Both bounds are validated as
# unsigned integers below.
readonly MERGE_LOOKAHEAD_SECONDS="${MAGISK_CANCEL_MERGED_MR_LOOKAHEAD_SECONDS:-60}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/trusted_projects.sh
source "$script_dir/trusted_projects.sh"
# shellcheck source=ci/api_retry.sh
source "$script_dir/api_retry.sh"

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
: "${CI_PROJECT_PATH:?CI_PROJECT_PATH is required}"
: "${CI_PIPELINE_ID:?CI_PIPELINE_ID is required}"
: "${CI_PIPELINE_IID:?CI_PIPELINE_IID is required}"
: "${CI_PIPELINE_SOURCE:?CI_PIPELINE_SOURCE is required}"
: "${CI_COMMIT_REF_NAME:?CI_COMMIT_REF_NAME is required}"
: "${CI_DEFAULT_BRANCH:?CI_DEFAULT_BRANCH is required}"
: "${CI_COMMIT_REF_PROTECTED:?CI_COMMIT_REF_PROTECTED is required}"
: "${MAGISK_CI_PIPELINE_CONTROL_TOKEN:?MAGISK_CI_PIPELINE_CONTROL_TOKEN is required}"
: "${MAGISK_UPSTREAM_PROJECT_ID:?MAGISK_UPSTREAM_PROJECT_ID is required}"
: "${MAGISK_UPSTREAM_PROJECT_PATH:?MAGISK_UPSTREAM_PROJECT_PATH is required}"
: "${MAGISK_UPSTREAM_PIPELINE_ID:?MAGISK_UPSTREAM_PIPELINE_ID is required}"
: "${MAGISK_UPSTREAM_PIPELINE_IID:?MAGISK_UPSTREAM_PIPELINE_IID is required}"
: "${MAGISK_UPSTREAM_PIPELINE_SOURCE:?MAGISK_UPSTREAM_PIPELINE_SOURCE is required}"
: "${MAGISK_UPSTREAM_REF:?MAGISK_UPSTREAM_REF is required}"

[[ "$CI_PROJECT_ID" == "$CONTROLLER_PROJECT_ID" ]] || fail "controller project ID is not trusted"
[[ "$CI_PROJECT_PATH" == "$CONTROLLER_PROJECT_PATH" ]] || fail "controller project path is not trusted"
[[ "$CI_PIPELINE_SOURCE" == "pipeline" ]] || fail "controller must run as a multi-project downstream pipeline"
[[ "$CI_COMMIT_REF_NAME" == "$CI_DEFAULT_BRANCH" ]] || fail "controller must run on the default branch"
[[ "$CI_COMMIT_REF_PROTECTED" == "true" ]] || fail "controller must run on a protected ref"
require_unsigned_integer "CI_PIPELINE_ID" "$CI_PIPELINE_ID"
require_unsigned_integer "CI_PIPELINE_IID" "$CI_PIPELINE_IID"
require_unsigned_integer "MAGISK_UPSTREAM_PROJECT_ID" "$MAGISK_UPSTREAM_PROJECT_ID"
require_unsigned_integer "MAGISK_UPSTREAM_PIPELINE_ID" "$MAGISK_UPSTREAM_PIPELINE_ID"
require_unsigned_integer "MAGISK_UPSTREAM_PIPELINE_IID" "$MAGISK_UPSTREAM_PIPELINE_IID"

page_size="${MAGISK_CI_PIPELINE_PAGE_SIZE:-100}"
max_pages="${MAGISK_CI_PIPELINE_MAX_PAGES:-1000}"
reconcile_passes="${MAGISK_CI_PIPELINE_RECONCILE_PASSES:-3}"
reconcile_delay="${MAGISK_CI_PIPELINE_RECONCILE_DELAY_SECONDS:-1}"
merge_lookback_seconds="${MAGISK_CANCEL_MERGED_MR_LOOKBACK_SECONDS:-900}"
require_unsigned_integer "MAGISK_CI_PIPELINE_PAGE_SIZE" "$page_size"
require_unsigned_integer "MAGISK_CI_PIPELINE_MAX_PAGES" "$max_pages"
require_unsigned_integer "MAGISK_CI_PIPELINE_RECONCILE_PASSES" "$reconcile_passes"
require_unsigned_integer "MAGISK_CI_PIPELINE_RECONCILE_DELAY_SECONDS" "$reconcile_delay"
require_unsigned_integer "MAGISK_CANCEL_MERGED_MR_LOOKBACK_SECONDS" "$merge_lookback_seconds"
require_unsigned_integer "MAGISK_CANCEL_MERGED_MR_LOOKAHEAD_SECONDS" "$MERGE_LOOKAHEAD_SECONDS"
((page_size > 0 && page_size <= 100)) || fail "MAGISK_CI_PIPELINE_PAGE_SIZE must be between 1 and 100"
((max_pages > 0)) || fail "MAGISK_CI_PIPELINE_MAX_PAGES must be greater than zero"
((reconcile_passes > 0)) || fail "MAGISK_CI_PIPELINE_RECONCILE_PASSES must be greater than zero"
((merge_lookback_seconds > 0)) || fail "MAGISK_CANCEL_MERGED_MR_LOOKBACK_SECONDS must be greater than zero"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

auth_header=(--header "PRIVATE-TOKEN: ${MAGISK_CI_PIPELINE_CONTROL_TOKEN}")

api_curl() {
  curl --fail --silent --show-error --location "${auth_header[@]}" "$@"
}

# Post-merge cleanup serves exactly one upstream family: the push that lands
# the merge on the protected target branch. Every other upstream source has
# no merged MRs to clean up after.
[[ "$MAGISK_UPSTREAM_PIPELINE_SOURCE" == "push" ]] || \
  fail "upstream pipeline source must be push for post-merge cleanup"

upstream_project_id="$MAGISK_UPSTREAM_PROJECT_ID"
upstream_project_path="$MAGISK_UPSTREAM_PROJECT_PATH"
upstream_pipeline_id="$MAGISK_UPSTREAM_PIPELINE_ID"
upstream_ref="$MAGISK_UPSTREAM_REF"

expected_upstream_project_id="$(trusted_project_id "$upstream_project_path")" || \
  fail "upstream project is not in the controller allowlist"
[[ "$upstream_project_id" == "$expected_upstream_project_id" ]] || fail "upstream project ID mismatch"

expected_target_branch="$(trusted_target_branch "$upstream_project_path")" || \
  fail "upstream project has no trusted target branch"
[[ "$upstream_ref" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "upstream push pipeline ref is invalid"
[[ "$upstream_ref" == "$expected_target_branch" ]] || \
  fail "upstream ref ${upstream_ref} is not the trusted target branch ${expected_target_branch}"

api_base="${CI_API_V4_URL}/projects/${upstream_project_id}"

upstream_pipeline_file="$tmp_dir/upstream-pipeline.json"
if ! api_get_with_retry api_curl "$upstream_pipeline_file" \
  "${api_base}/pipelines/${upstream_pipeline_id}"; then
  fail "failed to read upstream pipeline ${upstream_pipeline_id}"
fi
jq -e \
  --argjson pipeline_id "$upstream_pipeline_id" \
  --argjson pipeline_iid "$MAGISK_UPSTREAM_PIPELINE_IID" \
  --argjson project_id "$upstream_project_id" \
  --arg expected_ref "$upstream_ref" '
    .id == $pipeline_id
    and .iid == $pipeline_iid
    and .project_id == $project_id
    and .source == "push"
    and .ref == $expected_ref
    and (.created_at | type) == "string"
    and (.sha | type) == "string"
  ' "$upstream_pipeline_file" >/dev/null || fail "upstream pipeline response is invalid"

# gitlab_ts_epoch <timestamp>: normalize a GitLab ISO8601 timestamp to epoch
# seconds. GitLab emits millisecond precision, which jq's fromdateiso8601
# rejects, so the fraction is dropped and the remainder parsed at second
# granularity.
gitlab_ts_epoch() {
  local timestamp="$1"
  jq -rn --arg ts "$timestamp" \
    '($ts | sub("\\.[0-9]+";"")) | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime'
}

upstream_created_at="$(jq -r '.created_at' "$upstream_pipeline_file")"
upstream_created_epoch="$(gitlab_ts_epoch "$upstream_created_at")"
window_start_epoch=$((upstream_created_epoch - merge_lookback_seconds))
window_end_epoch=$((upstream_created_epoch + MERGE_LOOKAHEAD_SECONDS))
window_start="$(jq -rn --argjson epoch "$window_start_epoch" '$epoch | todateiso8601')"
window_end="$(jq -rn --argjson epoch "$window_end_epoch" '$epoch | todateiso8601')"

echo "Post-merge cleanup for ${upstream_project_path} push pipeline ${upstream_pipeline_id} (${upstream_ref}); merge window ${window_start} .. ${window_end}."

merged_mrs_file="$tmp_dir/merged-merge-requests.json"
cancel_targets_file="$tmp_dir/cancel-targets.ndjson"

# list_merged_merge_requests: MRs merged into the target branch whose merge
# timestamp falls inside the push pipeline's window. updated_after only
# narrows the response; the epoch comparison is the authoritative filter.
list_merged_merge_requests() {
  local output_file="$1"
  local ndjson_file="$tmp_dir/merge-requests.ndjson"
  local page=1
  local body_file
  local response_count

  : >"$ndjson_file"
  while :; do
    ((page <= max_pages)) || fail "merge request pagination exceeded ${max_pages} pages"
    body_file="$tmp_dir/merge-requests-page-${page}.json"
    if ! api_get_with_retry api_curl "$body_file" \
      --get \
      --data-urlencode "state=merged" \
      --data-urlencode "target_branch=${upstream_ref}" \
      --data-urlencode "updated_after=${window_start}" \
      --data-urlencode "order_by=updated_at" \
      --data-urlencode "sort=desc" \
      --data-urlencode "per_page=${page_size}" \
      --data-urlencode "page=${page}" \
      "${api_base}/merge_requests"; then
      fail "failed to list merged merge requests on page ${page}"
    fi
    jq -e 'type == "array" and all(.[]; (.iid | type) == "number" and (.state | type) == "string" and ((.merged_at // "") | type) == "string")' "$body_file" >/dev/null || \
      fail "merge request list response on page ${page} is invalid"
    jq -c '.[]' "$body_file" >>"$ndjson_file"
    response_count="$(jq 'length' "$body_file")"
    ((response_count < page_size)) && break
    page=$((page + 1))
  done

  if [[ -s "$ndjson_file" ]]; then
    jq -s --argjson start "$window_start_epoch" --argjson end "$window_end_epoch" '
      unique_by(.iid)
      | map(select(.state == "merged"))
      | map(.merged_at = (.merged_at // ""))
      | map(select(.merged_at != ""))
      | map(. + {merged_epoch: (.merged_at | sub("\\.[0-9]+";"") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)})
      | map(select(.merged_epoch >= $start and .merged_epoch <= $end))
      | sort_by(-.iid)
    ' "$ndjson_file" >"$output_file"
  else
    printf '[]\n' >"$output_file"
  fi
}

# list_mr_event_pipelines <mr_iid> <output_file>: active merge_request_event
# pipeline IDs of one MR. Source-branch push pipelines are deliberately out
# of scope here (see file header).
list_mr_event_pipelines() {
  local mr_iid="$1"
  local output_file="$2"
  local ndjson_file="$tmp_dir/mr-${mr_iid}-pipelines.ndjson"
  local page=1
  local body_file
  local response_count

  : >"$ndjson_file"
  while :; do
    ((page <= max_pages)) || fail "merge request pipeline pagination exceeded ${max_pages} pages"
    body_file="$tmp_dir/mr-${mr_iid}-pipelines-page-${page}.json"
    if ! api_get_with_retry api_curl "$body_file" \
      --get \
      --data-urlencode "per_page=${page_size}" \
      --data-urlencode "page=${page}" \
      "${api_base}/merge_requests/${mr_iid}/pipelines"; then
      fail "failed to list pipelines for merge request ${mr_iid} on page ${page}"
    fi
    jq -e 'type == "array" and all(.[]; (.id | type) == "number" and (.source | type) == "string" and (.status | type) == "string")' "$body_file" >/dev/null || \
      fail "merge request pipeline list response on page ${page} is invalid"
    jq -c '.[]' "$body_file" >>"$ndjson_file"
    response_count="$(jq 'length' "$body_file")"
    ((response_count < page_size)) && break
    page=$((page + 1))
  done

  if [[ -s "$ndjson_file" ]]; then
    jq -s --argjson active "$ACTIVE_PIPELINE_STATUSES" '
      unique_by(.id)
      | map(select(.source == "merge_request_event"))
      | map(.status as $status | select(($active | index($status)) != null))
      | map(.id)
    ' "$ndjson_file" >"$output_file"
  else
    printf '[]\n' >"$output_file"
  fi
}

# find_cancel_targets <output_file>: NDJSON of {iid, pipeline_id} pairs that
# should be canceled right now.
find_cancel_targets() {
  local output_file="$1"
  local mr_iid
  local pipeline_id
  local pipelines_file
  local -a mr_iids=()

  : >"$output_file"
  list_merged_merge_requests "$merged_mrs_file"
  mapfile -t mr_iids < <(jq -r '.[].iid' "$merged_mrs_file")
  ((${#mr_iids[@]} > 0)) || return 0

  for mr_iid in "${mr_iids[@]}"; do
    require_unsigned_integer "merge request IID" "$mr_iid"
    pipelines_file="$tmp_dir/mr-${mr_iid}-active.json"
    list_mr_event_pipelines "$mr_iid" "$pipelines_file"
    while IFS= read -r pipeline_id; do
      require_unsigned_integer "cancel candidate pipeline ID" "$pipeline_id"
      printf '{"iid":%s,"pipeline_id":%s}\n' "$mr_iid" "$pipeline_id" >>"$output_file"
    done < <(jq -r '.[]' "$pipelines_file")
  done
}

for ((pass = 1; pass <= reconcile_passes; pass++)); do
  find_cancel_targets "$cancel_targets_file"
  target_count="$(jq -s 'length' "$cancel_targets_file")"
  if ((target_count == 0)); then
    echo "No active merge request pipelines remain for the merge requests merged by this push."
    exit 0
  fi

  echo "Post-merge cleanup pass ${pass}: ${target_count} active merge request pipeline(s) to cancel."
  while IFS= read -r target; do
    mr_iid="$(jq -r '.iid' <<<"$target")"
    pipeline_id="$(jq -r '.pipeline_id' <<<"$target")"
    echo "Canceling merge request !${mr_iid} pipeline ${pipeline_id}."
    if ! api_curl \
      --request POST \
      --output "$tmp_dir/cancel-${pass}-${pipeline_id}.json" \
      "${api_base}/pipelines/${pipeline_id}/cancel"; then
      echo "Warning: failed to cancel pipeline ${pipeline_id}; it will be checked again." >&2
    fi
  done <"$cancel_targets_file"

  if ((pass < reconcile_passes && reconcile_delay > 0)); then
    sleep "$reconcile_delay"
  fi
done

find_cancel_targets "$cancel_targets_file"
remaining="$(jq -s 'length' "$cancel_targets_file")"
if ((remaining > 0)); then
  remaining_ids="$(jq -r '.pipeline_id' "$cancel_targets_file" | paste -sd, -)"
  fail "active merge request pipelines remain after reconciliation: ${remaining_ids}"
fi

echo "All merge request pipelines of the merge requests merged by this push are canceled."
