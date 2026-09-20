# Local Agent Guidance

## Project Scope

This repository is the shared CI implementation for XposedSmsCode, xinyi-relay, and
MiPushFramework. Keep consumer-specific build policy in the consumer repositories and keep shared
checkout, Android CI, release, security, notification, and code-generation behavior here.

## Immutable Checkout Contract

- Production consumers should pin the toolkit with one full 40-character commit SHA.
- GitLab consumers must use that same SHA for both `include.ref` and the top-level
  `MAGISK_CI_TOOLKIT_REF`; otherwise the included YAML and the runtime checkout can drift apart.
- Raw commit SHAs must be fetched directly and checked out detached. Do not pass them to
  `git clone --branch`, and do not silently fall back from a missing SHA to `main` or another moving
  ref.
- Keep `ci/resolve_git_checkout.sh` and the bootstrap logic in `.gitlab/ci/android.yml` behaviorally
  aligned. Branches and tags remain supported for development and migration work.
- Treat the checkout destination as resolver-owned scratch state. Preserve exact-ref verification
  and update the configured `origin` when reusing an existing checkout.

## Verification

Run the focused shell contracts after changing checkout, Gradle, or code-generation helpers:

```bash
bash ci/tests/test_resolve_git_checkout.sh
bash ci/tests/test_resolve_pnpm_version.sh
bash ci/tests/test_ensure_pnpm.sh
bash gradle/tests/test_run_gradle_with_retry.sh
bash codegen/tests/test_badges.sh
git diff --check
```

The pnpm helpers (`ci/resolve_pnpm_version.sh`, `ci/ensure_pnpm.sh`) treat the `packageManager`
field in a consumer's `package.json` as the single source of truth for the pnpm version. Consumers
must not hardcode the version in CI variables or scripts; resolve it through these helpers so a
Renovate `packageManager` bump propagates automatically.

Use `shellcheck` for changed shell files when it is available. Validate edited GitLab YAML with a
YAML parser before pushing.
