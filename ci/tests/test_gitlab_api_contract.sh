#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="$root_dir/ci/gitlab_api.sh"
source "$helper"

GITLAB_TOKEN=token
mapfile -t args < <(gitlab_api_auth_args)
[[ "${args[0]}" == "--header" ]] || { echo "missing auth flag" >&2; exit 1; }
[[ "${args[1]}" == "PRIVATE-TOKEN: token" ]] || { echo "wrong private token header" >&2; exit 1; }

unset GITLAB_TOKEN
CI_JOB_TOKEN=job-token
mapfile -t args < <(gitlab_api_auth_args)
[[ "${args[1]}" == "JOB-TOKEN: job-token" ]] || { echo "wrong job token header" >&2; exit 1; }

GITLAB_API_BASE_URL=https://example.test/api/v4
[[ "$(gitlab_api_base_url)" == "https://example.test/api/v4" ]] || { echo "wrong base URL" >&2; exit 1; }

if GITLAB_TOKEN= GITLAB_API_BASE_URL= CI_JOB_TOKEN= gitlab_api_auth_args >/dev/null 2>&1; then
  echo "missing credentials unexpectedly passed" >&2
  exit 1
fi

echo 'GitLab API contract tests passed'
