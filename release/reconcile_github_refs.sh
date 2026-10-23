#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Reconcile the GitHub mirror with GitLab after a fallback release.
#
# GitHub is a forced redundancy mirror: .gitlab/ci/github-sync.yml force-pushes
# the default branch and release tags from GitLab to GitHub, and that job is
# never gated by RELEASE_OWNER. A fallback release runs the other direction --
# while the Runner fleet is down, a signed tag (and, after a hotfix, commits)
# can exist only on GitHub, and nothing carries it back. This script is the
# recovery step of docs/github-fallback-release.md: it states exactly what the
# mirror holds that GitLab does not, and what must be written back before the
# next sync:github force-push makes that content unreachable from a branch.
#
# Read-only unless --apply is given, and even then it performs only the one
# mechanically safe action: pushing an annotated tag object whose commit GitLab
# already has. Commits, lightweight tags and leaked internal prefixes are
# reported and never moved, because each of those needs a human decision --
# including the one this script cannot see: pushing a release tag to GitLab
# starts that project's tag pipeline, whose publish jobs run when
# RELEASE_OWNER == "gitlab", so move the switch before you backfill a version
# GitHub already published.
#
# Usage:
#   release/reconcile_github_refs.sh [--repo-dir DIR]
#       [--gitlab-remote NAME] [--github-remote NAME] [--apply] [--porcelain]
#
# Exit codes: 0 nothing to write back; 1 the mirror holds content GitLab lacks
# (or a leak); 2 usage or configuration error.
#
# Output: porcelain mode prints "STATUS<TAB>REF<TAB>DETAIL" lines, one per
# finding; the default mode prints the same findings in prose. STATUS values:
#   PENDING_TAG               annotated tag, commit on GitLab, --apply can fix it
#   WROTE_BACK_TAG            pushed to GitLab by this run (--apply)
#   WRITE_BACK_FAILED         the push was attempted and failed
#   PENDING_TAG_WITH_COMMITS  tag whose commit is missing from GitLab
#   LIGHTWEIGHT_TAG           not an annotated tag object: hand review
#   UNREADABLE_TAG            the ref could not be fetched or parsed
#   LEAKED_TAG                internal safety-net prefix present on GitHub
#   GITHUB_ONLY_BRANCH        branch with no GitLab counterpart
#   GITHUB_ONLY_COMMITS       commits on a shared branch that GitLab lacks
# ============================================================================

fail() { echo "ERROR: $*" >&2; exit 2; }

usage() {
  cat >&2 <<'EOF'
Usage: release/reconcile_github_refs.sh [--repo-dir DIR]
          [--gitlab-remote NAME] [--github-remote NAME] [--apply] [--porcelain]

Compares the GitHub mirror against GitLab and lists what must be written back
to GitLab after a fallback release. Read-only unless --apply is passed.
EOF
}

repo_dir="."
gitlab_remote=""
github_remote=""
apply=false
porcelain=false

while (($#)); do
  case "$1" in
    --repo-dir) repo_dir="${2:-}"; shift 2 ;;
    --gitlab-remote) gitlab_remote="${2:-}"; shift 2 ;;
    --github-remote) github_remote="${2:-}"; shift 2 ;;
    --apply) apply=true; shift ;;
    --porcelain) porcelain=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; fail "unknown argument: $1" ;;
  esac
done

git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1 \
  || fail "--repo-dir is not a git repository: $repo_dir"

# Remote defaults: explicit flags, then the project-level overrides, then
# origin for GitLab and "github" for the mirror. A repository with no GitHub
# remote must say so out loud -- an empty diff there would read as "in sync".
[[ -n "$gitlab_remote" ]] || gitlab_remote="${MAGISK_RECONCILE_GITLAB_REMOTE:-origin}"
[[ -n "$github_remote" ]] || github_remote="${MAGISK_RECONCILE_GITHUB_REMOTE:-}"
if [[ -z "$github_remote" ]]; then
  if git -C "$repo_dir" remote get-url github >/dev/null 2>&1; then
    github_remote=github
  else
    fail "no GitHub remote in $repo_dir: pass --github-remote or add one (docs/github-fallback-release.md)"
  fi
