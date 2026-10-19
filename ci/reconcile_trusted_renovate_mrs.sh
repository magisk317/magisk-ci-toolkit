#!/usr/bin/env bash
# Reconcile sweep for Renovate merge requests across every trusted project.
#
# The serial loop (ci/renovate_serial_loop.sh) and the consumer controller
# (ci/auto_merge_upstream_mr.sh) each merge exactly one request per trigger,
# and both can leave a request unmerged when their trigger dies: on 2026-10-18
# a dropped TLS connection during get_sources killed the controller before any
# script ran, and on 2026-10-19 GitLab's post-rebase merge_status recheck
# window answered 422 to all six controller merge attempts for build-logic
# !21. In both cases the request sat healthy and unmerged until the next
# day's schedule. The sweep closes that gap: a dedicated high-frequency
# schedule runs it every 15 minutes, it merges the requests GitLab already
# reports as can_be_merged, and it leaves everything else for the next sweep
# or the daily orchestrator.
#
# Semantics deliberately match the controller: same-project renovate/ source
# branches targeting the trusted default branch only, non-draft,
# conflict-free, no pipeline-gated auto-merge armed, sha-pinned merge, and
# pipeline status is intentionally not a merge gate. Requests are visited
# oldest first and the sweep stops at the first request that is not ready, so
# merge order is preserved exactly like the serial loop's one-at-a-time
# invariant. Transport-level failures on every GitLab API call ride the
# shared retry ladder in ci/api_retry.sh.
#
# This script never runs Renovate, cancels pipelines, or retries a readiness
# failure: there is always another sweep in 15 minutes.
set -euo pipefail

readonly CONTROLLER_PROJECT_ID="83955109"
readonly CONTROLLER_PROJECT_PATH="magisk3171/shared/magisk-ci-toolkit"
readonly RENOVATE_BRANCH_PREFIX="renovate/"
readonly DEFAULT_PAGE_SIZE=100

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/trusted_projects.sh
source "$script_dir/trusted_projects.sh"
# shellcheck source=ci/api_retry.sh
source "$script_dir/api_retry.sh"

fail() {
  echo "Error: $*" >&2
  exit 1
}

warn() {
  echo "Warning: $*" >&2
}

require_unsigned_integer() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "$name must be an unsigned integer"
}

require_sha() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9a-fA-F]{40,64}$ ]] || fail "$name is not a commit SHA"
}

: "${CI_API_V4_URL:?CI_API_V4_URL is required}"
: "${CI_PROJECT_ID:?CI_PROJECT_ID is required}"
: "${CI_PROJECT_PATH:?CI_PROJECT_PATH is required}"
: "${CI_COMMIT_REF_NAME:?CI_COMMIT_REF_NAME is required}"
: "${CI_DEFAULT_BRANCH:?CI_DEFAULT_BRANCH is required}"
: "${MAGISK_CI_MR_AUTOMERGE_TOKEN:?MAGISK_CI_MR_AUTOMERGE_TOKEN is required}"

[[ "$CI_PROJECT_ID" == "$CONTROLLER_PROJECT_ID" ]] || fail "this script only runs in the toolkit project"
[[ "$CI_PROJECT_PATH" == "$CONTROLLER_PROJECT_PATH" ]] || fail "this script only runs in the toolkit project"
# The merge token is only exposed on protected refs; running from anywhere
# else would turn every merge attempt into a token rejection.
[[ "$CI_COMMIT_REF_NAME" == "$CI_DEFAULT_BRANCH" ]] || fail "reconcile must run on the default branch"
[[ "$CI_DEFAULT_BRANCH" == "main" ]] || fail "unexpected toolkit default branch ${CI_DEFAULT_BRANCH}"
require_unsigned_integer "CI_PROJECT_ID" "$CI_PROJECT_ID"

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

