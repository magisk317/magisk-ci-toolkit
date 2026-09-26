#!/usr/bin/env bash
# Trusted auto-merge for this repository's own Renovate merge requests.
#
# Consumers are merged by a multi-project bridge into the protected toolkit
# main branch. A multi-project trigger cannot target the project its own
# pipeline runs in (verified on this instance: a self bridge is rejected as
# an invalid bridge trigger, the pipeline create API refuses the CI job
# token, and a child pipeline inherits the unprotected merge request ref,
# where masked variables such as the merge token are unavailable). The
# toolkit therefore has no bridge-side controller for its own merge
# requests: the serial Renovate pipeline itself - which already runs on
# the protected default branch, where the merge token is available -
# merges the requests Renovate opens.
#
# Semantics deliberately match the consumer controller: each merge request
# must be open, non-draft, same-project, conflict-free and targeted at the
# trusted default branch; the merge is pinned to the request HEAD sha and
# transient readiness is absorbed by a retry ladder. Pipeline status is
# intentionally not a merge gate: every merge request still runs its own
# pipeline, and every merge commit is guarded by shell:test on the
# resulting push pipeline. The script also performs the latest-wins
# cancellation of obsolete Renovate pipelines that consumers receive from
# the renovate bridge kind.
set -euo pipefail

readonly CONTROLLER_PROJECT_ID="83955109"
readonly CONTROLLER_PROJECT_PATH="magisk3171/shared/magisk-ci-toolkit"
readonly DEFAULT_LOOP_JOB_NAME="renovate:gitlab"
readonly RENOVATE_BRANCH_PREFIX="renovate/"
readonly DEFAULT_POLL_INTERVAL_SECONDS=10
readonly DEFAULT_MERGE_ATTEMPTS=6
readonly DEFAULT_MERGE_DELAY_SECONDS=2
readonly DEFAULT_PAGE_SIZE=100
readonly DEFAULT_MAX_PAGES=1000
readonly ACTIVE_PIPELINE_STATUSES='"created","waiting_for_resource","preparing","pending","running","manual","scheduled"'
readonly RENOVATE_PIPELINE_SOURCES='"schedule","web","api"'

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
: "${CI_PIPELINE_ID:?CI_PIPELINE_ID is required}"
: "${CI_PIPELINE_SOURCE:?CI_PIPELINE_SOURCE is required}"
: "${CI_COMMIT_REF_NAME:?CI_COMMIT_REF_NAME is required}"
: "${CI_DEFAULT_BRANCH:?CI_DEFAULT_BRANCH is required}"

[[ "$CI_PROJECT_ID" == "$CONTROLLER_PROJECT_ID" ]] || fail "this script only runs in the toolkit project"
[[ "$CI_PROJECT_PATH" == "$CONTROLLER_PROJECT_PATH" ]] || fail "this script only runs in the toolkit project"
[[ "$CI_PIPELINE_SOURCE" == "schedule" || "$CI_PIPELINE_SOURCE" == "web" || "$CI_PIPELINE_SOURCE" == "api" ]] || \
  fail "self Renovate must run from a schedule, web, or API pipeline"
[[ "$CI_COMMIT_REF_NAME" == "$CI_DEFAULT_BRANCH" ]] || fail "self Renovate must run on the default branch"
require_unsigned_integer "CI_PROJECT_ID" "$CI_PROJECT_ID"
require_unsigned_integer "CI_PIPELINE_ID" "$CI_PIPELINE_ID"

