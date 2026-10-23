#!/usr/bin/env bash
set -euo pipefail

# Fixture-driven test for release/reconcile_github_refs.sh. Everything runs
# against local bare repositories, so it needs no network, no credentials and
# no GitLab/GitHub account -- and it must stay that way, because this is the
# script an operator runs during an outage.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
script="$root_dir/release/reconcile_github_refs.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$script" ] || fail "$script is missing"
bash -n "$script" || fail "$script has a syntax error"

work_root="$(mktemp -d)"
trap 'rm -rf -- "$work_root"' EXIT

# A quoted array expansion cannot be the command word ("\"${arr[@]}\" git init"
# runs the program named "-c"), so the fixed git config options live in a
# function that takes the subcommand as its own arguments.
g() {
  git -c user.name=reconcile-test -c user.email=reconcile@example.invalid \
    -c init.defaultBranch=main "$@"
}

# Annotated tags need a tagger identity, and the utility image has no git
# config at all, so the fixture supplies it through the environment rather than
# relying on the machine it happens to run on.
export GIT_AUTHOR_NAME=reconcile-test GIT_AUTHOR_EMAIL=reconcile@example.invalid
export GIT_COMMITTER_NAME=reconcile-test GIT_COMMITTER_EMAIL=reconcile@example.invalid

fixture_count=0
new_fixture() {
  local f="$work_root/f$((++fixture_count))"
  mkdir -p "$f"
  g init --quiet --bare -b main "$f/gitlab.git"
  g init --quiet --bare -b main "$f/github.git"
  # Cloning a bare repo that has no commits yet prints "You appear to have
  # cloned an empty repository"; the seed commit below is what the fixture
  # actually cares about, so the noise is dropped for this one call and the
  # result is asserted instead.
  g clone --quiet "$f/gitlab.git" "$f/work" 2>/dev/null
  [ -d "$f/work/.git" ] || fail "fixture clone is missing"
  git -C "$f/work" remote add github "$f/github.git"
  g -C "$f/work" commit --quiet --allow-empty -m "seed commit"
  git -C "$f/work" push --quiet origin main
  git -C "$f/work" push --quiet github main
  FIXTURE="$f"
}

run_reconcile() {
  local out_file="$1"; shift
  set +e
  bash "$script" --repo-dir "$FIXTURE/work" --gitlab-remote origin --github-remote github "$@" \
    >"$out_file" 2>&1
  RECON_RC=$?
  set -e
}

require_status() {
  local file="$1" status="$2" context="$3"
  awk -F'\t' -v s="$status" '$1 == s { found = 1 } END { exit !found }' "$file" \
    || fail "$context: expected a $status finding, got: $(tr '\t' ' ' < "$file" | tr '\n' ' ')"
}

forbid_status() {
  local file="$1" status="$2" context="$3"
  if awk -F'\t' -v s="$status" '$1 == s { exit 0 } END { exit 1 }' "$file"; then
    fail "$context: unexpected $status finding"
  fi
}

# Every scenario ends with the same zero-side-effect checks: the tool must not
# leave refs behind in the caller's repository and must not make it shallow
# (a --depth fetch would).
assert_no_residue() {
  local context="$1"
  if [ -n "$(git -C "$FIXTURE/work" for-each-ref --format='%(refname)' refs/magisk-reconcile)" ]; then
    fail "$context: left temporary refs under refs/magisk-reconcile"
  fi
  if [ -f "$FIXTURE/work/.git/shallow" ]; then
    fail "$context: made the caller's repository shallow"
  fi
}

out="$work_root/out"

# 1. Both ends identical.
new_fixture
run_reconcile "$out"
[ "$RECON_RC" -eq 0 ] || fail "in-sync fixture exited $RECON_RC: $(cat "$out")"
assert_no_residue "in-sync fixture"

# 2. GitHub-only annotated tag whose commit GitLab has: reported, and --apply
#    writes exactly the tag object back.
new_fixture
git -C "$FIXTURE/work" tag -a -m "release" v9.9.9
git -C "$FIXTURE/work" push --quiet github refs/tags/v9.9.9
run_reconcile "$out" --porcelain
[ "$RECON_RC" -eq 1 ] || fail "pending tag should exit 1, got $RECON_RC: $(cat "$out")"
require_status "$out" PENDING_TAG "github-only tag"
forbid_status "$out" WROTE_BACK_TAG "read-only run must not push"
assert_no_residue "pending tag"
if git -C "$FIXTURE/gitlab.git" for-each-ref refs/tags/v9.9.9 | grep -q .; then
  fail "read-only run created a tag in GitLab"
fi
run_reconcile "$out" --porcelain --apply
require_status "$out" WROTE_BACK_TAG "apply writes the tag back"
git -C "$FIXTURE/gitlab.git" tag -l | grep -q '^v9\.9\.9$' \
  || fail "--apply did not create the tag in the GitLab remote"
