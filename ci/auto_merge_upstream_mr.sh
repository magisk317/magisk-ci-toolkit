#!/usr/bin/env bash
set -euo pipefail

readonly CONTROLLER_PROJECT_ID="83955109"
readonly CONTROLLER_PROJECT_PATH="magisk3171/shared/magisk-ci-toolkit"
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
: "${MAGISK_CI_MR_AUTOMERGE_TOKEN:?MAGISK_CI_MR_AUTOMERGE_TOKEN is required}"
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

readonly merge_attempts=6
readonly merge_delay=2

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pipeline_auth_header=(--header "PRIVATE-TOKEN: ${MAGISK_CI_PIPELINE_CONTROL_TOKEN}")
merge_auth_header=(--header "PRIVATE-TOKEN: ${MAGISK_CI_MR_AUTOMERGE_TOKEN}")

# Invoked indirectly: api_get_with_retry receives this function's name
# as its first argument, which shellcheck cannot follow.
# shellcheck disable=SC2329 # Called by name from api_get_with_retry below.
pipeline_api_curl() {
  curl --fail --silent --show-error --location "${pipeline_auth_header[@]}" "$@"
}

merge_api_curl() {
  curl --silent --show-error --location "${merge_auth_header[@]}" "$@"
}

[[ "$MAGISK_UPSTREAM_PIPELINE_SOURCE" == "merge_request_event" ]] || fail "upstream pipeline is not a merge request pipeline"
[[ "$MAGISK_UPSTREAM_REF" =~ ^refs/merge-requests/([0-9]+)/head$ ]] || fail "upstream pipeline ref is not a merge request ref"
merge_request_iid="${BASH_REMATCH[1]}"
require_unsigned_integer "merge request IID" "$merge_request_iid"

upstream_project_id="$MAGISK_UPSTREAM_PROJECT_ID"
upstream_project_path="$MAGISK_UPSTREAM_PROJECT_PATH"
upstream_pipeline_id="$MAGISK_UPSTREAM_PIPELINE_ID"
upstream_pipeline_iid="$MAGISK_UPSTREAM_PIPELINE_IID"
expected_upstream_project_id="$(trusted_project_id "$upstream_project_path")" || \
  fail "upstream project is not in the controller allowlist"
expected_target_branch="$(trusted_target_branch "$upstream_project_path")" || \
  fail "upstream project has no trusted target branch"
[[ "$upstream_project_id" == "$expected_upstream_project_id" ]] || fail "upstream project ID mismatch"

pipeline_file="$tmp_dir/upstream-pipeline.json"
if ! api_get_with_retry pipeline_api_curl "$pipeline_file" \
  "${CI_API_V4_URL}/projects/${upstream_project_id}/pipelines/${upstream_pipeline_id}"; then
  fail "failed to read upstream pipeline ${upstream_pipeline_id}"
fi
jq -e \
  --argjson pipeline_id "$upstream_pipeline_id" \
  --argjson pipeline_iid "$upstream_pipeline_iid" \
  --argjson project_id "$upstream_project_id" \
  --arg expected_ref "$MAGISK_UPSTREAM_REF" '
    .id == $pipeline_id
    and .iid == $pipeline_iid
    and .project_id == $project_id
    and .source == "merge_request_event"
    and .ref == $expected_ref
    and (.sha | type) == "string"
    and (.sha | test("^[0-9a-fA-F]{40,64}$"))
  ' "$pipeline_file" >/dev/null || fail "upstream pipeline response is invalid"
upstream_sha="$(jq -r '.sha | ascii_downcase' "$pipeline_file")"


mr_api_url="${CI_API_V4_URL}/projects/${upstream_project_id}/merge_requests/${merge_request_iid}"
mr_file="$tmp_dir/merge-request.json"

