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
[[ "${calls[2]}" == *"push origin v3.3.1"* && "${calls[2]}" != *"ci.skip"* ]] || {
  echo "FAIL: tag push must create the release pipeline" >&2
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

echo "Release tag push contract tests passed"
