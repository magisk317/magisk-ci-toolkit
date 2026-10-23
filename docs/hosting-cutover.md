# Hosting Ownership And GitHub Cutover

This runbook covers XposedSmsCode, xinyi-relay, MiPushFramework, their shared source repositories,
MiPushConfigurations and MiPushZygisk. It records ordering and safety rules only; commit counts, branch tips, backup
branch names, and copied secret inventories belong to live inspection rather than this document.

## Current state

Rechecked 2026-10-21: every GitHub remote answers `git ls-remote` again, so the 2026-07-26 note
below is historical. The three GitHub parent repositories and the shared repositories all respond,
and the shared repositories whose default branch is mirrored are pushed to by pipeline.
The two MiPush satellites are the exception still open: GitLab `beta` is their default branch and the
mirror publishes `beta`, while GitHub still answers to `main`, so their visible GitHub tip lags by
design until step 3 of the first-mirror sequence is finished.

> As of 2026-07-26, live `git ls-remote` checks for the three GitHub parent repositories returned
> HTTP 403 because the owner account was suspended.

GitLab remains the source, dependency automation, CI, and release owner. GitHub holds a redundancy
mirror only, under the contract below.

Recheck live remotes before using this runbook. Do not infer current reachability or divergence from
the date above.

## Mirror contract

`.gitlab/ci/github-sync.yml` defines `.magisk_github_sync`, the only sanctioned way to put this
ecosystem's content on GitHub. A consumer includes it, sets
`MAGISK_GITHUB_MIRROR_REPOSITORY` to the GitHub `owner/name`, and adds a `sync` stage. The job:

- runs only on a push to the default branch and on tag pipelines, never on feature branches or merge
  requests, so a throwaway branch cannot become the visible GitHub tip;
- force-pushes that branch and its tags, which means a commit made directly on GitHub is
  overwritten by the next pipeline rather than merged anywhere. Tags whose names start with
  `backup/`, `archive/`, `tmp/`, `wip/` or `keep/` are withheld: they point at history a
  rewrite retired, and a public host cannot be asked to forget what was pushed to it. Set
  `MAGISK_GITHUB_MIRROR_EXCLUDED_TAG_PREFIXES` to change the list;
- takes the target name from the variable, never from `CI_PROJECT_NAME`, because several GitHub
  repository names still predate the `magisk-` prefix used on GitLab.

Every repository in the ecosystem now uses the anchor. The three parents plus MiPushConfigurations
and MiPushZygisk used to hand-copy a sync job whose tag branch ran `git push github --tags --force`,
which would have published the withheld safety-net tags the first time a release tag was pushed;
they were converted on 2026-10-21. A conversion keeps only the consumer-specific decision in the
consumer: the three parents set `stage: release` because `android:release:github` needs the tag on
GitHub before it creates the release there, MiPushFramework drops its `ci-android` runner tag so a
mirror push no longer occupies an Android build slot, and the two MiPush satellites keep `needs: []`
and trade `image: alpine:latest` for the pinned utility image. The push, the tag filter and the
remote cleanup belong to the anchor alone, which is why copying it is not the same as including it.

Mirroring is redundancy, not cutover. `.gitmodules`, toolkit resolver URLs and CI clone URLs keep
pointing at GitLab; step 5 of the sequence below is the only thing that changes them, and it has not
happened.

### First mirror run

A repository that has never been mirrored needs one deliberate pass, in this order:

1. Audit divergence and reconcile every GitHub-only commit into GitLab before anything is pushed.
2. Run the mirror so the default branch and the tags land on GitHub; the target branch may not exist
   yet, which is the only case where creating it is legitimate.
3. Repoint the GitHub default branch at the mirrored name where the two differ, then retire the stale
   branch and every branch whose unique content no longer exists.
4. Check that no GitHub-side writer is left enabled: `gh api repos/<repo>/actions/workflows` must show
   nothing active that can push commits or open dependency pull requests, and `.github/dependabot.yml`
   must be gone. A mirror force-pushed over an active writer produces silent loss, not a conflict.

