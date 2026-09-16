#!/usr/bin/env bash
set -euo pipefail

readonly CONTROLLER_PROJECT_ID="83955109"
readonly CONTROLLER_PROJECT_PATH="magisk3171/shared/magisk-ci-toolkit"
readonly ACTIVE_PIPELINE_STATUSES='["created","waiting_for_resource","preparing","pending","running","manual","scheduled"]'
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/trusted_projects.sh
source "$script_dir/trusted_projects.sh"

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
require_unsigned_integer "MAGISK_CI_PIPELINE_PAGE_SIZE" "$page_size"
require_unsigned_integer "MAGISK_CI_PIPELINE_MAX_PAGES" "$max_pages"
require_unsigned_integer "MAGISK_CI_PIPELINE_RECONCILE_PASSES" "$reconcile_passes"
require_unsigned_integer "MAGISK_CI_PIPELINE_RECONCILE_DELAY_SECONDS" "$reconcile_delay"
((page_size > 0 && page_size <= 100)) || fail "MAGISK_CI_PIPELINE_PAGE_SIZE must be between 1 and 100"
((max_pages > 0)) || fail "MAGISK_CI_PIPELINE_MAX_PAGES must be greater than zero"
((reconcile_passes > 0)) || fail "MAGISK_CI_PIPELINE_RECONCILE_PASSES must be greater than zero"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

auth_header=(--header "PRIVATE-TOKEN: ${MAGISK_CI_PIPELINE_CONTROL_TOKEN}")

api_curl() {
  curl --fail --silent --show-error --location "${auth_header[@]}" "$@"
}

if [[ "$MAGISK_UPSTREAM_PIPELINE_SOURCE" == "merge_request_event" ]]; then
  [[ "$MAGISK_UPSTREAM_REF" =~ ^refs/merge-requests/[0-9]+/head$ ]] || \
    fail "upstream merge request pipeline ref is invalid"
elif [[ "$MAGISK_UPSTREAM_PIPELINE_SOURCE" == "push" ]]; then
  [[ "$MAGISK_UPSTREAM_REF" =~ ^[A-Za-z0-9._/-]+$ ]] || \
    fail "upstream push pipeline ref is invalid"
else
  fail "upstream pipeline source must be merge_request_event or push"
fi
upstream_project_id="$MAGISK_UPSTREAM_PROJECT_ID"
upstream_project_path="$MAGISK_UPSTREAM_PROJECT_PATH"
upstream_pipeline_id="$MAGISK_UPSTREAM_PIPELINE_ID"
upstream_pipeline_iid="$MAGISK_UPSTREAM_PIPELINE_IID"
upstream_ref="$MAGISK_UPSTREAM_REF"
expected_upstream_project_id="$(trusted_project_id "$upstream_project_path")" || \
  fail "upstream project is not in the controller allowlist"
[[ "$upstream_project_id" == "$expected_upstream_project_id" ]] || fail "upstream project ID mismatch"

api_base="${CI_API_V4_URL}/projects/${upstream_project_id}/pipelines"

upstream_pipeline_file="$tmp_dir/upstream-pipeline.json"
if ! api_curl \
  --output "$upstream_pipeline_file" \
  "${api_base}/${upstream_pipeline_id}"; then
  fail "failed to read upstream pipeline ${upstream_pipeline_id}"
fi
jq -e \
  --argjson pipeline_id "$upstream_pipeline_id" \
  --argjson pipeline_iid "$upstream_pipeline_iid" \
  --argjson project_id "$upstream_project_id" \
  --arg expected_ref "$upstream_ref" '
    .id == $pipeline_id
    and .iid == $pipeline_iid
    and .project_id == $project_id
    and (.source == "merge_request_event" or .source == "push")
    and .ref == $expected_ref
    and (.created_at | type) == "string"
  ' "$upstream_pipeline_file" >/dev/null || fail "upstream pipeline response is invalid"
