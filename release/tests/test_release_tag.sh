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

reset_calls() {
  : > "$calls_file"
  : > "$glab_calls_file"
}

# ---------------------------------------------------------------------------
# 1. Fast-forwardable branch: the branch push must still carry a lease, but the
#    protected-branch API must not be touched at all — the "allow force push"
#    window stays closed for the common case.
# ---------------------------------------------------------------------------
release_force_push_required=false
release_remote_branch_commit="aaaa1111"
reset_calls

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
[[ "${calls[1]}" == *"--force-with-lease=refs/heads/beta:aaaa1111"* ]] || {
  echo "FAIL: branch push must carry the observed remote commit as the lease" >&2
  exit 1
}
[[ "${calls[1]}" == *"-o ci.skip origin beta"* ]] || {
  echo "FAIL: branch push must use the GitLab ci.skip push option" >&2
  exit 1
}
[[ "${calls[2]}" == *"push --force origin v3.3.1"* && "${calls[2]}" != *"ci.skip"* ]] || {
  echo "FAIL: tag push must force-push and create the release pipeline" >&2
  exit 1
}
[[ "${#glab_calls[@]}" -eq 0 ]] || {
  echo "FAIL: a fast-forwardable push must not change force-push protection" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 2. Diverged branch: force push protection is lifted for the push and restored
#    right after, and never left enabled.
# ---------------------------------------------------------------------------
release_force_push_required=true
release_remote_branch_commit="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
reset_calls

create_signed_tag "$workspace" v3.3.1 origin beta

mapfile -t calls < "$calls_file"
mapfile -t glab_calls < "$glab_calls_file"
[[ "${calls[1]}" == *"--force-with-lease=refs/heads/beta:deadbeef"* ]] || {
  echo "FAIL: diverged branch push must lease against the remote commit" >&2
  exit 1
}
[[ "${#glab_calls[@]}" -eq 2 ]] || {
  echo "FAIL: expected force-push protection to be changed twice, got ${#glab_calls[@]}" >&2
  exit 1
}
[[ "${glab_calls[0]}" == *"protected_branches/"* && "${glab_calls[0]}" == *"allow_force_push=true"* ]] || {
  echo "FAIL: protected branch must allow force push before the branch push" >&2
  exit 1
}
[[ "${glab_calls[1]}" == *"protected_branches/"* && "${glab_calls[1]}" == *"allow_force_push=false"* ]] || {
  echo "FAIL: protected branch must disable force push after the branch push" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 3. A failed branch push must skip the tag push and still restore protection.
# ---------------------------------------------------------------------------
release_force_push_required=true
release_remote_branch_commit="deadbeef"
reset_calls

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

mapfile -t calls < "$calls_file"
mapfile -t glab_calls < "$glab_calls_file"
[[ "${#calls[@]}" -eq 2 ]] || {
  echo "FAIL: tag push must not run after a failed branch push" >&2
  exit 1
}
[[ "${#glab_calls[@]}" -eq 2 && "${glab_calls[1]}" == *"allow_force_push=false"* ]] || {
  echo "FAIL: failed branch push must restore force-push protection" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 4. Branch-state classification: only a diverged remote branch needs force.
# ---------------------------------------------------------------------------
stub_head_commit="aaa"
stub_remote_commit="aaa"
stub_ancestor_rc=0

git() {
  case "$*" in
    *"rev-parse HEAD"*) printf '%s\n' "$stub_head_commit" ;;
    *"ls-remote"*)
      # Real `git ls-remote` prints nothing when the ref is absent; the stub
      # must mimic that instead of emitting an empty hash column.
      if [[ "$*" == *"refs/heads/"* && -n "$stub_remote_commit" ]]; then
        printf '%s\trefs/heads/beta\n' "$stub_remote_commit"
      fi
      ;;
    *"merge-base --is-ancestor"*) return "$stub_ancestor_rc" ;;
    *) return 0 ;;
  esac
}

# remote already at HEAD
check_branch_state_before_checks "$workspace" origin beta
[[ "$release_force_push_required" == "false" ]] || { echo "FAIL: identical branch must not require force push" >&2; exit 1; }
[[ "$release_head_commit" == "aaa" ]] || { echo "FAIL: head commit must be recorded" >&2; exit 1; }

# remote is an ancestor of HEAD -> fast-forwardable
stub_remote_commit="bbb"
stub_ancestor_rc=0
check_branch_state_before_checks "$workspace" origin beta
[[ "$release_force_push_required" == "false" ]] || { echo "FAIL: fast-forwardable branch must not require force push" >&2; exit 1; }
[[ "$release_remote_branch_commit" == "bbb" ]] || { echo "FAIL: remote branch commit must be recorded" >&2; exit 1; }

# diverged
stub_remote_commit="ccc"
stub_ancestor_rc=1
check_branch_state_before_checks "$workspace" origin beta
[[ "$release_force_push_required" == "true" ]] || { echo "FAIL: diverged branch must require force push" >&2; exit 1; }