The six shared repositories completed this pass on 2026-10-21, in the order above. Step 4 is the part
an API cannot finish by itself: Dependabot security updates and code-scanning default setup are
repository settings rather than workflows, and GitHub owns the `dynamic/dependabot/*`,
`dynamic/dependency-graph/*` and `dynamic/github-code-scanning/*` entries outright -- they answer
`422 Unable to disable this workflow` to the workflow endpoint. With `.github/dependabot.yml` gone
they schedule nothing, so the residual is a listed-but-inert entry, not a writer.

## Divergence audit

Stop before any force-push that could drop work. For every GitHub ref, in this order:

1. Count commits unreachable from **all** GitLab refs, `archive/*` and `backup/*` tags included. A
   rewrite or squash makes a branch look unique by SHA while every change is already on GitLab; only
   counting against the default branch reports false divergences.
2. For the remaining commits, compare subjects against GitLab history. Squashed histories match on
   subject, not on patch id.
3. Diff the ref against the GitLab default branch as a tree (`--name-status`, split by add, modify,
   delete) to size what a force-push would actually destroy.
4. Check whether the change was re-implemented elsewhere rather than abandoned. Superseded work needs
   the consuming code open, not just a matching commit message.

The 2026-10-21 audit of the six shared repositories found one genuine divergence: a
`ProcessNameResolver` hardening commit that existed only on GitHub. It was recovered into GitLab
before that repository was mirrored. Everything else on the GitHub shared remotes was either
identical, already contained in a GitLab ref, or superseded.

## Dependency automation ownership

Dependency automation runs on GitLab: `.gitlab/ci/renovate.yml` with `.gitlab/renovate.json`,
extending the shared catalog in `default.json`. GitHub-side Renovate entry points in the shared
repositories were removed on 2026-10-21 (the three `renovate/configure` branches and the open pull
requests they created). The GitHub Actions workflows that the shared repositories still carry are
`disabled_manually` on GitHub; treat them as dead surface and delete rather than re-enable, because
a workflow that can run on both hosts is how two dependency owners appear again.

The parent repositories each carried `.github/dependabot.yml`, narrowed at the time to
`github-actions` only. That is still a second dependency owner: Dependabot opens branches and
pull requests against the GitHub copy, and anything merged there is force-pushed over by the next
mirror run, so the bump silently disappears instead of landing on the source. Those files are
removed from GitLab, which deletes them from GitHub with the next mirror push, and Dependabot
security updates are switched off at the repository setting so GitHub cannot reopen the question.

Dependabot is not the only GitHub-side writer. `gh api repos/<repo>/actions/workflows` showed
several parent workflows still `active` (CI, Detekt scan, Detekt autofix, shared-submodule
compat, dependency submission). A workflow that can push commits must be disabled on GitHub, not
merely left unreferenced, before the mirror is trusted to be the only history. Every repository-owned
one was disabled on 2026-10-21; check the live state again rather than trusting this list, because a
re-enabled workflow is indistinguishable in the mirror's history from a lost commit.

## Ownership rules

- Exactly one platform owns dependency automation and release side effects at a time.
- `DEPENDENCY_OWNER` selects the Renovate/Dependabot side; `RELEASE_OWNER` selects release and Play
  publication. Do not switch both platforms on concurrently.
- Shared repositories are published before parent repositories that pin them.
- Production toolkit consumers pin one full 40-character commit SHA and repeat it for every GitLab
  `include.ref`, the top-level `MAGISK_CI_TOOLKIT_REF`, any generated resolver fallback, and every
  GitHub-side toolkit ref — a cross-repository `uses: <repo>/magisk-ci-toolkit/<path>@<ref>`, the
  `ref:`/`toolkit_ref:` input handed to the step that clones the toolkit, or a toolkit `git clone`
  argument. GitHub Actions cannot build a `uses:` ref from an expression, so the SHA is written
  literally in the caller workflow and that literal is what the guard reads. The `v1` tag was deleted
  on 2026-10-21; `ci/verify_toolkit_pin.sh` enforces exactly this shape on both hosts, and `AGENTS.md`
  carries the contract.
- Parent-specific build tasks and artifact policy stay in the parent repository. Shared checkout,
  retry, release, notification, and security behavior stays in this toolkit.