loop_job_name="${MAGISK_SELF_MERGE_LOOP_JOB:-$DEFAULT_LOOP_JOB_NAME}"
[[ -n "$loop_job_name" ]] || fail "MAGISK_SELF_MERGE_LOOP_JOB must not be empty"
poll_interval="${MAGISK_SELF_MERGE_POLL_INTERVAL_SECONDS:-$DEFAULT_POLL_INTERVAL_SECONDS}"
merge_attempts="${MAGISK_SELF_MERGE_ATTEMPTS:-$DEFAULT_MERGE_ATTEMPTS}"
merge_delay="${MAGISK_SELF_MERGE_DELAY_SECONDS:-$DEFAULT_MERGE_DELAY_SECONDS}"
page_size="${MAGISK_CI_PIPELINE_PAGE_SIZE:-$DEFAULT_PAGE_SIZE}"
max_pages="${MAGISK_CI_PIPELINE_MAX_PAGES:-$DEFAULT_MAX_PAGES}"
require_unsigned_integer "MAGISK_SELF_MERGE_POLL_INTERVAL_SECONDS" "$poll_interval"
require_unsigned_integer "MAGISK_SELF_MERGE_ATTEMPTS" "$merge_attempts"
require_unsigned_integer "MAGISK_SELF_MERGE_DELAY_SECONDS" "$merge_delay"
require_unsigned_integer "MAGISK_CI_PIPELINE_PAGE_SIZE" "$page_size"
require_unsigned_integer "MAGISK_CI_PIPELINE_MAX_PAGES" "$max_pages"
((merge_attempts > 0)) || fail "MAGISK_SELF_MERGE_ATTEMPTS must be greater than zero"
((page_size > 0 && page_size <= 100)) || fail "MAGISK_CI_PIPELINE_PAGE_SIZE must be between 1 and 100"
((max_pages > 0)) || fail "MAGISK_CI_PIPELINE_MAX_PAGES must be greater than zero"

api_base="${CI_API_V4_URL%/}/projects/${CI_PROJECT_ID}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

# The controller tokens are fine-grained personal access tokens with
# complementary project permissions, so each operation class tries the tokens
# that can perform it:
#   MAGISK_CI_MR_AUTOMERGE_TOKEN - reads and merges merge requests (the same
#     work it performs for consumers every day), but lacks Pipeline: Read
#   MAGISK_CI_PIPELINE_CONTROL_TOKEN - reads pipelines and cancels them
#   RENOVATE_TOKEN - creates this repository's Renovate branches and merge
#     requests, so it holds repository and merge-request write access here
mr_read_tokens=()
mr_merge_tokens=()
pipeline_read_tokens=()
pipeline_cancel_tokens=()
for candidate in \
  "${MAGISK_CI_MR_AUTOMERGE_TOKEN:-}" \
  "${RENOVATE_TOKEN:-}" \
  "${MAGISK_CI_PIPELINE_CONTROL_TOKEN:-}"; do
  [[ -n "$candidate" ]] || continue
  mr_read_tokens+=("$candidate")
  mr_merge_tokens+=("$candidate")
done
for candidate in \
  "${MAGISK_CI_PIPELINE_CONTROL_TOKEN:-}" \
  "${MAGISK_CI_MR_AUTOMERGE_TOKEN:-}" \
  "${RENOVATE_TOKEN:-}"; do
  [[ -n "$candidate" ]] || continue
  pipeline_read_tokens+=("$candidate")
  pipeline_cancel_tokens+=("$candidate")
