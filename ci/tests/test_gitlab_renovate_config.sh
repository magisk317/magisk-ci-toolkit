#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
template="$root_dir/.gitlab/ci/renovate.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_json_eq() {
  local expected="$1" filter="$2" file="$3" message="$4"
  local actual
  actual="$(node -e "const cfg=require(process.argv[1]); const value=(${filter}); console.log(Array.isArray(value) ? JSON.stringify(value) : String(value));" "$file")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

command -v node >/dev/null || fail "node is required to run the Renovate config tests"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

renovate_node_script="$tmp_dir/generate-config.js"
sed -n "/node <<'NODE' > config.js/,/^[[:space:]]*NODE$/p" "$template" | sed '1d;$d' > "$renovate_node_script"
[[ -s "$renovate_node_script" ]] || fail "GitLab Renovate dynamic config heredoc was not found"

(
  cd "$tmp_dir"
  mkdir -p .gitlab
  : > .gitlab/renovate.json
  MAGISK_RENOVATE_REPOSITORY="magisk3171/demo" \
  MAGISK_RENOVATE_PLATFORM_AUTOMERGE="false" \
  MAGISK_RENOVATE_IGNORE_TESTS="true" \
  CI_JOB_TOKEN="job-token" \
  CI_JOB_ID="job-id" \
  MAGISK_RENOVATE_GIT_AUTHOR="CI Bot <ci@example.invalid>" \
    node "$renovate_node_script" > config.js
)

config_file="$tmp_dir/config.js"
assert_json_eq "gitlab" "cfg.platform" "$config_file" "GitLab platform"
assert_json_eq '["magisk3171/demo"]' "cfg.repositories" "$config_file" "repository list"
assert_json_eq '[".gitlab/renovate.json"]' "cfg.configFileNames" "$config_file" "GitLab config preference"
assert_json_eq "true" "cfg.dependencyDashboard" "$config_file" "dependency dashboard enabled"
assert_json_eq "all" "cfg.dependencyDashboardOSVVulnerabilitySummary" "$config_file" "dashboard vulnerability summary"
assert_json_eq "false" "cfg.platformAutomerge" "$config_file" "platform automerge env override"
assert_json_eq "false" "cfg.automerge" "$config_file" "Renovate direct automerge disabled"
assert_json_eq "1" "cfg.prConcurrentLimit" "$config_file" "one concurrent Renovate MR"
assert_json_eq "1" "cfg.branchConcurrentLimit" "$config_file" "one concurrent Renovate branch"
assert_json_eq "0" "cfg.prHourlyLimit" "$config_file" "unlimited hourly Renovate MRs"
assert_json_eq "true" "cfg.ignoreTests" "$config_file" "ignore tests env override"
assert_json_eq "CI Bot <ci@example.invalid>" "cfg.gitAuthor" "$config_file" "git author env override"
assert_json_eq "maven" "cfg.hostRules[0].hostType" "$config_file" "Maven host rule type"
assert_json_eq "gitlab-ci-token" "cfg.hostRules[0].username" "$config_file" "GitLab Maven Basic username"
assert_json_eq "job-token" "cfg.hostRules[0].password" "$config_file" "GitLab Maven Basic password"
assert_json_eq "/tmp/renovate-cache-job-id" "cfg.cacheDir" "$config_file" "ephemeral Renovate cache directory"

grep -F 'unset OTEL_EXPORTER_OTLP_ENDPOINT' "$template" >/dev/null || {
  fail "Renovate's truthy empty-endpoint check requires unsetting OTEL_EXPORTER_OTLP_ENDPOINT"
}
grep -F 'bash "$toolkit_dir/repo/ci/renovate_serial_loop.sh"' "$template" >/dev/null || {
  fail "Renovate must use the serial loop orchestrator"
}
grep -F 'MAGISK_RENOVATE_NO_MR_GRACE_POLLS' "$template" >/dev/null || {
  fail "Renovate must configure a bounded no-MR convergence grace period"
}
if grep -F 'MAGISK_RENOVATE_AUTOMERGE_DELAY_SECONDS' "$template" >/dev/null; then
  fail "the obsolete second-pass Renovate delay must be removed"
fi
if grep -F 'CI_PIPELINE_SOURCE == "push"' "$template" >/dev/null; then
  fail "Renovate must not start a new scan from a merge push"
fi

node -e '
const policy = require(process.argv[1]);
const rule = policy.packageRules.find((item) =>
  Array.isArray(item.registryUrls) &&
  item.registryUrls.includes("https://gitlab.com/api/v4/projects/85187820/packages/maven")
);
if (!rule) throw new Error("private Magisk Mobile Maven registry rule is missing");
' "$root_dir/default.json"

(
  cd "$tmp_dir"
  rm -rf .gitlab config.js
  MAGISK_RENOVATE_REPOSITORY="magisk3171/demo" \
  MAGISK_RENOVATE_IGNORE_TESTS="false" \
    node "$renovate_node_script" > config.js
)

config_file="$tmp_dir/config.js"
assert_json_eq '["renovate.json"]' "cfg.configFileNames" "$config_file" "root config fallback"
assert_json_eq "false" "cfg.platformAutomerge" "$config_file" "platform automerge default"
assert_json_eq "false" "cfg.automerge" "$config_file" "Renovate direct automerge remains disabled"
if node -e "const cfg=require(process.argv[1]); process.exit(Object.prototype.hasOwnProperty.call(cfg, 'ignoreTests') ? 0 : 1)" "$config_file"; then
  fail "ignoreTests should be omitted when MAGISK_RENOVATE_IGNORE_TESTS=false"
fi
if node -e "const cfg=require(process.argv[1]); process.exit(Object.prototype.hasOwnProperty.call(cfg, 'hostRules') ? 0 : 1)" "$config_file"; then
  fail "hostRules should be omitted when CI_JOB_TOKEN is unavailable"
fi

echo "GitLab Renovate dynamic config tests passed"
