#!/usr/bin/env bash
set -euo pipefail

gitlab_api_auth_args() {
  if [[ -n "${CI_JOB_TOKEN:-}" ]]; then
    printf '%s\n' --header "JOB-TOKEN: ${CI_JOB_TOKEN}"
  elif [[ -n "${GITLAB_RELEASE_TOKEN:-}" ]]; then
    printf '%s\n' --header "PRIVATE-TOKEN: ${GITLAB_RELEASE_TOKEN}"
  elif [[ -n "${GITLAB_TOKEN:-}" ]]; then
    printf '%s\n' --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}"
  elif [[ -n "${GITLAB_DEPLOY_TOKEN:-}" ]]; then
    printf '%s\n' --header "DEPLOY-TOKEN: ${GITLAB_DEPLOY_TOKEN}"
  else
    echo "CI_JOB_TOKEN, GITLAB_RELEASE_TOKEN, GITLAB_TOKEN, or GITLAB_DEPLOY_TOKEN is required" >&2
    return 1
  fi
}

gitlab_api_base_url() {
  if [[ -n "${GITLAB_API_BASE_URL:-}" ]]; then
    printf '%s\n' "${GITLAB_API_BASE_URL%/}"
  elif [[ -n "${CI_API_V4_URL:-}" ]]; then
    printf '%s\n' "${CI_API_V4_URL%/}"
  else
    printf '%s\n' "https://gitlab.com/api/v4"
  fi
}

gitlab_api_curl() {
  local endpoint="$1"
  shift
  local -a auth_args=()
  while IFS= read -r line; do
    auth_args+=("$line")
  done < <(gitlab_api_auth_args)
  curl --silent --show-error --location \
    --retry "${GITLAB_API_RETRIES:-3}" \
    --retry-delay "${GITLAB_API_RETRY_DELAY:-2}" \
    "${auth_args[@]}" "$@" \
    "$(gitlab_api_base_url)/${endpoint#/}"
}

gitlab_api_curl_fail() {
  local endpoint="$1"
  shift
  local -a auth_args=()
  while IFS= read -r line; do
    auth_args+=("$line")
  done < <(gitlab_api_auth_args)
  curl --silent --show-error --fail-with-body --location \
    --retry "${GITLAB_API_RETRIES:-3}" \
    --retry-delay "${GITLAB_API_RETRY_DELAY:-2}" \
    "${auth_args[@]}" "$@" \
    "$(gitlab_api_base_url)/${endpoint#/}"
}

gitlab_api_curl_url() {
  local -a auth_args=()
  while IFS= read -r line; do
    auth_args+=("$line")
  done < <(gitlab_api_auth_args)
  curl --silent --show-error --location \
    --retry "${GITLAB_API_RETRIES:-3}" \
    --retry-delay "${GITLAB_API_RETRY_DELAY:-2}" \
    "${auth_args[@]}" "$@"
}

gitlab_api_get() {
  gitlab_api_curl "$1"
}

gitlab_api_json() {
  local payload="$1"
  python3 - "$payload" <<'PY'
import json
import sys
json.loads(sys.argv[1])
PY
}
