# Hosting Ownership And GitHub Cutover

This runbook covers XposedSmsCode, xinyi-relay, MiPushFramework, their shared source repositories,
and MiPushZygisk. It records ordering and safety rules only; commit counts, branch tips, backup
branch names, and copied secret inventories belong to live inspection rather than this document.

## Current state

As of 2026-07-26, live `git ls-remote` checks for the three GitHub parent repositories return HTTP
403 because the owner account is suspended. GitLab remains the source, dependency automation, CI,
and release owner until every target GitHub repository is reachable again.

Recheck live remotes before using this runbook. Do not infer current reachability or divergence from
the date above.

## Ownership rules

- Exactly one platform owns dependency automation and release side effects at a time.
- `DEPENDENCY_OWNER` selects the Renovate/Dependabot side; `RELEASE_OWNER` selects release and Play
  publication. Do not switch both platforms on concurrently.
- Shared repositories are published before parent repositories that pin them.
- Production toolkit consumers pin one full commit SHA for every GitLab `include.ref` and
  `MAGISK_CI_TOOLKIT_REF`.
- Parent-specific build tasks and artifact policy stay in the parent repository. Shared checkout,
  retry, release, notification, and security behavior stays in this toolkit.

## Cutover sequence

1. Confirm every GitHub target exists, is writable, is not archived, and has the expected default
   branch. Fetch both remotes and compare live refs.
2. Stop if GitHub has unique commits. Reconcile divergence explicitly; never force-push as part of
   the generic cutover.
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
