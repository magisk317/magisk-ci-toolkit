#!/usr/bin/env bash
# The template assertions below grep for literal shell and GitLab expressions, so
# their patterns stay single-quoted on purpose.
# shellcheck disable=SC2016
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
resolver="$root_dir/ci/resolve_git_checkout.sh"
android_template="$root_dir/.gitlab/ci/android.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_detached_at() {
  local checkout_dir="$1" expected_commit="$2" message="$3"
  assert_eq "$expected_commit" "$(git -C "$checkout_dir" rev-parse HEAD)" "$message"
  if git -C "$checkout_dir" symbolic-ref -q HEAD >/dev/null; then
    fail "$message left HEAD attached"
  fi
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

source_repo="$tmp_dir/source"
remote_repo="$tmp_dir/remote.git"
checkout_dir="$tmp_dir/checkout"

git init --quiet --initial-branch=main "$source_repo"
git -C "$source_repo" config user.name "CI Toolkit Test"
git -C "$source_repo" config user.email "ci-toolkit-test@example.invalid"
git -C "$source_repo" config commit.gpgSign false

printf 'one\n' > "$source_repo/payload.txt"
git -C "$source_repo" add payload.txt
git -C "$source_repo" commit --quiet -m one
commit_one="$(git -C "$source_repo" rev-parse HEAD)"
git -C "$source_repo" tag v1

printf 'two\n' > "$source_repo/payload.txt"
git -C "$source_repo" commit --quiet -am two
commit_two="$(git -C "$source_repo" rev-parse HEAD)"

printf 'three\n' > "$source_repo/payload.txt"
git -C "$source_repo" commit --quiet -am three
commit_three="$(git -C "$source_repo" rev-parse HEAD)"

git clone --quiet --bare "$source_repo" "$remote_repo"
remote_url="file://$remote_repo"

mkdir -p "$checkout_dir"
printf 'stale\n' > "$checkout_dir/stale.txt"
assert_eq "$checkout_dir" "$("$resolver" "$remote_url" main "$checkout_dir")" "branch checkout output"
assert_detached_at "$checkout_dir" "$commit_three" "branch checkout"
assert_eq "$remote_url" "$(git -C "$checkout_dir" remote get-url origin)" "origin URL"

assert_eq "$checkout_dir" "$("$resolver" "$remote_url" v1 "$checkout_dir")" "tag checkout output"
assert_detached_at "$checkout_dir" "$commit_one" "tag checkout"

assert_eq "$checkout_dir" "$("$resolver" "$remote_url" "$commit_two" "$checkout_dir")" "raw SHA checkout output"
assert_detached_at "$checkout_dir" "$commit_two" "raw SHA checkout"

missing_commit="ffffffffffffffffffffffffffffffffffffffff"
if "$resolver" "$remote_url" "$missing_commit" "$checkout_dir" >/dev/null 2>&1; then
  fail "missing raw SHA unexpectedly resolved"
fi
assert_detached_at "$checkout_dir" "$commit_two" "failed raw SHA checkout"

if grep -Fq 'MAGISK_CI_TOOLKIT_REF: "main"' "$android_template"; then
  fail "GitLab job-level variables still override consumer MAGISK_CI_TOOLKIT_REF"
fi
grep -Fq ': "${MAGISK_CI_TOOLKIT_REF:?MAGISK_CI_TOOLKIT_REF must be a full 40-character toolkit SHA}"' "$android_template" ||
  fail "GitLab template must require the consumer-pinned toolkit ref instead of defaulting it"
grep -Fq 'git init --quiet "$MAGISK_CI_TOOLKIT_DIR"' "$android_template" ||
  fail "GitLab template is missing exact-fetch repository initialization"
grep -Fq 'toolkit_repository_auth=' "$android_template" ||
  fail "GitLab template is missing job-token authentication setup"
grep -Fq 'git -C "$MAGISK_CI_TOOLKIT_DIR" fetch --depth 1 origin "$MAGISK_CI_TOOLKIT_REF"' "$android_template" ||
  fail "GitLab template is missing exact ref fetch"
grep -Fq 'git -C "$MAGISK_CI_TOOLKIT_DIR" checkout --detach --force FETCH_HEAD' "$android_template" ||
  fail "GitLab template is missing detached checkout"
if grep -Eq 'git clone .*--branch .*MAGISK_CI_TOOLKIT_REF' "$android_template"; then
  fail "GitLab template still treats the toolkit ref as a branch"
fi

template_checkout_dir="$tmp_dir/template-checkout"
template_checkout_script="$(sed -n \
  '/toolkit-checkout-contract:start/,/toolkit-checkout-contract:end/p' \
  "$android_template" | sed '1d;$d')"
if [[ -z "$template_checkout_script" ]]; then
  fail "GitLab toolkit checkout contract block was not found"
fi
MAGISK_CI_TOOLKIT_DIR="$template_checkout_dir" \
MAGISK_CI_TOOLKIT_REPOSITORY="$remote_url" \
MAGISK_CI_TOOLKIT_REF="$commit_two" \
  bash -c "$template_checkout_script"
assert_detached_at "$template_checkout_dir" "$commit_two" "GitLab raw SHA checkout"

echo "git checkout resolver tests passed"