# branch missing on the remote
stub_remote_commit=""
stub_ancestor_rc=1
check_branch_state_before_checks "$workspace" origin beta
[[ "$release_force_push_required" == "false" ]] || { echo "FAIL: missing remote branch must not require force push" >&2; exit 1; }
[[ -z "$release_remote_branch_commit" ]] || { echo "FAIL: missing remote branch must record an empty lease" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 5. release_tag must refuse to tag when HEAD moves while the checks run.
# ---------------------------------------------------------------------------
mkdir -p "$workspace/gradle" "$workspace/docs"
printf 'versionName = "3.3.1"\nversionCode = 331\n' > "$workspace/gradle/libs.versions.toml"
cat > "$workspace/docs/CHANGELOG.md" <<'MD'
## [v3.3.1]

- 版本：`versionCode 331` · `versionName 3.3.1`

---

## [v3.3.0]

- 版本：`versionCode 330` · `versionName 3.3.0`

---
MD

# The stub is reached through $(git ...), so it runs in a subshell and a plain
# counter variable would be lost between calls. Keep the count in a file.
head_counter_file="$tmp_dir/head-count"
printf '0\n' > "$head_counter_file"
git() {
  printf '%q ' "$@" >> "$calls_file"
  printf '\n' >> "$calls_file"
  case "$*" in
    *"rev-parse HEAD"*)
      local head_call_count
      head_call_count=$(( $(cat "$head_counter_file") + 1 ))
      printf '%s\n' "$head_call_count" > "$head_counter_file"
      if (( head_call_count == 1 )); then
        printf 'aaa\n'
      else
        printf 'bbb\n'
      fi
      ;;
    *"branch --show-current"*) printf 'beta\n' ;;
    *"ls-remote"*"refs/heads/"*) printf 'aaa\trefs/heads/beta\n' ;;
    *"merge-base --is-ancestor"*) return 0 ;;
    *"diff"*|*"status --porcelain"*) return 0 ;;
    *"rev-parse -q --verify refs/tags"*) return 1 ;;
    *) return 0 ;;
  esac
}

run_pre_push_checks() { :; }
export RELEASE_SKIP_GUARD=true
reset_calls

if head_changed_output="$(release_tag "$workspace" 2>&1)"; then
  echo "FAIL: release_tag must fail when HEAD changes during the checks" >&2
  exit 1
fi
[[ "$head_changed_output" == *"HEAD changed during release checks"* ]] || {
  echo "FAIL: unexpected release_tag output: $head_changed_output" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 6. Protected remote tags: the tag must be deleted by temporarily lifting the
#    matching protected-tag rule and restoring it afterwards, because GitLab
#    only allows protected tags to be removed through the API.
# ---------------------------------------------------------------------------
reset_calls

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
  if [[ "$*" == *"projects/:fullpath/protected_tags"* && "$*" != *"protected_tags/"* && "$*" != *"DELETE"* && "$*" != *"POST"* ]]; then
    printf '[{"name":"v*","create_access_levels":[{"access_level":40}]}]'
    return 0
  fi
  return 0
}

delete_remote_tag_if_exists "$workspace" v3.3.1 origin

mapfile -t calls < "$calls_file"
mapfile -t glab_calls < "$glab_calls_file"

[[ "${#calls[@]}" -eq 2 ]] || {
  echo "FAIL: expected ls-remote plus delete push, got ${#calls[@]}" >&2
  exit 1
}
[[ "${calls[1]}" == *"push origin :refs/tags/v3.3.1"* ]] || {
  echo "FAIL: remote tag must be deleted" >&2
  exit 1
}
[[ "${#glab_calls[@]}" -eq 3 ]] || {
  echo "FAIL: expected list/lift/restore protected-tag calls, got ${#glab_calls[@]}" >&2
  exit 1
}
[[ "${glab_calls[0]}" == *"protected_tags"* && "${glab_calls[0]}" != *"DELETE"* ]] || {
  echo "FAIL: protected-tag rules must be queried first" >&2
  exit 1
}
[[ "${glab_calls[1]}" == *"--method DELETE"* && "${glab_calls[1]}" == *"protected_tags/v"* ]] || {
  echo "FAIL: the matching protected-tag rule must be lifted" >&2
  exit 1
}
[[ "${glab_calls[2]}" == *"--method POST"* && "${glab_calls[2]}" == *"protected_tags"* ]] || {
  echo "FAIL: the protected-tag rule must be restored afterwards" >&2
  exit 1
}

# An unprotected tag must not touch the protected-tag API at all.
reset_calls

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

mapfile -t glab_calls < "$glab_calls_file"
[[ "${#glab_calls[@]}" -eq 1 && "${glab_calls[0]}" == *"protected_tags"* ]] || {
  echo "FAIL: an unprotected tag must not lift or restore any rule" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 7. The branch push must always carry -o ci.skip while the tag push must not,
#    so the tag pipeline — and only the tag pipeline — owns the release.
# ---------------------------------------------------------------------------
release_force_push_required=false
release_remote_branch_commit=""
reset_calls

create_signed_tag "$workspace" v3.3.1 origin beta

mapfile -t calls < "$calls_file"
[[ "${calls[1]}" == *"-o ci.skip origin beta"* ]] || {
  echo "FAIL: branch push must carry ci.skip" >&2
  exit 1
}
[[ "${calls[2]}" == *"push --force origin v3.3.1"* && "${calls[2]}" != *"ci.skip"* ]] || {
  echo "FAIL: tag push must not carry ci.skip" >&2
  exit 1
}

echo "Release tag push contract tests passed"
