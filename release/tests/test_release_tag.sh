#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"

source "$root_dir/release/release_tag.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
calls_file="$tmp_dir/git-calls.txt"
glab_calls_file="$tmp_dir/glab-calls.txt"
workspace="$tmp_dir/workspace"
mkdir -p "$workspace"

git() {
  printf '%q ' "$@" >> "$calls_file"
  printf '\n' >> "$calls_file"
}

glab() {
  printf '%q ' "$@" >> "$glab_calls_file"
  printf '\n' >> "$glab_calls_file"
}

create_signed_tag "$workspace" v3.3.1 origin beta

mapfile -t calls < "$calls_file"
mapfile -t glab_calls < "$glab_calls_file"
[[ "${#calls[@]}" -eq 3 ]] || {
  echo "FAIL: expected three git calls, got ${#calls[@]}" >&2
  exit 1
}
[[ "${calls[0]}" == *"tag -s v3.3.1 -m v3.3.1"* ]] || {
  echo "FAIL: signed tag call is missing" >&2
  exit 1
}
[[ "${calls[1]}" == *"push --force-with-lease -o ci.skip origin beta"* ]] || {
  echo "FAIL: branch push must use the GitLab ci.skip push option" >&2
  exit 1
}
[[ "${calls[2]}" == *"push --force origin v3.3.1"* && "${calls[2]}" != *"ci.skip"* ]] || {
  echo "FAIL: tag push must force-push and create the release pipeline" >&2
  exit 1
}
[[ "${#glab_calls[@]}" -eq 2 ]] || {
  echo "FAIL: expected force-push protection to be changed twice, got ${#glab_calls[@]}" >&2
  exit 1
}
[[ "${glab_calls[0]}" == *"protected_branches/:branch"* && "${glab_calls[0]}" == *"allow_force_push=true"* ]] || {
  echo "FAIL: protected branch must allow force push before the branch push" >&2
  exit 1
}
[[ "${glab_calls[1]}" == *"protected_branches/:branch"* && "${glab_calls[1]}" == *"allow_force_push=false"* ]] || {
  echo "FAIL: protected branch must disable force push after the branch push" >&2
  exit 1
}

: > "$calls_file"
: > "$glab_calls_file"
git() {
  printf '%q ' "$@" >> "$calls_file"
  printf '\n' >> "$calls_file"
  if [[ "$*" == *"push --force-with-lease"* ]]; then
    return 1
  fi
}

if create_signed_tag "$workspace" v3.3.1 origin beta; then
  echo "FAIL: create_signed_tag must fail when the branch push fails" >&2
  exit 1
fi

mapfile -t failed_calls < "$calls_file"
mapfile -t failed_glab_calls < "$glab_calls_file"
[[ "${#failed_calls[@]}" -eq 2 ]] || {
  echo "FAIL: tag push must not run after a failed branch push" >&2
  exit 1
}
[[ "${#failed_glab_calls[@]}" -eq 2 && "${failed_glab_calls[1]}" == *"allow_force_push=false"* ]] || {
  echo "FAIL: failed branch push must restore force-push protection" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Protected remote tags: the tag must be deleted by temporarily lifting the
# matching protected-tag rule and restoring it afterwards, because GitLab only
# allows protected tags to be removed through the API.
# ---------------------------------------------------------------------------
: > "$calls_file"
: > "$glab_calls_file"

git() {
  printf '%q ' "$@" >> "$calls_file"
  printf '\n' >> "$calls_file"
  if [[ "$*" == *"ls-remote --tags"* ]]; then
    printf 'cac564acd421f7bbf41b84475a2f080b42e4c21f\trefs/tags/v3.3.1\n'
    return 0
  fi
  if [[ "$*" == *"push origin :refs/tags/v3.3.1"* ]]; then
    return 0
  fi
}

glab() {
  printf '%q ' "$@" >> "$glab_calls_file"
  printf '\n' >> "$glab_calls_file"
  if [[ "$*" == *"projects/:fullpath/protected_tags"* && "$*" != *"protected_tags/"*"/"* && "$*" != *"DELETE"* && "$*" != *"POST"* ]]; then
    printf '[{"name":"v*","create_access_levels":[{"access_level":40}]}]'
    return 0
  fi
  return 0
}

delete_remote_tag_if_exists "$workspace" v3.3.1 origin

mapfile -t pt_calls < "$calls_file"
mapfile -t pt_glab_calls < "$glab_calls_file"

[[ "${#pt_calls[@]}" -eq 2 ]] || {
  echo "FAIL: expected ls-remote plus delete push, got ${#pt_calls[@]}" >&2
  exit 1
}
[[ "${pt_calls[1]}" == *"push origin :refs/tags/v3.3.1"* ]] || {
  echo "FAIL: remote tag must be deleted" >&2
  exit 1
}
[[ "${#pt_glab_calls[@]}" -eq 3 ]] || {
  echo "FAIL: expected list/lift/restore protected-tag calls, got ${#pt_glab_calls[@]}" >&2
  exit 1
}
[[ "${pt_glab_calls[0]}" == *"protected_tags"* && "${pt_glab_calls[0]}" != *"DELETE"* ]] || {
  echo "FAIL: protected-tag rules must be queried first" >&2
  exit 1
}
[[ "${pt_glab_calls[1]}" == *"--method DELETE"* && "${pt_glab_calls[1]}" == *"protected_tags/v"* ]] || {
  echo "FAIL: the matching protected-tag rule must be lifted" >&2
  exit 1
}
[[ "${pt_glab_calls[2]}" == *"--method POST"* && "${pt_glab_calls[2]}" == *"protected_tags"* ]] || {
  echo "FAIL: the protected-tag rule must be restored afterwards" >&2
  exit 1
}

# An unprotected tag must not touch the protected-tag API at all.
: > "$calls_file"
: > "$glab_calls_file"
glab() {
  printf '%q ' "$@" >> "$glab_calls_file"
  printf '\n' >> "$glab_calls_file"
  if [[ "$*" == *"projects/:fullpath/protected_tags"* ]]; then
    printf '[]'
    return 0
  fi
  return 0
}

delete_remote_tag_if_exists "$workspace" v3.3.1 origin

mapfile -t up_glab_calls < "$glab_calls_file"
[[ "${#up_glab_calls[@]}" -eq 1 && "${up_glab_calls[0]}" == *"protected_tags"* ]] || {
  echo "FAIL: an unprotected tag must not lift or restore any rule" >&2
  exit 1
}

echo "Release tag push contract tests passed"