# Invoked by name from the shared retry ladder in ci/api_retry.sh, which adds
# --fail, --output and --write-out itself; this wrapper must not.
# shellcheck disable=SC2329 # Called by name from api_get_with_retry / api_write_with_retry.
api_curl() {
  curl --silent --show-error --location \
    --header "PRIVATE-TOKEN: ${MAGISK_CI_MR_AUTOMERGE_TOKEN}" \
    "$@"
}

TOTAL_PROJECTS=0
TOTAL_MERGED=0
TOTAL_NOT_READY=0
# Set by merge_renovate_mr to "merged" or "skipped" on every return 0, so the
# sweep can tell a landed merge (by itself, or concurrently by the controller)
# from a request it deliberately left alone.
LAST_MERGE_OUTCOME="skipped"

# list_open_renovate_mrs <project_path> <project_id> <target_branch> <output_file>
list_open_renovate_mrs() {
  local project_path="$1"
  local project_id="$2"
  local target_branch="$3"
  local output_file="$4"
  local response_file="$tmp_dir/list-${project_id}.json"

  if ! api_get_with_retry api_curl "$response_file" \
    --get \
    --data-urlencode "state=opened" \
    --data-urlencode "target_branch=${target_branch}" \
    --data-urlencode "per_page=${DEFAULT_PAGE_SIZE}" \
    "${CI_API_V4_URL%/}/projects/${project_id}/merge_requests"; then
    warn "failed to list open merge requests for ${project_path}; skipping it in this sweep"
    return 1
  fi
  jq -e 'type == "array"' "$response_file" >/dev/null || {
    warn "merge request list response for ${project_path} is invalid; skipping it in this sweep"
    return 1
  }
  if [[ "$(jq 'length' "$response_file")" -ge "$DEFAULT_PAGE_SIZE" ]]; then
    warn "${project_path} returned ${DEFAULT_PAGE_SIZE} open merge requests; the sweep reads only the first page"
  fi
  jq \
    --arg prefix "$RENOVATE_BRANCH_PREFIX" \
    --arg target_branch "$target_branch" \
    --argjson project_id "$project_id" '
    map(select(
      ((.source_branch // "") | startswith($prefix))
      and .target_branch == $target_branch
      and .source_project_id == $project_id
    )) | sort_by(.iid)
  ' "$response_file" >"$output_file"
}

# merge_renovate_mr <project_path> <project_id> <target_branch> <iid>
#
# Merge one request at its HEAD sha with the controller semantics, or skip it
# with a reason. Prints 0 when the sweep may continue with the next request
# and 1 when the rest of the project must wait for a later sweep (the request
# is not ready, or the transport broke).
merge_renovate_mr() {
  local project_path="$1"
  local project_id="$2"
  local target_branch="$3"
  local iid="$4"
  local mr_api_url="${CI_API_V4_URL%/}/projects/${project_id}/merge_requests/${iid}"
  local mr_file="$tmp_dir/mr-${project_id}-${iid}.json"
  local response_file="$tmp_dir/merge-${project_id}-${iid}.json"
  local state
  local source_branch
  local mr_sha
  local http_status
  local message

  require_unsigned_integer "merge request IID" "$iid"
  if ! api_get_with_retry api_curl "$mr_file" \
    --get \
    --data-urlencode "with_merge_status_recheck=true" \
    "$mr_api_url"; then
    warn "failed to read ${project_path}!${iid}; the rest of ${project_path} waits for a later sweep"
    return 1
  fi
  jq -e \
    --argjson iid "$iid" \
    --argjson project_id "$project_id" \
    --arg target_branch "$target_branch" '
      .iid == $iid
      and .project_id == $project_id
      and .target_project_id == $project_id
      and (.state | type) == "string"
      and (.draft | type) == "boolean"
      and (.source_branch | type) == "string"
      and .target_branch == $target_branch
    ' "$mr_file" >/dev/null || fail "${project_path}!${iid} response is invalid"

  state="$(jq -r '.state' "$mr_file")"
  case "$state" in
    merged)
      echo "${project_path}!${iid} is already merged."
      LAST_MERGE_OUTCOME="merged"
      return 0
      ;;
    closed)
      echo "${project_path}!${iid} was closed without merging; skipping."
      LAST_MERGE_OUTCOME="skipped"
      return 0
      ;;
    locked)
      echo "${project_path}!${iid} is locked (a merge is in progress); the rest of ${project_path} waits for a later sweep."
      return 1
      ;;
    opened) ;;
    *)
      fail "${project_path}!${iid} has unsupported state ${state}"
      ;;
  esac

  if [[ "$(jq -r '.draft' "$mr_file")" == "true" ]]; then
    echo "${project_path}!${iid} is a draft; skipping."
    LAST_MERGE_OUTCOME="skipped"
    return 0
  fi

  if [[ "$(jq -r '.source_project_id' "$mr_file")" != "$project_id" ]]; then
    echo "${project_path}!${iid} comes from another project; skipping."
    LAST_MERGE_OUTCOME="skipped"
    return 0
  fi

  source_branch="$(jq -r '.source_branch' "$mr_file")"
  [[ -n "$source_branch" ]] || fail "${project_path}!${iid} source branch is empty"
  [[ "$source_branch" == "${RENOVATE_BRANCH_PREFIX}"* ]] || \
    fail "${project_path}!${iid} is not a Renovate branch"

  if [[ "$(jq -r '.merge_when_pipeline_succeeds // false' "$mr_file")" == "true" ]]; then
    echo "${project_path}!${iid} has a pipeline-gated auto-merge armed; it will merge itself."
    LAST_MERGE_OUTCOME="skipped"
    return 0
  fi

  if [[ "$(jq -r '.has_conflicts // false' "$mr_file")" == "true" ]]; then
    echo "${project_path}!${iid} has conflicts; the rest of ${project_path} waits for a later sweep."
    return 1
  fi

  # The coarse gate the merge endpoint applies. During GitLab's post-rebase
  # recheck window this field reads "unchecked" while detailed_merge_status
  # already claims "mergeable" - trusting the detailed field here would repeat
  # the controller's six-fold 422 run (build-logic !21, 2026-10-19).
  if [[ "$(jq -r '.merge_status // "unknown"' "$mr_file")" != "can_be_merged" ]]; then
    echo "${project_path}!${iid} is not mergeable yet (merge_status: $(jq -r '.merge_status // "unknown"' "$mr_file"), detailed_merge_status: $(jq -r '.detailed_merge_status // "unknown"' "$mr_file")); the rest of ${project_path} waits for a later sweep."
    return 1
  fi

  mr_sha="$(jq -r '.sha | ascii_downcase' "$mr_file")"
  require_sha "${project_path}!${iid} HEAD sha" "$mr_sha"

  # The merge endpoint answers 4xx/5xx with a JSON body, so --fail turns
  # readiness failures into curl exit 22 and the ladder classifies them by
  # status code: 4xx determinations are not retried, 429/5xx are.
  if ! http_status="$(api_write_with_retry api_curl "$response_file" \
    --request PUT \
    --data-urlencode "sha=${mr_sha}" \
    "${mr_api_url}/merge")"; then
    http_status="${http_status:-000}"
  fi

  case "$http_status" in
    200)
      jq -e --argjson iid "$iid" '.iid == $iid and .state == "merged"' "$response_file" >/dev/null || \
        fail "merge API returned an unexpected success response for ${project_path}!${iid}"
      echo "Merged ${project_path}!${iid} at ${mr_sha} without waiting for pipeline success."
      LAST_MERGE_OUTCOME="merged"
      return 0
      ;;
    405)
      echo "${project_path}!${iid} was merged concurrently (HTTP 405)."
      LAST_MERGE_OUTCOME="merged"
      return 0
      ;;
    409)
      echo "${project_path}!${iid} HEAD changed while merging; the rest of ${project_path} waits for a later sweep."
      return 1
      ;;
    422 | 429 | 5??)
      message="$(jq -r '.message // .merge_error // "merge is not ready"' "$response_file" 2>/dev/null || printf '%s' 'merge is not ready')"
      echo "${project_path}!${iid} is not ready (HTTP ${http_status}: ${message}); the rest of ${project_path} waits for a later sweep."
      return 1
      ;;
    401 | 403)
      message="$(jq -r '.message // .error // "token rejected"' "$response_file" 2>/dev/null || printf '%s' 'token rejected')"
      fail "MAGISK_CI_MR_AUTOMERGE_TOKEN cannot merge ${project_path}!${iid} (HTTP ${http_status}: ${message})"
      ;;
    000)
      warn "merge API request for ${project_path}!${iid} kept failing at the transport level; the rest of ${project_path} waits for a later sweep"
      return 1
      ;;
    *)
      message="$(jq -r '.message // .error // "unexpected response"' "$response_file" 2>/dev/null || printf '%s' 'unexpected response')"
      fail "merge API returned HTTP ${http_status} for ${project_path}!${iid}: ${message}"
      ;;
  esac
}

