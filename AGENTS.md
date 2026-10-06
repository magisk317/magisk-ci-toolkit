# Local Agent Guidance

## Project Scope

This repository is the shared CI implementation for XposedSmsCode, xinyi-relay, and
MiPushFramework. Keep consumer-specific build policy in the consumer repositories and keep shared
checkout, Android CI, release, security, notification, and code-generation behavior here.

## Immutable Checkout Contract

- Production consumers should pin the toolkit with one immutable tag (for example `ref: v1`), not a
  bare commit SHA: a SHA looks equally pinned but becomes unreachable the moment the toolkit history
  is rewritten, which then breaks every consumer at once. Tags survive rewrites because the release
  process re-points them.
- GitLab consumers must use that same ref for both `include.ref` and the top-level
  `MAGISK_CI_TOOLKIT_REF`; otherwise the included YAML and the runtime checkout can drift apart.
- Tags and full commit SHAs must be fetched directly and checked out detached. Do not pass them to
  `git clone --branch`, and do not silently fall back from a missing ref to `main` or another moving
  ref.
- Keep `ci/resolve_git_checkout.sh` and the bootstrap logic in `.gitlab/ci/android.yml` behaviorally
  aligned. Branches and tags remain supported for development and migration work.
- Treat the checkout destination as resolver-owned scratch state. Preserve exact-ref verification
  and update the configured `origin` when reusing an existing checkout.

## Release Channel Semantics

- Play publishing is best-effort by template policy: `.magisk_android_publish_play` sets
  `allow_failure: true`. A Play-side block (policy review, permission declaration, track rejection) is
  environmental, not a code defect — it must not fail the release pipeline or gate the Telegram
  notification. `release/publish_play.sh` always records `MAGISK_RELEASE_STATUS`
  (`published` / `skipped` / `failed`, plus `MAGISK_RELEASE_FAIL_REASON` on failure) in the release env
  file, so an orange job keeps a machine-readable explanation.
- The notify layer must not depend on the publish layer in the DAG: telegram jobs must not `needs`
  release jobs (`*:release:*`). Failure propagation between release channels is each job's own
  `allow_failure` semantics, never the pipeline graph. Consumers keep their own `needs` wiring (job
  names differ per project); this repository owns the job-level semantics and the audit trail.

## CI Java Runtime

Android jobs take their JDK from `.magisk_android_base` in `.gitlab/ci/android.yml`. Two
configurations are supported; which one is active depends only on whether a published image
carries the target Java major on a new-enough glibc. Keep the decision in the toolkit only --
consumers must never restate JDK setup in their own `.gitlab-ci.yml`.

**Hard constraints (they decide the choice, whichever one is active):**

- **glibc >= 2.38.** The runners mount host-built ARM `aidl` / `aapt2` binaries that require
  `GLIBC_2.38`, so the base distro must be Ubuntu 26.04 / Debian trixie or newer. This is what
  ruled out Corretto 27 (AL2023 glibc 2.34 / Alpine musl) and Liberica 27 (bookworm 2.36) in
  2026-09.
- **A published `linux/arm64/v8` manifest for the tag.** The arm64 runner is rootless on
  Oracle ARM; a tag without an arm64 manifest fails at pull time with
  `runner_configuration_error` and never reaches the build script.
- **Eclipse Temurin tag numbering.** `27-jdk` is Java major 27, but a bare `27` tag resolves
  to 11.0.27. Always spell the `-jdk` (or `-jre`) suffix.

**A. Published JDK image -- preferred whenever it exists for the target major**

```yaml
image: "eclipse-temurin:<major>-jdk"
```

The image supplies its own `JAVA_HOME` (`/opt/java/openjdk`) and `PATH`. Delete the JDK
staging block from `before_script` and do **not** export `JAVA_HOME` on top of it.
`eclipse-temurin:27-jdk` is based on `ubuntu:26.04` and publishes `linux/amd64` +
`linux/arm64/v8`, so it satisfies both constraints above. Docker-tag bumps are already
handled by Renovate in this repository (`rust:*`, `renovate/renovate:*`), so pinning the JDK
to an image turns Java upgrades into an automatic PR.