list_merge_request_pipelines() {
  local output_file="$1"
  local ndjson_file="$tmp_dir/pipelines.ndjson"
  local page=1
  local body_file
  local response_count

  : >"$ndjson_file"
  while :; do
    ((page <= max_pages)) || fail "pipeline pagination exceeded ${max_pages} pages"
    body_file="$tmp_dir/pipelines-page-${page}.json"
    if ! api_curl \
      --get \
      --data-urlencode "order_by=id" \
      --data-urlencode "sort=desc" \
      --data-urlencode "per_page=${page_size}" \
      --data-urlencode "page=${page}" \
      --output "$body_file" \
      "$api_base"; then
      fail "failed to list merge request pipelines on page ${page}"
    fi
    jq -e 'type == "array" and all(.[]; (.id | type) == "number" and (.source | type) == "string" and (.created_at | type) == "string")' "$body_file" >/dev/null || \
      fail "pipeline list response on page ${page} is invalid"
    jq -c '.[]' "$body_file" >>"$ndjson_file"
    response_count="$(jq 'length' "$body_file")"
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
      --argjson current_id "$upstream_pipeline_id" \
      --arg current_source "$MAGISK_UPSTREAM_PIPELINE_SOURCE" \
      --arg current_ref "$upstream_ref" \
      --arg current_created_at "$current_created_at" '
        (map(select((.source == "merge_request_event" or .source == "push") and .ref == $current_ref))
          + [{id: $current_id, source: $current_source, ref: $current_ref, created_at: $current_created_at}])
        | max_by([.created_at, .id])
        | .id
      ' "$pipelines_file"
  )"
  require_unsigned_integer "latest project pipeline ID" "$latest_id"

  jq -r \
    --argjson current "$upstream_pipeline_id" \
    --arg current_created_at "$current_created_at" \
    --arg current_ref "$upstream_ref" \
    --argjson active "$ACTIVE_PIPELINE_STATUSES" '
      .[]
      | select((.source == "merge_request_event" or .source == "push") and .ref == $current_ref)
      | select(.id != $current)
      | .status as $status
      | select(($active | index($status)) != null)
      | select(
          (.created_at < $current_created_at)
          or (.created_at == $current_created_at and .id < $current)
        )
      | .id
    ' "$pipelines_file" >"$output_file"

  printf '%s\n' "$latest_id"
}

echo "Validated upstream ${upstream_project_path} pipeline ${upstream_pipeline_id} (${upstream_ref})."

for ((pass = 1; pass <= reconcile_passes; pass++)); do
  pipelines_file="$tmp_dir/pipelines-${pass}.json"
  candidates_file="$tmp_dir/candidates-${pass}.txt"
  list_merge_request_pipelines "$pipelines_file"
  latest_pipeline_id="$(find_cancel_candidates "$pipelines_file" "$candidates_file")"

  if [[ "$latest_pipeline_id" != "$upstream_pipeline_id" ]]; then
    echo "Upstream pipeline ${upstream_pipeline_id} is no longer latest; pipeline ${latest_pipeline_id} wins, so this controller exits without canceling newer work."
    exit 0
  fi

  if [[ ! -s "$candidates_file" ]]; then
    echo "Latest project pipeline is ${latest_pipeline_id}; no older active MR/push pipelines remain."
    exit 0
  fi

  echo "Latest project pipeline is ${latest_pipeline_id}; reconciliation pass ${pass}."
  while IFS= read -r pipeline_id; do
    require_unsigned_integer "cancel candidate pipeline ID" "$pipeline_id"
    echo "Canceling older MR/push pipeline ${pipeline_id}."
    cancel_file="$tmp_dir/cancel-${pass}-${pipeline_id}.json"
    if ! api_curl \
      --request POST \
      --output "$cancel_file" \
      "${api_base}/${pipeline_id}/cancel"; then
      echo "Warning: failed to cancel pipeline ${pipeline_id}; it will be checked again." >&2
    fi
  done <"$candidates_file"

  if ((pass < reconcile_passes && reconcile_delay > 0)); then
    sleep "$reconcile_delay"
  fi
done

pipelines_file="$tmp_dir/pipelines-final.json"
candidates_file="$tmp_dir/candidates-final.txt"
list_merge_request_pipelines "$pipelines_file"
latest_pipeline_id="$(find_cancel_candidates "$pipelines_file" "$candidates_file")"
if [[ "$latest_pipeline_id" != "$upstream_pipeline_id" ]]; then
  echo "Upstream pipeline ${upstream_pipeline_id} is no longer latest; pipeline ${latest_pipeline_id} wins."
  exit 0
fi
if [[ -s "$candidates_file" ]]; then
  remaining="$(paste -sd, "$candidates_file")"
  fail "older active MR/push pipelines remain after reconciliation: ${remaining}"
fi

echo "Latest project pipeline is ${latest_pipeline_id}; all older active MR/push pipelines are canceled."