done
((${#mr_read_tokens[@]} > 0)) || fail "no token with merge-request access is available"
((${#mr_merge_tokens[@]} > 0)) || fail "no token with merge access is available"
((${#pipeline_read_tokens[@]} > 0)) || fail "no token with pipeline read access is available"

# api_request <token> <output-file> <method> [curl args...]:
# prints the HTTP status code; returns non-zero only when curl itself fails.
api_request() {
  local token="$1"
  local output_file="$2"
  local method="$3"
  shift 3
  curl --silent --show-error --location \
    --header "PRIVATE-TOKEN: ${token}" \
    --request "$method" \
    --output "$output_file" \
    --write-out '%{http_code}' "$@"
}

# get_with_tokens <tokens-array-name> <output-file> [curl args...]:
# performs a GET with the first token whose credentials return a 2xx status;
# exits with every token's error when none succeeds.
get_with_tokens() {
  local -n tokens="$1"
  local output_file="$2"
  shift 2
  local code
  local errors=""
  local token
  for token in "${tokens[@]}"; do
    if code="$(api_request "$token" "$output_file" GET "$@")" && [[ "$code" =~ ^2 ]]; then
      return 0
    fi
    errors+="HTTP ${code:-curl-failed}: $(head -c 200 "$output_file" 2>/dev/null)"$'\n'
  done
  fail "no available token can perform the request: ${errors}"
}

# try_get_with_tokens: same as get_with_tokens, but returns non-zero instead
# of exiting; used by the best-effort cleanup paths.
try_get_with_tokens() {
  local -n tokens="$1"
  local output_file="$2"
  shift 2
  local code
  local errors=""
  local token
  for token in "${tokens[@]}"; do
    if code="$(api_request "$token" "$output_file" GET "$@")" && [[ "$code" =~ ^2 ]]; then
      return 0
    fi
    errors+="HTTP ${code:-curl-failed}: $(head -c 200 "$output_file" 2>/dev/null)"$'\n'
  done
  echo "${errors}" >&2
  return 1
}

fetch_merge_request() {
  local iid="$1"
  local output_file="$2"
  require_unsigned_integer "merge request IID" "$iid"
  get_with_tokens mr_read_tokens "$output_file" \
    --get \
    --data-urlencode "with_merge_status_recheck=true" \
    "${api_base}/merge_requests/${iid}" || fail "failed to read merge request !${iid}"
  jq -e \
    --argjson iid "$iid" \
    --argjson project_id "$CI_PROJECT_ID" '
      .iid == $iid
      and (.state | type) == "string"
      and (.draft | type) == "boolean"
      and (.sha | type) == "string"
      and (.source_branch | type) == "string"
      and (.target_branch | type) == "string"
    ' "$output_file" >/dev/null || fail "merge request !${iid} response is invalid"
}

list_open_renovate_mrs() {
  local output_file="$1"
  local response_file="$tmp_dir/open-merge-requests.json"

  get_with_tokens mr_read_tokens "$response_file" \
    --get \
    --data-urlencode "state=opened" \
    --data-urlencode "target_branch=${CI_COMMIT_REF_NAME}" \
    --data-urlencode "order_by=updated_at" \
    --data-urlencode "sort=desc" \
    --data-urlencode "per_page=100" \
    "${api_base}/merge_requests" || fail "failed to list open merge requests"
  jq -e 'type == "array"' "$response_file" >/dev/null || fail "merge request list response is invalid"
  jq \
    --arg target_branch "$CI_COMMIT_REF_NAME" \
    --arg prefix "$RENOVATE_BRANCH_PREFIX" \
    --argjson project_id "$CI_PROJECT_ID" '
    map(select(
      ((.source_branch // "") | startswith($prefix))
      and .target_branch == $target_branch
      and .source_project_id == $project_id
    ) | {iid: .iid})
  ' "$response_file" >"$output_file"
}

sibling_job_status() {
  local output_file="$tmp_dir/pipeline-jobs.json"
  get_with_tokens pipeline_read_tokens "$output_file" \
    --get \
    --data-urlencode "per_page=100" \
    "${api_base}/pipelines/${CI_PIPELINE_ID}/jobs" || fail "failed to list jobs for pipeline ${CI_PIPELINE_ID}"
  jq -e 'type == "array"' "$output_file" >/dev/null || fail "jobs response for pipeline ${CI_PIPELINE_ID} is invalid"
  jq -r \
    --arg name "$loop_job_name" '
      [.[] | select(.name == $name)]
      | if length == 0 then "missing" else (max_by(.id) | .status) end
    ' "$output_file"
}

merge_merge_request() {
  local iid="$1"
  local attempt
  local response_file
  local http_status
  local state
  local source_project_id
  local source_branch
  local target_branch
  local mr_sha
  local message
  local retry_delay
  local backoff
  local token
  local saw_auth_rejection
  local saw_readiness_failure

  for ((attempt = 1; attempt <= merge_attempts; attempt++)); do
    response_file="$tmp_dir/mr-${iid}-${attempt}.json"
    fetch_merge_request "$iid" "$response_file"

    state="$(jq -r '.state' "$response_file")"
    case "$state" in
      merged)
        echo "Merge request !${iid} is already merged."
        return 0
        ;;
      opened) ;;
      *)
        echo "Merge request !${iid} has state ${state}; skipping."
        return 0
        ;;
    esac

    if [[ "$(jq -r '.draft' "$response_file")" == "true" ]]; then
      echo "Merge request !${iid} is a draft; automatic merge is skipped."
      return 0
    fi

    source_project_id="$(jq -r '.source_project_id // empty' "$response_file")"
    [[ "$source_project_id" == "$CI_PROJECT_ID" ]] || fail "merge request !${iid} does not come from this project"

    source_branch="$(jq -r '.source_branch' "$response_file")"
    target_branch="$(jq -r '.target_branch' "$response_file")"
    [[ -n "$source_branch" ]] || fail "merge request !${iid} source branch is empty"
    [[ "$source_branch" == "${RENOVATE_BRANCH_PREFIX}"* ]] || fail "merge request !${iid} is not a Renovate branch"
    [[ "$target_branch" == "$CI_COMMIT_REF_NAME" ]] || fail "merge request !${iid} target branch is not the default branch"

    if [[ "$(jq -r '.merge_when_pipeline_succeeds // false' "$response_file")" == "true" ]]; then
      echo "Merge request !${iid} has a pipeline-gated auto-merge armed; skipping."
      return 0
    fi

    if [[ "$(jq -r '.has_conflicts // false' "$response_file")" == "true" ]]; then
      echo "Merge request !${iid} has conflicts; automatic merge is skipped."
      return 0
    fi

    mr_sha="$(jq -r '.sha | ascii_downcase' "$response_file")"
    require_sha "merge request !${iid} HEAD sha" "$mr_sha"

    saw_auth_rejection=0
    saw_readiness_failure=0
    for token in "${mr_merge_tokens[@]}"; do
      http_status="$(api_request "$token" "$response_file" PUT \
        --data-urlencode "sha=${mr_sha}" \
        "${api_base}/merge_requests/${iid}/merge")" || fail "merge API request failed"

      case "$http_status" in
        200)
          jq -e --argjson iid "$iid" '.iid == $iid and .state == "merged"' "$response_file" >/dev/null || \
            fail "merge API returned an unexpected success response"
          echo "Merged merge request !${iid} at ${mr_sha} without waiting for pipeline success."
          return 0
          ;;
        401 | 403)
          message="$(jq -r '.message // .error // "token rejected"' "$response_file" 2>/dev/null || printf '%s' 'token rejected')"
          echo "Merge for !${iid} with the current token returned HTTP ${http_status}: ${message}"
          saw_auth_rejection=1
          continue
          ;;
        405 | 422 | 429 | 5??)
          message="$(jq -r '.message // .merge_error // "merge is not ready"' "$response_file" 2>/dev/null || printf '%s' 'merge is not ready')"
          echo "Merge attempt ${attempt}/${merge_attempts} for !${iid} returned HTTP ${http_status}: ${message}"
          saw_readiness_failure=1
          ;;
        409)
          echo "Merge request !${iid} HEAD changed while merging."
          saw_readiness_failure=1
          ;;
        *)
          message="$(jq -r '.message // .error // "unexpected response"' "$response_file" 2>/dev/null || printf '%s' 'unexpected response')"
          fail "merge API returned HTTP ${http_status}: ${message}"
          ;;
      esac
      break
    done

    if ((saw_auth_rejection && !saw_readiness_failure)); then
      fail "no available token can merge merge request !${iid} (last response HTTP ${http_status}: ${message})"
    fi

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

  return 0
}

pipeline_has_loop_job() {
  local pipeline_id="$1"
  local jobs_file="$tmp_dir/cleanup-jobs-${pipeline_id}.json"
  try_get_with_tokens pipeline_read_tokens "$jobs_file" \
    --get \
    --data-urlencode "per_page=100" \
    "${api_base}/pipelines/${pipeline_id}/jobs" >/dev/null || return 1
  jq -e --arg name "$loop_job_name" 'any(.[]; .name == $name)' "$jobs_file" >/dev/null 2>&1
}

# Latest-wins cleanup: consumers receive this from the renovate bridge kind
# (cancel_older_renovate_pipelines.sh running in the downstream controller).
# The toolkit cannot bridge into itself, so the schedule pipeline performs
# the equivalent cancellation directly.
cancel_older_renovate_pipelines() {
  local page=1
  local response_file
  local response_count
  local pipeline_id
  local candidates=()
  local newer_exists=0
  local token
  local code
  local cancel_failed

  while :; do
    ((page <= max_pages)) || fail "pipeline pagination exceeded ${max_pages} pages"
    response_file="$tmp_dir/cleanup-pipelines-page-${page}.json"
    if ! try_get_with_tokens pipeline_read_tokens "$response_file" \
      --get \
      --data-urlencode "order_by=id" \
      --data-urlencode "sort=desc" \
      --data-urlencode "per_page=${page_size}" \
      --data-urlencode "page=${page}" \
      "${api_base}/pipelines"; then
      warn "failed to list pipelines on page ${page}; skipping obsolete-pipeline cleanup"
      return 0
    fi
    jq -e 'type == "array"' "$response_file" >/dev/null || {
      warn "pipeline list response on page ${page} is invalid; skipping obsolete-pipeline cleanup"
      return 0
    }

    while IFS= read -r pipeline_id; do
      [[ -n "$pipeline_id" ]] || continue
      require_unsigned_integer "obsolete candidate pipeline ID" "$pipeline_id"
      if ((pipeline_id > CI_PIPELINE_ID)); then
        newer_exists=1
        continue
      fi
      if pipeline_has_loop_job "$pipeline_id"; then
        candidates+=("$pipeline_id")
      fi
    done < <(
      jq -r \
        --argjson current "$CI_PIPELINE_ID" \
        --argjson active "[${ACTIVE_PIPELINE_STATUSES}]" \
        --argjson sources "[${RENOVATE_PIPELINE_SOURCES}]" '
          .[]
          | select(.id != $current)
          | .source as $source
          | .status as $status
          | select(($sources | index($source)) != null)
          | select(($active | index($status)) != null)
          | .id
        ' "$response_file"
    )

    response_count="$(jq 'length' "$response_file")"
    ((response_count < page_size)) && break
    page=$((page + 1))
  done

  if ((newer_exists)); then
    echo "A newer Renovate pipeline exists; this pipeline is no longer the latest orchestrator."
    return 0
  fi
  if ((${#candidates[@]} == 0)); then
    echo "No obsolete active Renovate pipelines to cancel."
    return 0
  fi

  for pipeline_id in "${candidates[@]}"; do
    echo "Canceling obsolete Renovate pipeline ${pipeline_id}."
    cancel_failed=1
    for token in "${pipeline_cancel_tokens[@]}"; do
      if code="$(api_request "$token" "$tmp_dir/cancel-${pipeline_id}.json" POST \
        "${api_base}/pipelines/${pipeline_id}/cancel")" && [[ "$code" =~ ^2 ]]; then
        cancel_failed=0
        break
      fi
    done
    ((cancel_failed == 0)) || warn "failed to cancel obsolete Renovate pipeline ${pipeline_id}"
  done
}

sweep_open_renovate_mrs() {
  local mrs_file="$tmp_dir/sweep-merge-requests.json"
  local iid

  list_open_renovate_mrs "$mrs_file"
  while IFS= read -r iid; do
    [[ -n "$iid" ]] || continue
    require_unsigned_integer "open merge request IID" "$iid"
    merge_merge_request "$iid"
  done < <(jq -r '.[].iid' "$mrs_file")
}

cancel_older_renovate_pipelines

sibling_status="running"
while :; do
  sibling_status="$(sibling_job_status)"
  case "$sibling_status" in
    success | failed | canceled | skipped | missing)
      break
      ;;
    *) ;;
  esac

  sweep_open_renovate_mrs

  if ((poll_interval > 0)); then
    sleep "$poll_interval"
  fi
done

echo "Serial Renovate loop job ${loop_job_name} finished (${sibling_status}); final merge sweep."
sweep_open_renovate_mrs

remaining_file="$tmp_dir/remaining-merge-requests.json"
list_open_renovate_mrs "$remaining_file"
remaining_count="$(jq 'length' "$remaining_file")"
if ((remaining_count > 0)); then
  remaining_iids="$(jq -r '[.[].iid | tostring] | join(", ")' "$remaining_file")"
  fail "open Renovate merge requests remain and need a manual merge: !${remaining_iids}"
fi

echo "No open Renovate merge requests remain for ${CI_COMMIT_REF_NAME}."