**B. Ubuntu base + Adoptium tarball -- fallback when no image qualifies**

Used from 2026-09-26 (commit `b6dc220`) until a 27 image existed. It is the recipe to restore
the next time a major ships before its image does:

```yaml
image: "ubuntu:26.04"
```

```bash
# staged by .magisk_android_base before_script; $ANDROID_HOME is the persistent SDK mount,
# so each runner downloads the tarball once
magisk_jdk_dir="$ANDROID_HOME/jdk-<major>"
if [ ! -x "$magisk_jdk_dir/bin/javac" ]; then
  exec 9>"$ANDROID_HOME/.jdk.lock" 2>/dev/null || true
  flock 9 2>/dev/null || true
  if [ ! -x "$magisk_jdk_dir/bin/javac" ]; then
    case "$(dpkg --print-architecture)" in
      amd64) magisk_jdk_arch=x64 ;;
      arm64) magisk_jdk_arch=aarch64 ;;
      *) echo "Unsupported runner architecture" >&2; exit 1 ;;
    esac
    magisk_jdk_tmp="$(mktemp -d)"
    curl -fsSL --retry 2 \
      "https://api.adoptium.net/v3/binary/latest/<major>/ga/linux/${magisk_jdk_arch}/jdk/hotspot/normal/eclipse" \
      -o "$magisk_jdk_tmp/jdk.tar.gz"
    rm -rf "$magisk_jdk_dir"
    mkdir -p "$magisk_jdk_dir"
    tar -xzf "$magisk_jdk_tmp/jdk.tar.gz" -C "$magisk_jdk_dir" --strip-components=1
    rm -rf "$magisk_jdk_tmp"
  fi
  flock -u 9 2>/dev/null || true
fi
export JAVA_HOME="$magisk_jdk_dir"
export PATH="$JAVA_HOME/bin:$PATH"
```

Known trade-off of B: `latest/<major>/ga` freezes whatever version the first runner cached,
so patch updates never arrive and two runners can disagree. Prefer A whenever possible.

**Switching checklist**

1. Edit `image:` and the JDK staging block in `.gitlab/ci/android.yml`.
2. Grep the whole tree for `jdk-27`, `JAVA_HOME`, and `XINYI_JDK_DIR` -- hardcoded paths live
   in consumers (xinyi's `scripts/ci/gitlab_stage_jdk27.sh` and `.xinyi_desktop_kmp_linux`
   restate the same fetch for the pure-JVM desktop track) and in packaging drivers.
3. Consumers pick up the change differently: xinyi includes this project by `ref: v1`
   (re-point the tag), XposedSmsCode and MiPushFramework use the `.magisk-ci-toolkit`
   submodule (bump the gitlink). The two are not synchronized, so expect a window where
   projects disagree.
4. Validate with the full gate on every consumer -- `detekt` plus the branch's full test task
   set and `kover`, not `assemble` alone. The Gradle/Kotlin/AGP toolchain probe changes from
   "a JDK under `ANDROID_HOME`" to "the system JDK", which `assemble` does not exercise.
5. If the image is large or freshly published, pre-pull it once on **both** runner hosts
   (lzc amd64 and the Oracle ARM64 rootless host). A cold pull that fails surfaces as
   `runner_configuration_error` before any code runs.

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

After changing release templates or `release/publish_play.sh`, also run the release contracts:

```bash
bash ci/tests/test_linux_release_template.sh
bash release/tests/test_publish_play.sh
```

The pnpm helpers (`ci/resolve_pnpm_version.sh`, `ci/ensure_pnpm.sh`) treat the `packageManager`
field in a consumer's `package.json` as the single source of truth for the pnpm version. Consumers
must not hardcode the version in CI variables or scripts; resolve it through these helpers so a
Renovate `packageManager` bump propagates automatically.

Use `shellcheck` for changed shell files when it is available. Validate edited GitLab YAML with a
YAML parser before pushing.
