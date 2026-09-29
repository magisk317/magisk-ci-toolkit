#!/usr/bin/env bash
set -euo pipefail

readonly CONTROLLER_PROJECT_ID="83955109"
readonly CONTROLLER_PROJECT_PATH="magisk3171/shared/magisk-ci-toolkit"
readonly ACTIVE_PIPELINE_STATUSES='["created","waiting_for_resource","preparing","pending","running","manual","scheduled"]'
readonly RENOVATE_PIPELINE_SOURCES='["schedule","web","api"]'
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

require_sha() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9a-fA-F]{40,64}$ ]] || fail "$name is not a commit SHA"
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
[[ "$MAGISK_UPSTREAM_PIPELINE_SOURCE" == "schedule" || \
  "$MAGISK_UPSTREAM_PIPELINE_SOURCE" == "web" || \
  "$MAGISK_UPSTREAM_PIPELINE_SOURCE" == "api" ]] || \
  fail "upstream pipeline source must be schedule, web, or api"
[[ "$MAGISK_UPSTREAM_REF" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "upstream Renovate ref is invalid"

require_unsigned_integer "CI_PIPELINE_ID" "$CI_PIPELINE_ID"
require_unsigned_integer "CI_PIPELINE_IID" "$CI_PIPELINE_IID"
require_unsigned_integer "MAGISK_UPSTREAM_PROJECT_ID" "$MAGISK_UPSTREAM_PROJECT_ID"
require_unsigned_integer "MAGISK_UPSTREAM_PIPELINE_ID" "$MAGISK_UPSTREAM_PIPELINE_ID"
require_unsigned_integer "MAGISK_UPSTREAM_PIPELINE_IID" "$MAGISK_UPSTREAM_PIPELINE_IID"

expected_upstream_project_id="$(trusted_project_id "$MAGISK_UPSTREAM_PROJECT_PATH")" || \
  fail "upstream project is not in the controller allowlist"
expected_target_branch="$(trusted_target_branch "$MAGISK_UPSTREAM_PROJECT_PATH")" || \
  fail "upstream project has no trusted target branch"
[[ "$MAGISK_UPSTREAM_PROJECT_ID" == "$expected_upstream_project_id" ]] || \
  fail "upstream project ID mismatch"
[[ "$MAGISK_UPSTREAM_REF" == "$expected_target_branch" ]] || \
  fail "upstream Renovate ref is not the trusted target branch"

page_size="${MAGISK_CI_PIPELINE_PAGE_SIZE:-100}"
max_pages="${MAGISK_CI_PIPELINE_MAX_PAGES:-1000}"
reconcile_passes="${MAGISK_CI_PIPELINE_RECONCILE_PASSES:-3}"
reconcile_delay="${MAGISK_CI_PIPELINE_RECONCILE_DELAY_SECONDS:-1}"
require_unsigned_integer "MAGISK_CI_PIPELINE_PAGE_SIZE" "$page_size"
require_unsigned_integer "MAGISK_CI_PIPELINE_MAX_PAGES" "$max_pages"
require_unsigned_integer "MAGISK_CI_PIPELINE_RECONCILE_PASSES" "$reconcile_passes"
require_unsigned_integer "MAGISK_CI_PIPELINE_RECONCILE_DELAY_SECONDS" "$reconcile_delay"
((page_size > 0 && page_size <= 100)) || fail "MAGISK_CI_PIPELINE_PAGE_SIZE must be between 1 and 100"
((max_pages > 0)) || fail "MAGISK_CI_PIPELINE_MAX_PAGES must be greater than zero"
((reconcile_passes > 0)) || fail "MAGISK_CI_PIPELINE_RECONCILE_PASSES must be greater than zero"

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

auth_header=(--header "PRIVATE-TOKEN: ${MAGISK_CI_PIPELINE_CONTROL_TOKEN}")
api_base="${CI_API_V4_URL%/}/projects/${MAGISK_UPSTREAM_PROJECT_ID}"

api_curl() {
  curl --fail --silent --show-error --location "${auth_header[@]}" "$@"
}

upstream_pipeline_file="$tmp_dir/upstream-pipeline.json"
if ! api_get_with_retry api_curl "$upstream_pipeline_file" \
  "${api_base}/pipelines/${MAGISK_UPSTREAM_PIPELINE_ID}"; then
  fail "failed to read upstream pipeline ${MAGISK_UPSTREAM_PIPELINE_ID}"
fi
jq -e \
  --argjson pipeline_id "$MAGISK_UPSTREAM_PIPELINE_ID" \
  --argjson pipeline_iid "$MAGISK_UPSTREAM_PIPELINE_IID" \
  --argjson project_id "$MAGISK_UPSTREAM_PROJECT_ID" \
  --arg source "$MAGISK_UPSTREAM_PIPELINE_SOURCE" \
  --arg ref "$MAGISK_UPSTREAM_REF" '
    .id == $pipeline_id
    and .iid == $pipeline_iid
    and .project_id == $project_id
    and .source == $source
    and .ref == $ref
    and (.created_at | type) == "string"
  ' "$upstream_pipeline_file" >/dev/null || fail "upstream Renovate pipeline response is invalid"

list_pipeline_jobs() {
  local pipeline_id="$1"
  local output_file="$2"
  if ! api_get_with_retry api_curl "$output_file" \
    --get \
    --data-urlencode 'per_page=100' \
    "${api_base}/pipelines/${pipeline_id}/jobs"; then
    fail "failed to list jobs for Renovate pipeline ${pipeline_id}"
  fi
  jq -e 'type == "array"' "$output_file" >/dev/null || \
    fail "jobs response for pipeline ${pipeline_id} is invalid"
}

pipeline_is_renovate() {
  local pipeline_id="$1"
  local jobs_file="$tmp_dir/jobs-${pipeline_id}.json"
  list_pipeline_jobs "$pipeline_id" "$jobs_file"
  jq -e 'any(.[]; .name == "renovate:gitlab")' "$jobs_file" >/dev/null
}

list_renovate_pipelines() {
  local output_file="$1"
  local ndjson_file="$tmp_dir/renovate-pipelines.ndjson"
  local page=1
  local response_file
  local response_count
  local pipeline_id

  : >"$ndjson_file"
  while :; do
    ((page <= max_pages)) || fail "pipeline pagination exceeded ${max_pages} pages"
    response_file="$tmp_dir/pipelines-page-${page}.json"
    if ! api_get_with_retry api_curl "$response_file" \
      --get \
      --data-urlencode 'order_by=id' \
      --data-urlencode 'sort=desc' \
      --data-urlencode "per_page=${page_size}" \
      --data-urlencode "page=${page}" \
      "${api_base}/pipelines"; then
      fail "failed to list pipelines on page ${page}"
    fi
    jq -e 'type == "array" and all(.[]; (.id | type) == "number" and (.source | type) == "string" and (.ref | type) == "string" and (.created_at | type) == "string")' "$response_file" >/dev/null || \
      fail "pipeline list response on page ${page} is invalid"

    while IFS= read -r pipeline_id; do
      if [[ "$pipeline_id" == "$MAGISK_UPSTREAM_PIPELINE_ID" ]] || pipeline_is_renovate "$pipeline_id"; then
        jq -c --argjson id "$pipeline_id" '.[] | select(.id == $id)' "$response_file" >>"$ndjson_file"
      fi
    done < <(
      jq -r \
        --arg ref "$MAGISK_UPSTREAM_REF" \
        --argjson sources "$RENOVATE_PIPELINE_SOURCES" '
          .[]
          | .source as $source
          | select(.ref == $ref and (($sources | index($source)) != null))
          | .id
        ' "$response_file"
    )

    response_count="$(jq 'length' "$response_file")"
    ((response_count < page_size)) && break
    page=$((page + 1))
  done

  if [[ -s "$ndjson_file" ]]; then
    jq -s 'unique_by(.id) | sort_by(.id)' "$ndjson_file" >"$output_file"
  else
    printf '[]\n' >"$output_file"
  fi
}

find_cancel_candidates() {
  local pipelines_file="$1"
  local output_file="$2"
  local latest_id
  local current_created_at

  current_created_at="$(jq -r '.created_at' "$upstream_pipeline_file")"
  latest_id="$(
    jq -r \
      --argjson current_id "$MAGISK_UPSTREAM_PIPELINE_ID" \
      --arg current_source "$MAGISK_UPSTREAM_PIPELINE_SOURCE" \
      --arg current_ref "$MAGISK_UPSTREAM_REF" \
      --arg current_created_at "$current_created_at" '
        (map(select(.ref == $current_ref))
          + [{id: $current_id, source: $current_source, ref: $current_ref, created_at: $current_created_at}])
        | max_by([.created_at, .id])
        | .id
      ' "$pipelines_file"
  )"
  require_unsigned_integer "latest Renovate pipeline ID" "$latest_id"

  jq -r \
    --argjson current "$MAGISK_UPSTREAM_PIPELINE_ID" \
    --arg current_created_at "$current_created_at" \
    --arg current_ref "$MAGISK_UPSTREAM_REF" \
    --argjson active "$ACTIVE_PIPELINE_STATUSES" '
      .[]
      | select(.ref == $current_ref and .id != $current)
      | .status as $status
      | select(($active | index($status)) != null)
      | select((.created_at < $current_created_at) or (.created_at == $current_created_at and .id < $current))
      | .id
    ' "$pipelines_file" >"$output_file"

  printf '%s\n' "$latest_id"
}

cancel_candidates() {
  local candidates_file="$1"
  local pass="$2"
  local pipeline_id
  local cancel_file

  while IFS= read -r pipeline_id; do
    require_unsigned_integer "cancel candidate pipeline ID" "$pipeline_id"
    echo "Canceling older Renovate pipeline ${pipeline_id}."
    cancel_file="$tmp_dir/cancel-${pass}-${pipeline_id}.json"
    if ! api_curl --request POST --output "$cancel_file" \
      "${api_base}/pipelines/${pipeline_id}/cancel"; then
      echo "Warning: failed to cancel Renovate pipeline ${pipeline_id}; it will be checked again." >&2
    fi
  done <"$candidates_file"
}

echo "Validated upstream Renovate pipeline ${MAGISK_UPSTREAM_PROJECT_PATH}#${MAGISK_UPSTREAM_PIPELINE_ID} (${MAGISK_UPSTREAM_REF})."

for ((pass = 1; pass <= reconcile_passes; pass++)); do
  pipelines_file="$tmp_dir/renovate-pipelines-${pass}.json"
  candidates_file="$tmp_dir/renovate-candidates-${pass}.txt"
  list_renovate_pipelines "$pipelines_file"
  latest_pipeline_id="$(find_cancel_candidates "$pipelines_file" "$candidates_file")"

  if [[ "$latest_pipeline_id" != "$MAGISK_UPSTREAM_PIPELINE_ID" ]]; then
    echo "A newer Renovate pipeline ${latest_pipeline_id} wins; current pipeline exits without canceling it."
    exit 0
  fi
  if [[ ! -s "$candidates_file" ]]; then
    echo "Latest Renovate pipeline is ${latest_pipeline_id}; no older active Renovate pipelines remain."
    exit 0
  fi

  echo "Latest Renovate pipeline is ${latest_pipeline_id}; reconciliation pass ${pass}."
  cancel_candidates "$candidates_file" "$pass"
  if ((pass < reconcile_passes && reconcile_delay > 0)); then
    sleep "$reconcile_delay"
  fi
done

pipelines_file="$tmp_dir/renovate-pipelines-final.json"
candidates_file="$tmp_dir/renovate-candidates-final.txt"
list_renovate_pipelines "$pipelines_file"
latest_pipeline_id="$(find_cancel_candidates "$pipelines_file" "$candidates_file")"
if [[ "$latest_pipeline_id" != "$MAGISK_UPSTREAM_PIPELINE_ID" ]]; then
  echo "A newer Renovate pipeline ${latest_pipeline_id} wins."
  exit 0
fi
if [[ -s "$candidates_file" ]]; then
  remaining="$(paste -sd, "$candidates_file")"
  fail "older active Renovate pipelines remain after reconciliation: ${remaining}"
fi

echo "Latest Renovate pipeline is ${latest_pipeline_id}; all older active Renovate pipelines are canceled."
