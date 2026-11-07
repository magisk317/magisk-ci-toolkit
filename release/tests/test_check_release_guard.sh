#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"

source "$root_dir/release/check_release_guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
state_dir="$tmp_dir/state"
mkdir -p "$state_dir"
badge_calls_file="$state_dir/badge-calls"
allow_non_ascii_file="$state_dir/allow-non-ascii"
printf '0\n' > "$badge_calls_file"

# The guard is driven through $(...) in the tests, so every observation a stub
# makes has to go to a file — a shell variable would be lost in the subshell.
check_readme_badges() {
  printf '%s\n' "$(( $(cat "$badge_calls_file") + 1 ))" > "$badge_calls_file"
  return 0
}

check_commit_subjects() {
  printf '%s\n' "$2" > "$allow_non_ascii_file"
  return 0
}

make_repo() {
  local dir="$1"
  local policy_json="$2"
  mkdir -p "$dir/gradle" "$dir/docs" "$dir/distribution/whatsnew" \
    "$dir/scripts/config" "$dir/scripts/release" "$dir/scripts/ci"
  # Mirrors the real catalogs, which quote both values.
  printf 'versionName = "3.3.1"\nversionCode = "331"\n' > "$dir/gradle/libs.versions.toml"
  cat > "$dir/docs/CHANGELOG.md" <<'MD'
## [v3.3.1]

- 版本：`versionCode 331` · `versionName 3.3.1`

---

## [v3.3.0]

- 版本：`versionCode 330` · `versionName 3.3.0`

---
MD
  printf 'bug fixes\n' > "$dir/distribution/whatsnew/whatsnew-en-US"
  printf '修复若干问题\n' > "$dir/distribution/whatsnew/whatsnew-zh-CN"
  printf '%s\n' "$policy_json" > "$dir/scripts/config/release-policy.json"
}

base_policy() {
  cat <<'JSON'
{
  "version_file": "gradle/libs.versions.toml",
  "changelog_file": "docs/CHANGELOG.md",
  "require_changelog": true,
  "require_versioncode_increment": true,
  "require_readme_badges": true,
  "require_tag_match": true,
  "allow_non_ascii_commit_subject": false,
  "whatsnew_locales": ["en-US", "zh-CN"],
  "project_checks": []
}
JSON
}

policy_with() {
  printf '%s' "$(base_policy)" | python3 -c "$1"
}

# ---------------------------------------------------------------------------
# 1. The guard runs the policy-declared whatsnew locales against the
#    policy-declared directory, not the old hard-coded metadata path.
# ---------------------------------------------------------------------------
repo="$tmp_dir/repo-ok"
make_repo "$repo" "$(base_policy)"
export MAGISK_RELEASE_POLICY_FILE="$repo/scripts/config/release-policy.json"

out="$(check_release_guard "$repo" v3.3.1)"
[[ "$out" == *"PASS: en-US length="* ]] || { echo "FAIL: en-US whatsnew not checked: $out" >&2; exit 1; }
[[ "$out" == *"PASS: zh-CN length="* ]] || { echo "FAIL: zh-CN whatsnew not checked: $out" >&2; exit 1; }
[[ "$out" == *"Release guard passed"* ]] || { echo "FAIL: guard should pass: $out" >&2; exit 1; }
[[ "$(cat "$badge_calls_file")" == "1" ]] || {
  echo "FAIL: README badge check must run once, ran $(cat "$badge_calls_file")" >&2; exit 1
}

# ---------------------------------------------------------------------------
# 2. A missing whatsnew file must fail the guard.
# ---------------------------------------------------------------------------
repo_missing="$tmp_dir/repo-missing"
make_repo "$repo_missing" "$(base_policy)"
rm -f "$repo_missing/distribution/whatsnew/whatsnew-zh-CN"
export MAGISK_RELEASE_POLICY_FILE="$repo_missing/scripts/config/release-policy.json"