fetch_merge_request() {
  if ! api_get_with_retry merge_api_curl "$mr_file" \
    --get \
    --data-urlencode "with_merge_status_recheck=true" \
    "$mr_api_url"; then
    fail "failed to read merge request !${merge_request_iid}"
  fi
  jq -e \
    --argjson iid "$merge_request_iid" \
    --argjson project_id "$upstream_project_id" '
      .iid == $iid
      and .project_id == $project_id
      and .target_project_id == $project_id
      and (.source_project_id | type) == "number"
      and (.state | type) == "string"
      and (.draft | type) == "boolean"
      and (.sha | type) == "string"
      and (.sha | test("^[0-9a-fA-F]{40,64}$"))
      and (.source_branch | type) == "string"
      and (.target_branch | type) == "string"
      and (.title | type) == "string"
    ' "$mr_file" >/dev/null || fail "merge request response is invalid"
}

validate_merge_request() {
  local state
  local source_project_id
  local source_branch
  local target_branch
  local mr_sha

  state="$(jq -r '.state' "$mr_file")"
  if [[ "$state" == "merged" ]]; then
    echo "Merge request ${upstream_project_path}!${merge_request_iid} is already merged."
    return 10
  fi
  [[ "$state" == "opened" ]] || fail "merge request !${merge_request_iid} is not open"

  if [[ "$(jq -r '.draft' "$mr_file")" == "true" ]]; then
    echo "Merge request ${upstream_project_path}!${merge_request_iid} is Draft; automatic merge is skipped."
    return 11
  fi

  source_project_id="$(jq -r '.source_project_id' "$mr_file")"
  if [[ "$source_project_id" != "$upstream_project_id" ]]; then
    echo "Merge request ${upstream_project_path}!${merge_request_iid} comes from another project; automatic merge is skipped."
    return 11
  fi

  source_branch="$(jq -r '.source_branch' "$mr_file")"
  target_branch="$(jq -r '.target_branch' "$mr_file")"
  [[ -n "$source_branch" ]] || fail "merge request source branch is empty"
  [[ "$target_branch" == "$expected_target_branch" ]] || \
    fail "merge request target branch ${target_branch} is not trusted"

  mr_sha="$(jq -r '.sha | ascii_downcase' "$mr_file")"
  [[ "$mr_sha" == "$upstream_sha" ]] || fail "merge request HEAD no longer matches the upstream pipeline"

  if [[ "$(jq -r '.has_conflicts // false' "$mr_file")" == "true" ]]; then
    echo "Merge request ${upstream_project_path}!${merge_request_iid} has conflicts; automatic merge is skipped."
    return 11
  fi

  return 0
}

cancel_scheduled_auto_merge() {
  local cancel_file
  local http_status

  if [[ "$(jq -r '.merge_when_pipeline_succeeds // false' "$mr_file")" != "true" ]]; then
    return 0
  fi

  cancel_file="$tmp_dir/cancel-auto-merge.json"
  # POST through the same retry ladder as the reads: a transient network
  # failure here would otherwise kill the controller after the MR was already
  # validated — the failure class pipeline 2892824485 exposed on the read
  # path, reached a second time through the pipeline-gated auto-merge path.
  if ! http_status="$(api_write_with_retry merge_api_curl "$cancel_file" \
    --request POST \
    "${mr_api_url}/cancel_merge_when_pipeline_succeeds")"; then
    fail "failed to cancel the existing pipeline-gated auto-merge (HTTP ${http_status})"
  fi
  case "$http_status" in
    200 | 201)
      # GitLab currently returns 201 for this state-changing endpoint, while
      # older installations returned 200. Both responses include the MR body.
      ;;
    204)
      # Some GitLab versions acknowledge cancellation without a response body.
      jq '.merge_when_pipeline_succeeds = false' "$mr_file" >"$cancel_file"
      ;;
    *)
      fail "canceling the existing pipeline-gated auto-merge returned HTTP ${http_status}"
      ;;
  esac
  jq -e \
    --argjson iid "$merge_request_iid" \
    '.iid == $iid and .state == "opened" and (.merge_when_pipeline_succeeds // false) == false' \
    "$cancel_file" >/dev/null || fail "cancel auto-merge API returned an unexpected response"
  cp "$cancel_file" "$mr_file"
  echo "Canceled the existing pipeline-gated auto-merge for ${upstream_project_path}!${merge_request_iid}."
}

