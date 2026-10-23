# GitHub fallback release runbook

This is the operator's procedure for releasing one of the three Android
products when the GitLab Runner fleet is not available. It exists because
`sync:github` keeps a GitHub mirror of every repository at all times, and
`.github/workflows/release-android.yml` in the toolkit is a `workflow_call`
twin of the GitLab release template, so the same artifacts can be produced
somewhere else.

## What this fallback does and does not cover

It covers one failure: **the Runner fleet is down**. The GitLab host, the
submodules, this toolkit repository and the GitLab Maven registry are all
assumed reachable, because the chain fetches them over HTTPS and nothing about
a Runner outage takes them away. Host-level GitLab loss, a lost project, or a
lost repository is a different incident and this procedure will not help.

Deliberate differences from the GitLab chain:

- **No tag is created in GitHub Actions.** `release/release_tag.sh` signs
  locally, so the private key never becomes a workflow secret. The operator
  creates the signed tag on their own machine and pushes it to both hosts by
  hand; the chain refuses a source ref that is not a signed tag object before
  it pushes anything to Xposed-Modules-Repo.
- **No Telegram message.** The release card is human-reviewed before it is
  sent, which is why `notification.yml` stays `workflow_dispatch`-only in every
  consumer. Announce from GitLab after the Runners are back, or send it
  yourself.
- **Play goes through `release/publish_play.sh`** (stdlib python) instead of
  fastlane, so no ruby toolchain is installed on the runner.
- **`release/resolve_play_release.sh` runs exactly once**, in `release-meta`.
  Two sibling build jobs resolving independently could disagree on versionCode.

## One-time setup per repository

1. `.github/workflows/release.yml` is the thin caller (see
   `XposedSmsCode` as the reference implementation). It passes
   `enabled: ${{ vars.RELEASE_OWNER == 'github' }}`, an equality, not
   `!= 'gitlab'`: `sync:github` force-pushes release tags, so an unset variable
   would turn every mirrored tag push into a second publish.
2. Repository variable `RELEASE_OWNER` exists and is `gitlab`. Settings →
   Secrets and variables → Actions → Variables. It is the same switch GitLab
   uses, mirrored, and only one host may hold it at a time.
3. The `Release` workflow is `active` (a repository that never used Actions
   starts its workflows disabled):
   `gh api -X PUT "repos/<owner>/<repo>/actions/workflows/release.yml/enable"`.
4. Secrets the chain reads: `RELEASE_KEYSTORE`, `STORE_PASSWORD`, `KEY_ALIAS`,
   `KEY_PASSWORD`, `GITLAB_TOKEN` (private submodules), `ANDROID_PUBLISHER_CREDENTIALS`,
   `GH_PAT`, `XPOSED_MODULES_REPO_TOKEN`, and `GOOGLE_SERVICES_JSON` where the
   product has Firebase flavours.
5. The pin contract holds: `ci/verify_toolkit_pin.sh` run from the repository
   root must pass, so the GitHub run cannot build against a different toolkit
   than the GitLab pipeline would have used.

## Rehearse first (no side effects)

`dry_run: true` builds everything and publishes nothing. It does not need a tag
that exists yet: the guard compares the tag *name* with `versionName`, so the
next version is a valid rehearsal target, and the only external call the run
makes is the Play track query in `release-meta` (read-only against the track,
plus an edit that is created and abandoned).

```bash
gh workflow run release.yml --repo <owner>/<repo> --ref <default-branch> \
  -f release_tag=v<versionName-from-gradle/libs.versions.toml> \
  -f dry_run=true \
  -f publish_github_release=false -f publish_play=false -f publish_modules_repo=false
```

Leave `RELEASE_OWNER` at `gitlab` while rehearsing: the caller's eligibility job
allows a `workflow_dispatch` rehearsal without ownership, and refuses a
non-dry-run dispatch by anyone who is not the owner.

A good rehearsal ends like XposedSmsCode run `39956819116` (2026-10-23):
`Check release ownership` success, `Resolve release metadata` success (toolkit
fetched at the pinned SHA from GitLab, guard passed, Play axis resolved),
`Build release APKs` and `Build Play bundle` success, and all three publish
jobs **skipped**.

Before the rehearsal, run the release guard locally with the same tag, because
the guard fails the pipeline for reasons that have nothing to do with GitHub:

```bash
scripts/release/check_release_guard.sh v<versionName>
```

Stale README badge blocks are the usual one — the catalog moves with dependency
updates and `sync:readme-badges` only fires on a schedule or from the GitLab
web UI. While the Runners are down you fix it with the same driver that job
uses: `bash <toolkit>/codegen/sync_readme_badges.sh . --write`, then commit.

## Emergency release