# sweep_project <project_path> <project_id> <target_branch>
sweep_project() {
  local project_path="$1"
  local project_id="$2"
  local target_branch="$3"
  local open_file="$tmp_dir/open-${project_id}.json"
  local iid
  local count
  local remaining

  TOTAL_PROJECTS=$((TOTAL_PROJECTS + 1))
  if ! list_open_renovate_mrs "$project_path" "$project_id" "$target_branch" "$open_file"; then
    return 0
  fi
  count="$(jq 'length' "$open_file")"
  if ((count == 0)); then
    echo "${project_path}: no open Renovate merge requests targeting ${target_branch}."
    return 0
  fi
  echo "${project_path}: ${count} open Renovate merge request(s) targeting ${target_branch} (!$(jq -r '[.[].iid | tostring] | join(", !")' "$open_file"))."

  # Oldest first (sort_by(.iid) in the list filter); stop at the first
  # request that is not ready so the remaining ones keep their order.
  while IFS= read -r iid; do
    [[ -n "$iid" ]] || continue
    if merge_renovate_mr "$project_path" "$project_id" "$target_branch" "$iid"; then
      [[ "$LAST_MERGE_OUTCOME" == "merged" ]] && TOTAL_MERGED=$((TOTAL_MERGED + 1))
    else
      # The stopping request and everything behind it stays unmerged until a
      # later sweep; count all of them, not just the one that stopped us.
      remaining="$(jq --argjson stop "$iid" '[.[] | select(.iid >= $stop)] | length' "$open_file")"
      TOTAL_NOT_READY=$((TOTAL_NOT_READY + remaining))
      return 0
    fi
  done < <(jq -r '.[].iid' "$open_file")
}

# The trusted upstreams first (build-logic feeds the consumers' version
# catalogs), then this repository: the toolkit cannot bridge into itself, so
# its own requests normally ride the daily self-automerge job - one dead
# self-automerge job must not cost a day either.
while IFS= read -r project_path; do
  [[ -n "$project_path" ]] || continue
  project_id="$(trusted_project_id "$project_path")" || \
    fail "${project_path} is enumerated as trusted but resolves no project ID"
  target_branch="$(trusted_target_branch "$project_path")" || \
    fail "${project_path} is enumerated as trusted but resolves no target branch"
  sweep_project "$project_path" "$project_id" "$target_branch"
done < <(trusted_project_paths)
sweep_project "$CONTROLLER_PROJECT_PATH" "$CONTROLLER_PROJECT_ID" "$CI_DEFAULT_BRANCH"

echo "Renovate reconcile sweep complete: ${TOTAL_PROJECTS} projects visited, ${TOTAL_MERGED} merged, ${TOTAL_NOT_READY} left for a later sweep."