# The tag object is what travels, not the commit it peels to.
gl_tag="$(git -C "$FIXTURE/gitlab.git" rev-parse refs/tags/v9.9.9)"
gh_tag="$(git -C "$FIXTURE/github.git" rev-parse refs/tags/v9.9.9)"
[ "$gl_tag" = "$gh_tag" ] || fail "backfilled tag object differs ($gl_tag vs $gh_tag)"
[ "$(git -C "$FIXTURE/gitlab.git" cat-file -t "$gl_tag")" = "tag" ] \
  || fail "backfilled ref is not an annotated tag object"
run_reconcile "$out"
[ "$RECON_RC" -eq 0 ] || fail "after write-back the fixture should be clean: $(cat "$out")"
assert_no_residue "written-back tag"

# 3. GitHub-only tag whose commit is not in GitLab: never auto-pushed.
new_fixture
g -C "$FIXTURE/work" commit --quiet --allow-empty -m "fix during the outage"
release_commit="$(git -C "$FIXTURE/work" rev-parse HEAD)"
git -C "$FIXTURE/work" tag -a -m "release from github" v9.9.8 "$release_commit"
git -C "$FIXTURE/work" push --quiet github refs/tags/v9.9.8
git -C "$FIXTURE/work" reset --quiet --hard "$release_commit~1"
git -C "$FIXTURE/work" push --quiet --force github main
run_reconcile "$out" --porcelain
require_status "$out" PENDING_TAG_WITH_COMMITS "tag whose commits are missing"
forbid_status "$out" WROTE_BACK_TAG "must not push a tag GitLab cannot build"
run_reconcile "$out" --porcelain --apply
forbid_status "$out" WROTE_BACK_TAG "even with --apply"
if git -C "$FIXTURE/gitlab.git" for-each-ref refs/tags/v9.9.8 | grep -q .; then
  fail "--apply pushed a tag whose commit is absent from GitLab"
fi
assert_no_residue "tag with missing commits"

# 4. A lightweight tag is never treated as release content.
new_fixture
git -C "$FIXTURE/work" tag v9.9.7
git -C "$FIXTURE/work" push --quiet github refs/tags/v9.9.7
run_reconcile "$out" --porcelain
require_status "$out" LIGHTWEIGHT_TAG "lightweight tag"
forbid_status "$out" PENDING_TAG "lightweight tag must not look writable"
run_reconcile "$out" --porcelain --apply
forbid_status "$out" WROTE_BACK_TAG "lightweight tag must not be written back"
assert_no_residue "lightweight tag"

# 5. An internal safety-net tag on GitHub is a leak, not a backfill.
new_fixture
git -C "$FIXTURE/work" tag -a -m "backup" "backup/pre-rewrite"
git -C "$FIXTURE/work" push --quiet github "refs/tags/backup/pre-rewrite"
run_reconcile "$out" --porcelain
require_status "$out" LEAKED_TAG "withheld prefix published to GitHub"
forbid_status "$out" PENDING_TAG "leaked prefix must not be offered for write-back"
assert_no_residue "leaked prefix"

# 6. A branch that exists only on GitHub.
new_fixture
git -C "$FIXTURE/work" checkout --quiet -b emergency-fix
g -C "$FIXTURE/work" commit --quiet --allow-empty -m "hotfix"
git -C "$FIXTURE/work" push --quiet github emergency-fix
git -C "$FIXTURE/work" checkout --quiet main
run_reconcile "$out" --porcelain
require_status "$out" GITHUB_ONLY_BRANCH "github-only branch"
assert_no_residue "github-only branch"

# 7. Commits on a shared branch that only GitHub has.
new_fixture
g -C "$FIXTURE/work" commit --quiet --allow-empty -m "written during the outage"
git -C "$FIXTURE/work" push --quiet github main
run_reconcile "$out" --porcelain
require_status "$out" GITHUB_ONLY_COMMITS "commits only on the mirror"
assert_no_residue "github-only commits"

# 8. GitHub simply behind GitLab is harmless: the next sync force-push fixes it.
new_fixture
g -C "$FIXTURE/work" commit --quiet --allow-empty -m "only on gitlab"
git -C "$FIXTURE/work" push --quiet origin main
run_reconcile "$out"
[ "$RECON_RC" -eq 0 ] || fail "mirror lag must not be a finding: $(cat "$out")"
# The prose mode has to say why nothing is wrong, or an operator reading the
# output cannot tell "in sync" from "GitHub is behind".
grep -q 'lag:' "$out" || fail "mirror lag was not explained in the report: $(cat "$out")"
assert_no_residue "mirror lag"

# 9. No GitHub remote is a configuration error, not an empty answer.
new_fixture
git -C "$FIXTURE/work" remote remove github
if bash "$script" --repo-dir "$FIXTURE/work" --gitlab-remote origin >"$out" 2>&1; then
  fail "a repository without a GitHub remote must not report success"
fi
grep -qi 'github-fallback-release.md\|no GitHub remote' "$out" \
  || fail "missing-remote case gave no actionable message: $(cat "$out")"

echo "PASS: reconcile_github_refs reports the mirror's write-back list and touches nothing else."