set +e
out_missing="$(check_release_guard "$repo_missing" v3.3.1 2>&1)"
rc_missing=$?
set -e
(( rc_missing != 0 )) || { echo "FAIL: missing whatsnew must fail the guard" >&2; exit 1; }
[[ "$out_missing" == *"required whatsnew locale missing: zh-CN"* ]] || {
  echo "FAIL: unexpected output: $out_missing" >&2; exit 1
}

# ---------------------------------------------------------------------------
# 3. project_checks declared in the policy are dispatched: a function first...
# ---------------------------------------------------------------------------
repo_fn="$tmp_dir/repo-fn"
make_repo "$repo_fn" "$(policy_with '
import json,sys
d=json.load(sys.stdin); d["project_checks"]=["my_function_check"]; print(json.dumps(d))')"
export MAGISK_RELEASE_POLICY_FILE="$repo_fn/scripts/config/release-policy.json"

project_check_log="$state_dir/function-check.log"
: > "$project_check_log"
# Invoked indirectly by run_project_checks().
# shellcheck disable=SC2329
my_function_check() {
  printf 'function %s %s %s\n' "$1" "$2" "$3" >> "$project_check_log"
  return 0
}

out_fn="$(check_release_guard "$repo_fn" v3.3.1)"
[[ "$out_fn" == *"Running project check (function): my_function_check"* ]] || {
  echo "FAIL: function project check was not dispatched: $out_fn" >&2; exit 1
}
[[ "$(cat "$project_check_log")" == "function $repo_fn 3.3.1 v3.3.1" ]] || {
  echo "FAIL: project check arguments are wrong: $(cat "$project_check_log")" >&2; exit 1
}
unset -f my_function_check

# ---------------------------------------------------------------------------
# 4. ...then a script under scripts/ when no function is defined.
# ---------------------------------------------------------------------------
repo_sh="$tmp_dir/repo-sh"
make_repo "$repo_sh" "$(policy_with '
import json,sys
d=json.load(sys.stdin); d["project_checks"]=["my_script_check"]; print(json.dumps(d))')"
script_log="$state_dir/script-check.log"
: > "$script_log"
# The %%s escapes and single-quoted body are deliberate: they are the text of
# the generated script, not format expressions for this printf.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "script %%s %%s %%s\\n" "$1" "$2" "$3" >> "%s"\nexit 0\n' "$script_log" \
  > "$repo_sh/scripts/release/my_script_check.sh"
export MAGISK_RELEASE_POLICY_FILE="$repo_sh/scripts/config/release-policy.json"

out_sh="$(check_release_guard "$repo_sh" v3.3.1)"
[[ "$out_sh" == *"Running project check (script): my_script_check"* ]] || {
  echo "FAIL: script project check was not dispatched: $out_sh" >&2; exit 1
}
[[ "$(cat "$script_log")" == "script $repo_sh 3.3.1 v3.3.1" ]] || {
  echo "FAIL: script project check arguments are wrong: $(cat "$script_log")" >&2; exit 1
}

# ---------------------------------------------------------------------------
# 5. A policy check with no implementation fails closed instead of silently
#    passing.
# ---------------------------------------------------------------------------
repo_gone="$tmp_dir/repo-gone"
make_repo "$repo_gone" "$(policy_with '
import json,sys
d=json.load(sys.stdin); d["project_checks"]=["does_not_exist_check"]; print(json.dumps(d))')"
export MAGISK_RELEASE_POLICY_FILE="$repo_gone/scripts/config/release-policy.json"

set +e
out_gone="$(check_release_guard "$repo_gone" v3.3.1 2>&1)"
rc_gone=$?
set -e
(( rc_gone != 0 )) || { echo "FAIL: unimplemented project check must fail the guard" >&2; exit 1; }
[[ "$out_gone" == *"policy requires project check 'does_not_exist_check'"* ]] || {
  echo "FAIL: unexpected output: $out_gone" >&2; exit 1
}

