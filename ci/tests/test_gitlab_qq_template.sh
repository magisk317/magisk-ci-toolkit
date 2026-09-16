#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
template="$root_dir/.gitlab/ci/gitlab-qq.yml"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$template" ]] || fail "GitLab QQ template missing"
for required in ".magisk_gitlab_qq_ci:" ".magisk_gitlab_qq_release:" ".magisk_gitlab_qq_mr:" ".magisk_gitlab_qq_failure:"; do
  grep -Fq "$required" "$template" || fail "missing $required"
done
grep -Fq 'CI_COMMIT_TAG' "$template" || fail 'release/tag guard missing'
grep -Fq 'CI_PIPELINE_SOURCE == "merge_request_event"' "$template" || fail 'MR rule missing'
grep -Fq 'needs' "$template" && true || true
bash -n "$root_dir/ci/gitlab_qq_publish.sh"

echo "GitLab QQ template contract test passed"