1. Confirm the failure is a Runner outage, not a repository problem, and that
   GitLab can still serve the submodules and this toolkit.
2. Make sure the release content is on both hosts. `sync:github` needs a
   Runner, so during an outage it has not run: push the branch yourself.
   ```bash
   git push origin <branch>
   git push github <branch>        # add the remote if the clone has none
   ```
3. Create the signed tag locally, exactly as you would for a GitLab release:
   ```bash
   scripts/release/release_tag.sh          # or the project's own entry point
   ```
4. Push the tag to **GitHub only**. The chain needs it there: it checks out the
   tag ref, and the Xposed-Modules-Repo step refuses a source ref that is not a
   signed tag object. Do not push it to GitLab yet -- pushing a release tag
   creates that project's tag pipeline immediately, and even with no Runner
   available the pipeline is queued, so it fires and publishes a second time the
   moment a Runner returns. The tag goes back to GitLab in the recovery step.
5. Move the switch: set the GitHub repository variable `RELEASE_OWNER` to
   `github`. Nothing else decides who publishes -- a mirrored tag push while it
   says `gitlab` would only build a rehearsal.
6. Dispatch on the tag:
   ```bash
   gh workflow run release.yml --repo <owner>/<repo> --ref v<X.Y.Z> \
     -f release_tag=v<X.Y.Z> -f dry_run=false
   ```
   Dispatching on the tag ref is what makes the checkout and the workflow
   definition both come from the released commit.
7. Check the artifacts against the last GitLab release of the same product:
   asset names, the `135-3.4.1` style tag pushed to Xposed-Modules-Repo, the
   Play submission state, and the release notes body.
8. Send the announcement manually or wait; nothing here sends it.

## After the Runners are back

The GitHub side may now hold refs that GitLab does not, and `sync:github` will
force-push GitLab's view over the mirror. Write back first, then let it run.

```bash
TOOLKIT="$(scripts/resolve_ci_toolkit.sh)"
bash "$TOOLKIT/release/reconcile_github_refs.sh" --repo-dir . --github-remote github
# add --apply once the report is what you expect
```

It is read-only by default and reports, per repository:

| Status | Meaning | What to do |
| --- | --- | --- |
| `PENDING_TAG` | annotated tag, its commit is already in GitLab | `--apply` writes the tag object back |
| `PENDING_TAG_WITH_COMMITS` | the tag's commit is not in GitLab | land the commits first, then the tag |
| `LIGHTWEIGHT_TAG` | not an annotated tag object | hand review; the chain never makes these |
| `LEAKED_TAG` | a `backup/`, `archive/`, `tmp/`, `wip/` or `keep/` ref reached GitHub | delete it on GitHub; never import it |
| `GITHUB_ONLY_BRANCH` | branch with no GitLab counterpart | decide whether it belongs in GitLab |
| `GITHUB_ONLY_COMMITS` | commits on a shared branch GitLab lacks | land them by hand, then re-run |

A branch that is merely behind is printed as `lag` and is not a finding: the
next `sync:github` run resolves it.

Two things the script cannot decide for you:

- **Publishing twice.** The tag you are writing back is a release tag, and
  pushing it to GitLab creates that project's tag pipeline, whose publish jobs
  run whenever GitLab's `RELEASE_OWNER` is `gitlab`. If GitHub already published
  this version, set GitLab's `RELEASE_OWNER` to something else for the backfill
  push, then put it back to `gitlab`. The reconcile step is the only moment in
  the whole procedure where the two hosts' switches point the same way by
  design -- GitHub's is still `github` while you write back, which is what keeps
  the mirrored tag from re-publishing there.
- **The switch itself.** Put GitHub's `RELEASE_OWNER` back to `gitlab` only
  after the write-back is done; while it says `github`, a mirrored tag push will
  make the GitHub chain try to publish again.

Then verify the mirror agrees: `git ls-remote` both ends for `refs/heads/<branch>`
and the release tags, and run a normal GitLab pipeline for the next change so
`sync:github` reasserts the default branch.

## What has and has not been executed

The build half of this procedure has run on GitHub-hosted runners and is known
good: submodule checkout over `GITLAB_TOKEN`, toolkit fetch at the pinned SHA
from GitLab, the release guard with the project's own
`scripts/config/release-policy.json`, keystore decoding, `-PisCiBuild=false`,
signature validation against the pinned certificate fingerprint, the release APK
split set, and the Play bundle with mapping.

The three publish jobs have **not** run end to end: they are gated behind
`!inputs.dry_run` and `RELEASE_OWNER == 'github'`, so exercising them means
publishing a real version. The first live use of this procedure is therefore a
real release, and the artifact checks in step 7 are the verification. Read them
against the last GitLab release of the same product before you announce
anything.