## GitHub fallback release chain

The GitHub chain exists for one failure mode: the GitLab runner fleet is unavailable and a release
still has to ship. It is a fallback, not a cutover — GitLab keeps ownership, and the two hosts run
the same toolkit scripts at the same pinned SHA so "same behaviour" is a property of the code, not a
promise in a document.

- `.github/workflows/release-android.yml` is a `workflow_call` chain: guard and release metadata,
  Play-axis version resolution, APK build with signature validation, optional Play bundle, GitHub
  Release, Play submission, and the Xposed-Modules-Repo publish. Callers pass the values their
  `.gitlab-ci.yml` already passes to `.gitlab/ci/android-release.yml`.
- The tag is never created in Actions. A release tag comes from `release/release_tag.sh` on a
  workstation, is pushed to GitHub, and the workflow is dispatched with that tag as an explicit input.
  No signing key is ever placed in a GitHub secret: Xposed-Modules-Repo requires a signed annotated
  tag object, so the chain refuses to publish a channel tag whose source tag is missing, unsigned, or
  a lightweight tag, and it pushes that object before it lets `gh release create` run.
- Publishing is gated three ways: `enabled` carries the caller's `RELEASE_OWNER` check, each channel
  has its own switch, and `dry_run` builds and verifies without any external write.
- `RELEASE_OWNER` on the GitLab group variable stays `gitlab` while `sync:github` is active. The sync
  anchor force-pushes the default branch and every release tag, so a GitHub-side tag or commit created
  during a fallback has to be reconciled back to GitLab before the next sync runs, or the mirror
  overwrites it.
- Telegram release notification is not part of the chain: `send-telegram-notification.yml` is a
  separate `workflow_call` and the chat id, project tag and pin behaviour are per-repository, so the
  caller wires it from the release events and reads the outputs the chain exports.

## Cutover sequence

1. Confirm every GitHub target exists, is writable, is not archived, and has the expected default
   branch. Fetch both remotes and compare live refs. Where a GitHub default branch is still named
   `master` while GitLab uses `main`, note that GitHub refuses a default branch that does not exist
   yet: mirror `main` first, repoint the default branch at it, then retire `master`. Leaving both
   names in place is how the stale one keeps being the visible one.
2. Stop if GitHub has unique commits. Reconcile divergence explicitly using the audit above; never
   force-push as part of the generic cutover.
3. Push shared source repositories and required tags first, then verify every parent-pinned SHA is
   reachable from GitHub.
4. Push parent branches without rewriting history. MiPushFramework's historical GitHub branch name
   may differ from the current GitLab `beta`; choose the destination only from live repository state.
5. Change `.gitmodules`, toolkit resolver URLs, and external CI clone URLs only after their target
   commits are reachable. Synchronize and verify recursive submodule checkout from a fresh clone.
6. Align GitHub Actions with the active GitLab behavior: build matrix, release guard, signing,
   artifacts, notifications, dependency automation, and platform-specific runner constraints.
7. Run a non-release branch build, dependency-bot dry run, and signed release rehearsal. Compare
   produced assets and release notes before changing ownership variables.
8. Switch dependency ownership first. Switch release ownership only after automation is stable, then
   keep GitLab as a read-only mirror or documented rollback target.

## Acceptance checks

- Shared and parent refs resolve from a fresh GitHub clone with recursive submodules.
- GitHub and GitLab build the intended modules and architectures from the same source SHA.
- Only one bot opens dependency updates and only one platform performs release/Play side effects.
- Release notes still come from each parent repository's `docs/CHANGELOG.md`.
- APK/AAB/ZIP, mapping, native symbols, desktop, and module-repository assets retain each parent's
  existing ownership boundaries.

## Rollback

If checkout, CI, signing, automation, or publication parity fails, restore `DEPENDENCY_OWNER` and
`RELEASE_OWNER` to GitLab, keep GitLab submodule/toolkit URLs active, and stop the cutover. Do not
delete GitLab branches, tags, variables, or runner configuration until one complete GitHub release
cycle has passed and rollback is no longer required.
