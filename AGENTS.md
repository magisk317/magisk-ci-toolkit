# Local Agent Guidance

## Project Scope

This repository is the shared CI implementation for XposedSmsCode, xinyi-relay, and
MiPushFramework. Keep consumer-specific build policy in the consumer repositories and keep shared
checkout, Android CI, release, security, notification, and code-generation behavior here.

## Immutable Checkout Contract

- Production consumers pin the toolkit with one full 40-character commit SHA. Moving refs were the
  rule until 2026-10-21, when `v1` was deleted: a re-pointed tag changes what every consumer runs
  without producing a commit in that consumer, so a pipeline can differ from its own history and no
  diff explains it. A SHA is the reviewable half of that trade -- the cost is that a toolkit release
  or a history rewrite means one explicit bump commit per consumer, and that bump is the point.
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

**A. Published JDK image -- ACTIVE since 2026-10-07**

```yaml
image: "eclipse-temurin:<major>_<build>-jdk-resolute"   # e.g. 27_35-jdk-resolute
```

Spell both optional segments:

- `-resolute` pins the OS base to Ubuntu 26.04. The bare `27-jdk` tag points at whatever
  base Adoptium currently defaults to, so a future default change would silently move the
  glibc floor underneath the aidl/aapt2 assumption. (`27-jdk`, `27_35-jdk`,
  `27-jdk-resolute` and `27_35-jdk-resolute` currently resolve to the same amd64 manifest;
  only the index digests differ by attestation entries.)
- `<major>_<build>` pins the JDK build (`27_35` = Temurin 27+35). The runners pull with
  `if-not-present`, so a rolling tag like `27-jdk-resolute` would keep whatever digest each
  host first cached -- no patch updates would ever arrive, and lzc (amd64) and the Oracle
  arm64 runner could silently disagree. Changing the tag text is what forces a new pull.
- Bonus: the image's base is the very same `ubuntu:26.04` manifest digest
  (`sha256:88a381d5...`) this job used to pull directly, so the base layer is already
  cached on both runners and only the ~113MB JDK layer is new.

The image supplies its own `JAVA_HOME` (`/opt/java/openjdk`) and `PATH`. Delete the JDK
staging block from `before_script` and do **not** export `JAVA_HOME` on top of it.
`javac`, `jlink`, `jpackage`, `jmod` and `jshell` are all present; `git`, `curl`, `unzip`,
`python3` and `ripgrep` are not, so the apt install block stays.


**B. Ubuntu base + Adoptium tarball -- fallback when no image qualifies**

Used from 2026-09-26 (commit `b6dc220`) until a 27 image existed (retired 2026-10-07). It is the recipe to restore
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
3. All three consumers (XposedSmsCode, xinyi-relay, MiPushFramework) include this project
   with `include: project: magisk3171/shared/magisk-ci-toolkit, ref: <full-40-character-commit-sha>` -- there is **no**
   `.magisk-ci-toolkit` submodule in any of them. Pushing to `main` changes nothing for them:
   each consumer keeps its own pinned SHA, so a toolchain switch needs one bump commit per
   consumer plus the matching top-level `MAGISK_CI_TOOLKIT_REF`, and a consumer that is not
   bumped keeps running the old image until it is.
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
bash gradle/tests/test_build_guard_drift.sh
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

## ARM Runner SDK And Build-Tools Completeness

The arm64 runner (Oracle ARM, rootless Docker) keeps its Android SDK on a persistent
runner volume, so a half-installed build-tools revision survives across pipelines and
survives image re-pulls. The symptom is a validation failure before any compilation:

```
Installed Build Tools revision 37.0.0 is corrupted. ...
```

or `Build-tool 37.0.0 is missing DEXDUMP`.

AGP validates a build-tools revision by checking that the binaries it may invoke exist
(`aapt`, `aapt2`, `aidl`, `d8`, `dexdump`, `lib/`, ...); it never executes the x86_64
ones on ARM. Only `aidl` and `aapt2` actually run, and both come from the host ARM
overlay the runner bind-mounts over the SDK (`/usr/local/bin/aapt2`,
`/usr/local/bin/aidl`), with AGP pointed at the ARM `aapt2` through
`-Pandroid.aapt2FromMavenOverride`. Everything else is checked for existence only, so a
pruned or truncated revision fails the entire build for no functional reason.

