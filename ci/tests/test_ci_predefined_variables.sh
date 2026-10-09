#!/usr/bin/env bash
# Guard the GitLab CI YAML layer against typos in predefined variable names.
# GitLab silently expands an unknown predefined variable to an empty string, so
# a typo disables a feature without failing anything. Regression this prevents:
# on 2026-09-29 the cross-family cancel anchor referenced
# CI_MERGE_REQUEST_SOURCE_BRANCH, which is not a GitLab predefined variable (the
# real name is CI_MERGE_REQUEST_SOURCE_BRANCH_NAME), so
# MAGISK_UPSTREAM_SOURCE_BRANCH was always empty and the controller silently
# skipped cross-family cancellation. The controller contract tests missed it:
# they run the script with the variable set and never exercise the YAML
# plumbing that sets it.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

# Every GitLab predefined variable the GitLab CI YAML files may reference.
# Exhaustive on purpose: an unknown name must fail here instead of expanding
# empty in production. Extend deliberately when adopting a new predefined
# variable after verifying the exact name in the GitLab reference (note the
# asymmetry: the MR source branch is CI_MERGE_REQUEST_SOURCE_BRANCH_NAME while
# the MR ref path is CI_MERGE_REQUEST_REF_PATH).
allowed_predefined_variables='CI_ALL_PROXY
CI_COMMIT_BRANCH
CI_COMMIT_REF_NAME
CI_COMMIT_REF_SLUG
CI_COMMIT_TAG
CI_DEFAULT_BRANCH
CI_HTTP_PROXY
CI_HTTPS_PROXY
CI_MERGE_REQUEST_REF_PATH
CI_MERGE_REQUEST_SOURCE_BRANCH_NAME
CI_NO_PROXY
CI_PIPELINE_ID
CI_PIPELINE_IID
CI_PIPELINE_SOURCE
CI_PIPELINE_URL
CI_PROJECT_DIR
CI_PROJECT_ID
CI_PROJECT_NAME
CI_PROJECT_PATH
CI_PROJECT_URL'

status=0

# 1. No unknown predefined variable names anywhere in the GitLab CI YAML.
mapfile -t referenced_variables < <(
  grep -rhoE '[$]CI_[A-Z_]+' .gitlab-ci.yml .gitlab/ci/*.yml | tr -d '$' | sort -u
)
for variable in "${referenced_variables[@]}"; do
  if ! printf '%s\n' "$allowed_predefined_variables" | grep -qx "$variable"; then
    printf 'FAIL: $%s is not a known GitLab predefined variable (GitLab expands unknown names to an empty string)\n' "$variable" >&2
    status=1
  fi
done

# 2. The cross-family anchor must wire the MR source branch from the correct
#    variable, and the _NAME-less variant must not come back.
if ! grep -q 'MAGISK_UPSTREAM_SOURCE_BRANCH: "[$]CI_MERGE_REQUEST_SOURCE_BRANCH_NAME"' .gitlab/ci/cancel-mr-pipelines.yml; then
  printf 'FAIL: cancel-mr-pipelines.yml must set MAGISK_UPSTREAM_SOURCE_BRANCH from CI_MERGE_REQUEST_SOURCE_BRANCH_NAME\n' >&2
  status=1
fi
if grep -rq '[$]CI_MERGE_REQUEST_SOURCE_BRANCH"' .gitlab-ci.yml .gitlab/ci/*.yml; then
  printf 'FAIL: the non-existent CI_MERGE_REQUEST_SOURCE_BRANCH (missing _NAME suffix) is referenced again\n' >&2
  status=1
fi

# 3. No variable may be defined from a reference to its own key. GitLab does
#    not expand a self-reference in a trigger job's variables block: the
#    downstream pipeline receives the literal "$KEY", which also shadows the
#    value GitLab forwards from the upstream pipeline. Regression this
#    prevents: MAGISK_CANCEL_MERGED_MR_PIPELINES was forwarded as
#    "$MAGISK_CANCEL_MERGED_MR_PIPELINES", so the post-merge cleanup silently
#    never ran.
while IFS= read -r match; do
  location="${match%%:*}"
  rest="${match#*:}"
  line="${rest#*:}"
  key="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*([A-Z0-9_]+):.*/\1/')"
  referenced="$(printf '%s' "$line" | sed -E 's/.*"\$([A-Z0-9_]+)".*/\1/')"
  if [[ "$key" == "$referenced" ]]; then
    printf 'FAIL: %s defines %s from "$%s"; GitLab passes the literal string downstream\n' \
      "$location" "$key" "$referenced" >&2
    status=1
  fi
done < <(grep -rnE '^[[:space:]]+[A-Z0-9_]+: "\$[A-Z0-9_]+"' .gitlab-ci.yml .gitlab/ci/*.yml)

if ((status == 0)); then
  printf 'OK: %d predefined variable references are known-good\n' "${#referenced_variables[@]}"
fi
exit "$status"