# ---------------------------------------------------------------------------
# 6. A check name that is not a plain shell identifier is rejected while the
#    policy is parsed, before it can reach the shell.
# ---------------------------------------------------------------------------
repo_bad="$tmp_dir/repo-bad"
make_repo "$repo_bad" "$(policy_with '
import json,sys
d=json.load(sys.stdin); d["project_checks"]=["ok_check; rm -rf /"]; print(json.dumps(d))')"
export MAGISK_RELEASE_POLICY_FILE="$repo_bad/scripts/config/release-policy.json"

set +e
out_bad="$(validate_release_policy "$repo_bad" 2>&1)"
rc_bad=$?
set -e
(( rc_bad != 0 )) || { echo "FAIL: non-identifier check name must be rejected" >&2; exit 1; }
[[ "$out_bad" == *"not a shell identifier"* ]] || { echo "FAIL: unexpected output: $out_bad" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 7. allow_non_ascii_commit_subject from the policy reaches the commit-subject
#    check.
# ---------------------------------------------------------------------------
repo_ascii="$tmp_dir/repo-ascii"
make_repo "$repo_ascii" "$(policy_with '
import json,sys
d=json.load(sys.stdin); d["allow_non_ascii_commit_subject"]=True; print(json.dumps(d))')"
export MAGISK_RELEASE_POLICY_FILE="$repo_ascii/scripts/config/release-policy.json"

check_release_guard "$repo_ascii" v3.3.1 >/dev/null
[[ "$(cat "$allow_non_ascii_file")" == "true" ]] || {
  echo "FAIL: policy allow_non_ascii_commit_subject was not honoured (got '$(cat "$allow_non_ascii_file")')" >&2; exit 1
}

# An env var still decides the fallback for policies that omit the key.
repo_fallback="$tmp_dir/repo-fallback"
make_repo "$repo_fallback" "$(policy_with '
import json,sys
d=json.load(sys.stdin); d.pop("allow_non_ascii_commit_subject", None); print(json.dumps(d))')"
export MAGISK_RELEASE_POLICY_FILE="$repo_fallback/scripts/config/release-policy.json"

ALLOW_NON_ASCII_COMMIT_SUBJECT=true check_release_guard "$repo_fallback" v3.3.1 >/dev/null
[[ "$(cat "$allow_non_ascii_file")" == "true" ]] || {
  echo "FAIL: env fallback not honoured (got '$(cat "$allow_non_ascii_file")')" >&2; exit 1
}
check_release_guard "$repo_fallback" v3.3.1 >/dev/null
[[ "$(cat "$allow_non_ascii_file")" == "false" ]] || {
  echo "FAIL: default should be false (got '$(cat "$allow_non_ascii_file")')" >&2; exit 1
}

echo "Release guard policy dispatch tests passed"
# ---------------------------------------------------------------------------
# 8. The gradle wrapper sha check: a pinned distribution with a checksum
#    passes; the Renovate half-upgrade (URL moved, checksum behind) fails.
# ---------------------------------------------------------------------------
repo_wrap="$tmp_dir/repo-wrap"
make_repo "$repo_wrap" "$(base_policy)"
export MAGISK_RELEASE_POLICY_FILE="$repo_wrap/scripts/config/release-policy.json"
mkdir -p "$repo_wrap/gradle/wrapper"
printf "distributionUrl=https\\://services.gradle.org/distributions/gradle-9.9.0-bin.zip\ndistributionSha256Sum=0b00b0ffe07c4d4789c12d4935a44a7057d55774b7540bd4a3f76f336deb177a\n" \
  > "$repo_wrap/gradle/wrapper/gradle-wrapper.properties"
out_wrap="$(check_gradle_wrapper_sha "$repo_wrap" 2>&1)"
[[ "$out_wrap" == *"PASS: gradle wrapper 9.9.0 sha256 pinned"* ]] || {
  echo "FAIL: wrapper sha pass expected: $out_wrap" >&2; exit 1
}
printf "distributionUrl=https\\://services.gradle.org/distributions/gradle-9.9.0-bin.zip\n" \
  > "$repo_wrap/gradle/wrapper/gradle-wrapper.properties"
set +e
out_wrap="$(check_gradle_wrapper_sha "$repo_wrap" 2>&1)"
rc_wrap=$?
set -e
(( rc_wrap != 0 )) || { echo "FAIL: missing wrapper sha must fail" >&2; exit 1; }
[[ "$out_wrap" == *"no distributionSha256Sum"* ]] || {
  echo "FAIL: unexpected missing-sha output: $out_wrap" >&2; exit 1
}
printf "distributionUrl=https\\://services.gradle.org/distributions/gradle-9.9.0-bin.zip\ndistributionSha256Sum=not-a-sha\n" \
  > "$repo_wrap/gradle/wrapper/gradle-wrapper.properties"
set +e
out_wrap="$(check_gradle_wrapper_sha "$repo_wrap" 2>&1)"
rc_wrap=$?
set -e
(( rc_wrap != 0 )) || { echo "FAIL: malformed wrapper sha must fail" >&2; exit 1; }
[[ "$out_wrap" == *"not a sha256"* ]] || {
  echo "FAIL: unexpected malformed-sha output: $out_wrap" >&2; exit 1
}

# ---------------------------------------------------------------------------
# 9. Repositories without the surface under check must SKIP, not fail: the
#    guard is shared by repos in different shapes.
# ---------------------------------------------------------------------------
repo_plain="$tmp_dir/repo-plain"
make_repo "$repo_plain" "$(base_policy)"
out_plain="$(check_gradle_wrapper_sha "$repo_plain")"
[[ "$out_plain" == *"SKIP: no gradle wrapper properties"* ]] || {
  echo "FAIL: wrapper check should skip: $out_plain" >&2; exit 1
}
out_plain="$(check_gitlab_ci_lint "$repo_plain")"
[[ "$out_plain" == *"SKIP: no .gitlab-ci.yml"* ]] || {
  echo "FAIL: lint check should skip: $out_plain" >&2; exit 1
}
mkdir -p "$repo_plain/gradle/wrapper" "$repo_plain/.github"
printf "distributionUrl=https\\://services.gradle.org/distributions/gradle-9.9.0-bin.zip\ndistributionSha256Sum=0b00b0ffe07c4d4789c12d4935a44a7057d55774b7540bd4a3f76f336deb177a\n" \
  > "$repo_plain/gradle/wrapper/gradle-wrapper.properties"
printf "stages: [build]\n" > "$repo_plain/.gitlab-ci.yml"
unset GITLAB_TOKEN CI_JOB_TOKEN
out_plain="$(unset GITLAB_TOKEN CI_JOB_TOKEN; check_gitlab_ci_lint "$repo_plain")"
[[ "$out_plain" == *"SKIP: GitLab CI lint needs"* ]] || {
  echo "FAIL: lint without a token should skip: $out_plain" >&2; exit 1
}
out_plain="$(check_toolkit_pin "$repo_plain")"
[[ "$out_plain" == *"SKIP: no toolkit pin surfaces"* ]] || {
  echo "FAIL: toolkit pin should skip: $out_plain" >&2; exit 1
}
out_plain="$(check_submodule_pointers "$repo_plain")"
[[ "$out_plain" == *"SKIP: no submodules"* ]] || {
  echo "FAIL: pointer check should skip: $out_plain" >&2; exit 1
}

# ---------------------------------------------------------------------------
# 10. The kill switches honour the MAGISK_RELEASE_REQUIRE_* convention.
# ---------------------------------------------------------------------------
set +e
off_out="$(MAGISK_RELEASE_REQUIRE_WRAPPER_SHA=false check_release_guard "$repo_wrap" v3.3.1 2>&1)"
off_rc=$?
on_out="$(check_release_guard "$repo_wrap" v3.3.1 2>&1)"
on_rc=$?
set -e
(( off_rc == 0 )) || { echo "FAIL: kill switch must let the guard pass: $off_out" >&2; exit 1; }
(( on_rc != 0 )) || { echo "FAIL: guard must fail on a stale wrapper sha" >&2; exit 1; }
[[ "$on_out" == *"not a sha256"* ]] || {
  echo "FAIL: unexpected guard output: $on_out" >&2; exit 1; }

echo "Release guard new-check tests passed"