fi
for remote in "$gitlab_remote" "$github_remote"; do
  git -C "$repo_dir" remote get-url "$remote" >/dev/null 2>&1 \
    || fail "remote '$remote' is not configured in $repo_dir"
done

# The same prefixes github-sync.yml withholds, read from the same variable so
# the two cannot drift apart. An internal safety-net tag that reached GitHub is
# a leak to delete on GitHub, never content to import.
excluded_tag_prefixes="${MAGISK_GITHUB_MIRROR_EXCLUDED_TAG_PREFIXES:-backup/ archive/ tmp/ wip/ keep/}"

findings=0
note() { $porcelain || printf '%s\n' "$*"; }
record() {
  if $porcelain; then
    printf '%s\t%s\t%s\n' "$1" "$2" "$3"
  else
    printf '  %-24s %s\n    %s\n' "$1" "$2" "$3"
  fi
  findings=$((findings + 1))
}

tmp_dir="$(mktemp -d)"
reconcile_ns="refs/magisk-reconcile"
# Invoked through the EXIT trap, not called directly.
# shellcheck disable=SC2329
cleanup() {
  local ref
  while read -r ref; do
    [[ -n "$ref" ]] || continue
    git -C "$repo_dir" update-ref -d "$ref" 2>/dev/null || true
  done < <(git -C "$repo_dir" for-each-ref --format='%(refname)' "$reconcile_ns" 2>/dev/null || true)
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

# Objects for both ends' branches are needed to answer "is this commit already
# in GitLab". They are fetched under a private namespace and deleted on exit,
# so the caller's own refs and config are never touched, and no --depth flag is
# used anywhere: a shallow fetch would leave the caller's repository shallow,
# which is a side effect no read-only tool is allowed to cause.
git -C "$repo_dir" fetch --quiet --no-tags "$gitlab_remote" "+refs/heads/*:${reconcile_ns}/gitlab/*" \
  || fail "cannot fetch heads from remote '$gitlab_remote'"
git -C "$repo_dir" fetch --quiet --no-tags "$github_remote" "+refs/heads/*:${reconcile_ns}/github/*" \
  || fail "cannot fetch heads from remote '$github_remote'"

# ls-remote --tags --refs gives one line per tag ref, with the tag object's own
# SHA for annotated tags (the peeled lines are what --refs omits), which is
# exactly the comparison: two mirrors of the same release agree on the tag
# object, not merely on the commit it points at.
list_tags() {
  git -C "$repo_dir" ls-remote --tags --refs "$1" 2>/dev/null \
    | awk -F'\t' 'NF == 2 && $2 ~ /^refs\/tags\// { sub("^refs/tags/", "", $2); print $1 "\t" $2 }' \
    | sort -k2,2
}
list_heads() {
  git -C "$repo_dir" ls-remote --heads "$1" 2>/dev/null \
    | awk -F'\t' 'NF == 2 { sub("^refs/heads/", "", $2); print $1 "\t" $2 }' \
    | sort -k2,2
}

is_excluded_tag() {
  local name="$1" prefix
  for prefix in $excluded_tag_prefixes; do
    [[ "$name" == "$prefix"* ]] && return 0
  done
  return 1
}

gitlab_tags="$tmp_dir/gitlab-tags"
github_tags="$tmp_dir/github-tags"
gitlab_heads="$tmp_dir/gitlab-heads"
github_heads="$tmp_dir/github-heads"
list_tags "$gitlab_remote" > "$gitlab_tags"
list_tags "$github_remote" > "$github_tags"
list_heads "$gitlab_remote" > "$gitlab_heads"
list_heads "$github_remote" > "$github_heads"

gitlab_head_shas=()
while read -r sha _name; do
  [[ -n "${sha:-}" ]] && gitlab_head_shas+=("$sha")
done < "$gitlab_heads"

reachable_from_gitlab() {
  local commit="$1" head
  (( ${#gitlab_head_shas[@]} )) || return 1
  for head in "${gitlab_head_shas[@]}"; do
    git -C "$repo_dir" merge-base --is-ancestor "$commit" "$head" 2>/dev/null && return 0
  done
  return 1
}

note "Reconciling GitHub remote '$github_remote' against GitLab remote '$gitlab_remote' in $repo_dir"

# --- tags the mirror has and GitLab does not ---------------------------------
while read -r tag_sha name; do
  [[ -n "${name:-}" ]] || continue
  awk -v n="$name" '$2 == n { found = 1 } END { exit !found }' "$gitlab_tags" && continue

  if is_excluded_tag "$name"; then
    record LEAKED_TAG "$name" \
      "internal safety-net ref published to GitHub by accident; delete it there (the sync anchor never mirrors it)"
    continue
  fi

  if ! git -C "$repo_dir" fetch --quiet --no-tags "$github_remote" "refs/tags/$name" 2>/dev/null; then
    record UNREADABLE_TAG "$name" "cannot fetch refs/tags/$name from '$github_remote'"
    continue
  fi
  object_type="$(git -C "$repo_dir" cat-file -t FETCH_HEAD 2>/dev/null || echo missing)"
  if [[ "$object_type" != "tag" ]]; then
    record LIGHTWEIGHT_TAG "$name" \
      "ref points straight at a commit; the release chain only produces signed annotated tags, so this needs a human"
    continue
  fi
  commit="$(git -C "$repo_dir" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null || true)"
  [[ -n "$commit" ]] || { record UNREADABLE_TAG "$name" "tag object resolves to no commit"; continue; }

  if ! reachable_from_gitlab "$commit"; then
    record PENDING_TAG_WITH_COMMITS "$name" \
      "commit $commit is not reachable from any $gitlab_remote head; land the commits first, then the tag"
    continue
  fi

  if ! $apply; then
    record PENDING_TAG "$name" \
      "annotated tag whose commit $gitlab_remote already has; re-run with --apply to write it back (move GitLab's RELEASE_OWNER off gitlab first if GitHub already published this version)"
    continue
  fi
  if git -C "$repo_dir" push "$gitlab_remote" "$tag_sha:refs/tags/$name" >/dev/null 2>&1; then
    record WROTE_BACK_TAG "$name" "pushed tag object to $gitlab_remote"
  else
    record WRITE_BACK_FAILED "$name" "git push $gitlab_remote $tag_sha:refs/tags/$name failed (branch protection, or the tag already exists there)"
  fi
done < "$github_tags"

# --- branch content ----------------------------------------------------------
while read -r sha name; do
  [[ -n "${name:-}" ]] || continue
  gitlab_sha="$(awk -v n="$name" '$2 == n { print $1; exit }' "$gitlab_heads")"
  if [[ -z "$gitlab_sha" ]]; then
    record GITHUB_ONLY_BRANCH "$name" "no $gitlab_remote counterpart; decide whether this branch belongs in GitLab"
    continue
  fi
  [[ "$sha" == "$gitlab_sha" ]] && continue
  if git -C "$repo_dir" merge-base --is-ancestor "$sha" "$gitlab_sha" 2>/dev/null; then
    note "  lag: $name is behind $gitlab_remote; the next sync:github force-push resolves it"
    continue
  fi
  ahead="$(git -C "$repo_dir" rev-list --count "$gitlab_sha..$sha" 2>/dev/null || echo '?')"
  record GITHUB_ONLY_COMMITS "$name" \
    "$ahead commit(s) live only on GitHub; land them in $gitlab_remote by hand (merge request or fast-forward), then re-run"
done < "$github_heads"

if ((findings == 0)); then
  note "OK: '$github_remote' holds nothing that '$gitlab_remote' lacks."
  exit 0
fi

note ""
note "$findings finding(s) above."
exit 1