fetch_merge_request
validation_status=0
validate_merge_request || validation_status=$?
case "$validation_status" in
  0) ;;
  10 | 11) exit 0 ;;
  *) exit "$validation_status" ;;
esac
cancel_scheduled_auto_merge

echo "Validated ${upstream_project_path}!${merge_request_iid} at ${upstream_sha}; pipeline status is intentionally not a merge gate."

for ((attempt = 1; attempt <= merge_attempts; attempt++)); do
  if ((attempt > 1)); then
    fetch_merge_request
    validation_status=0
    validate_merge_request || validation_status=$?
    case "$validation_status" in
      0) ;;
      10) exit 0 ;;
      11) exit 0 ;;
      *) exit "$validation_status" ;;
    esac
    cancel_scheduled_auto_merge
  fi

  response_file="$tmp_dir/merge-response-${attempt}.json"
  merge_args=(
    --request PUT
    --data-urlencode "sha=${upstream_sha}"
  )
  source_branch="$(jq -r '.source_branch' "$mr_file")"
  if [[ "$source_branch" == ci/skip-post-merge/* ]]; then
    merge_title="$(jq -r '.title | gsub("[\\r\\n]+"; " ")' "$mr_file")"
    merge_args+=(
      --data-urlencode "merge_commit_message=[skip ci] Merge !${merge_request_iid}: ${merge_title}"
    )
    echo "Post-merge pipeline will be skipped for trusted rollout branch ${source_branch}."
  fi

  if ! http_status="$(
    merge_api_curl \
      "${merge_args[@]}" \
      --output "$response_file" \
      --write-out '%{http_code}' \
      "${mr_api_url}/merge"
  )"; then
    fail "merge API request failed"
  fi

  case "$http_status" in
    200)
      jq -e \
        --argjson iid "$merge_request_iid" \
        '.iid == $iid and .state == "merged" and (.merge_when_pipeline_succeeds // false) == false' \
        "$response_file" >/dev/null || fail "merge API returned an unexpected success response"
      echo "Merged ${upstream_project_path}!${merge_request_iid} immediately without waiting for pipeline success."
      exit 0
      ;;
    405 | 422 | 429 | 5??)
      message="$(jq -r '.message // .merge_error // "merge is not ready"' "$response_file" 2>/dev/null || printf '%s' 'merge is not ready')"
      echo "Merge attempt ${attempt}/${merge_attempts} returned HTTP ${http_status}: ${message}"
      ;;
    409)
      fail "merge request HEAD changed while merging"
      ;;
    401 | 403)
      fail "merge token is not authorized (HTTP ${http_status})"
      ;;
    *)
      message="$(jq -r '.message // .error // "unexpected response"' "$response_file" 2>/dev/null || printf '%s' 'unexpected response')"
      fail "merge API returned HTTP ${http_status}: ${message}"
      ;;
  esac

  if ((attempt < merge_attempts)); then
    retry_delay="$merge_delay"
    for ((backoff = 1; backoff < attempt; backoff++)); do
      retry_delay=$((retry_delay * 2))
    done
    echo "Waiting ${retry_delay}s before merge attempt $((attempt + 1))/${merge_attempts}."
    sleep "$retry_delay"
  fi
done

fetch_merge_request
detailed_status="$(jq -r '.detailed_merge_status // .merge_status // "unknown"' "$mr_file")"
fail "merge request !${merge_request_iid} did not become mergeable after ${merge_attempts} attempts (status: ${detailed_status})"