`android/install_arm_android_tools.sh` therefore backfills every missing entry in each
`build-tools/<rev>` directory from the most complete sibling revision after installing
the requested packages. Version metadata (`source.properties`, `package.xml`,
`runtime.properties`) is never copied, so AGP still sees the true revision numbers.

When this failure appears, do not hunt for an ARM `aapt`: none exists anywhere on the
host. Backfill from a complete sibling revision and move on.

History (2026-10-09): after the toolchain bump, every consumer pipeline began failing
this way because `build-tools/37.0.0` on the runner lacked `aapt`, `d8`, `dexdump` and
`lib/`. An earlier build that same day had passed with the older AGP, which validated
fewer binaries -- the regression was the validator, not the SDK.

## Gradle Build Guard

`gradle/00-build-guard.gradle` is the global serial-build lock. No consumer `include:`s it: the
runner host deploys it. `gradle-lock-sync` copies the authoritative host file to every
`GRADLE_USER_HOME/init.d`, to every unpacked Gradle distribution `init.d`, and to
`.locks/00-build-guard.gradle`, which the runner's `pre_build_script` copies into each CI slot
home. That makes the repository copy the only *reviewable* artifact and the deployed copy the
only *effective* one, so keep them byte-identical:
`gradle/tests/test_build_guard_drift.sh` compares them whenever a deployed copy is readable and
asserts the invariants below.

Load points decide whether a fix exists at all. A TestKit nested build runs with
`GRADLE_USER_HOME` = a throwaway `<module>/build/tmp/.../.gradle-test-kit` directory, so what it
evaluates is the **distribution** copy. A change that lands only in `~/.gradle/init.d` cannot
reach the JVM that deadlocks.

Three rules, each paid for by an incident:

- Never open a second `FileChannel` on the lock inode from a JVM that already holds the lock.
  POSIX record locks belong to the process, not the fd: closing any fd on that inode drops the
  process's whole lock (2026-10-21, the lock quietly became a no-op). The same-JVM re-entrant
  path must return before `FileChannel.open`.
- Excuse nested builds through the *environment*. The re-entrancy marker is a System property and
  properties do not cross a fork, so the build holding the lock injects `MAGISK_GW_LOCK_HELD=1`
  into its own `Test` task environments -- on both the acquire path and the re-entrant path,
  because whichever copy loads first is the one that acquires. Env is the only channel proven to
  cross job -> client -> daemon -> test worker -> nested daemon (the lock directory itself reaches
  the nested daemon the same way).
- Queueing must be bounded and must fail loudly: `MAGISK_GRADLE_LOCK_MAX_WAIT_SEC` (default 3000 s
  against a measured longest holder of 1248 s), a holder-is-my-ancestor probe after 60 s, and
  `MAGISK_BUILD_GUARD_DEADLOCK` rethrown past the swallow-all catch. Without them, 2026-10-23 saw
  `android:test:pure-modules` consume its entire 7200 s job budget with zero trace output -- the
  nested daemon's `排队中 Ns —— 当前持有者: pid=…` lines only ever reach
  `<module>/build/tmp/test/work/.gradle-test-kit/test-kit-daemon/<ver>/daemon-<pid>.out.log`.

A guard change does not travel through the pin chain: it deploys to the host, so it is live for
the next job no matter which SHA a consumer pins, and bumping a pin neither enables nor disables
it. Order of work: edit here, run `bash gradle/tests/test_build_guard_drift.sh` on the host, then
install as the authoritative source and `gradle-lock-sync sync`, requiring `gradle-lock-sync status`
to report 0 anomalies. Keep any backup outside the `*.gradle` glob -- `init.d` loads every
`*.gradle` file it finds, so `00-build-guard.gradle.bak-<date>` is inert while
`00-build-guard.gradle.bak` would run twice.

Before overwriting the authoritative file, evaluate the draft in an isolated `GRADLE_USER_HOME`
against a scratch project (`gradle help`, plus a registered `Test` task whose `environment` is
printed to prove the injection at runtime). A Groovy parse error in this one file bricks every
build on the machine and every CI job, and nothing else in it will tell you: the entire lock
section is deliberately wrapped in a catch that hides failures.
