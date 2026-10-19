# magisk-ci-toolkit

Shared CI scripts and tools for XposedSmsCode, xinyi-relay, and MiPushFramework repositories.

## Overview

This toolkit provides modular, reusable scripts for:

- **Security**: Dependency force management, Dependabot alert reconciliation, security fix janitor
- **Release**: Release guards, tag management, release reference parsing
- **CI**: GitHub composite actions and reusable workflows
- **Codegen**: README badge synchronization (driver, release-guard check, GitLab sync job)

Hosting ownership and a future GitLab-to-GitHub cutover are documented in
[`docs/hosting-cutover.md`](docs/hosting-cutover.md).

## Usage

### GitHub Actions

Keep a small resolver in the consumer repository and pin it to a full commit SHA. The resolver
should follow the exact-fetch contract implemented by `ci/resolve_git_checkout.sh`; unlike
`git clone --branch`, an exact fetch supports immutable raw commit SHAs as well as branches and
tags.

```yaml
- uses: actions/checkout@v7
  with:
    submodules: recursive
    fetch-depth: 0

- name: Resolve CI toolkit
  env:
    MAGISK_CI_TOOLKIT_REF: "<full-40-character-commit-sha>"
  run: bash scripts/resolve_ci_toolkit.sh

- name: Setup Android CI
  uses: ./.magisk-ci-toolkit/.github/actions/setup-android-ci
  with:
    checkout: 'false'

- name: Run Gradle
  uses: ./.magisk-ci-toolkit/.github/actions/run-gradle-with-retry
  with:
    arguments: --warning-mode all :app:check
```

`ci/resolve_git_checkout.sh <repository> <ref> <destination>` is also available for checked-out
automation that needs the same behavior. It initializes or reuses a resolver-owned checkout,
fetches the requested object at depth one, checks out `FETCH_HEAD` detached, and verifies that a
40-character SHA resolved exactly. A missing SHA fails closed; it never falls back to a moving
branch.

Consumer bootstrap scripts are generated from the toolkit rather than maintained as independent
copies. After publishing a toolkit commit, regenerate a consumer with:

```bash
bash codegen/sync_consumer_bootstrap.sh /path/to/consumer <full-40-character-commit-sha>
```

Use `--check` in maintenance jobs to fail when either `scripts/resolve_ci_toolkit.sh` or
`scripts/sync_shared_gradle.sh` has drifted from the generated form.

### pnpm toolchain

`ci/resolve_pnpm_version.sh [path/to/package.json]` prints the bare pnpm version (e.g. `11.17.0`)
read from the `packageManager` field of a `package.json`. That field is the single source of truth
(corepack convention), so consumers never hardcode the version and a Renovate bump of
`packageManager` propagates everywhere. The path resolves from the CLI argument, then
`$PNPM_VERSION_PACKAGE_JSON`, then `./package.json`. A corepack integrity suffix
(`pnpm@x.y.z+sha512...`) is stripped; a non-pnpm or missing field fails closed.

`ci/ensure_pnpm.sh [pnpm-version | path/to/package.json]` makes the pnpm on `PATH` match the pinned
version. With no argument it follows `resolve_pnpm_version.sh`; an explicit `pnpm@x.y.z`/`x.y.z`
overrides, and a path resolves from that manifest. It fast-paths when the current `pnpm --version`
already matches (so a corepack-provided pnpm is left untouched), otherwise it installs the exact
version globally. Verify both with `bash ci/tests/test_resolve_pnpm_version.sh` and
`bash ci/tests/test_ensure_pnpm.sh`.

### Bun and shared frontend jobs

`ci/resolve_bun_version.sh [path/to/package.json]` reads the pinned `bun@x.y.z` version from
`packageManager`, and `ci/ensure_bun.sh` installs that exact version only when the current Bun
binary does not match. `BUN_CONFIG_REGISTRY` is passed to npm when installation is required.

Include `/.gitlab/ci/frontend.yml` to use `.magisk_frontend_bun` or `.magisk_frontend_build`.
The template uses `oven/bun:1.4-alpine`, caches `.bun-cache`, resolves the consumer's toolkit, and
keeps checkout-specific commands in the consumer. `.magisk_frontend_build` calls
`ci/frontend_build.sh`, whose `MAGISK_FRONTEND_*_COMMAND` variables optionally run lint,
typecheck, test, and build after `bun install --frozen-lockfile`.

```yaml
include:
  - project: magisk3171/magisk-ci-toolkit
    ref: "<full-40-character-commit-sha>"
    file: /.gitlab/ci/frontend.yml

frontend:build:
  extends: .magisk_frontend_build
  variables:
    MAGISK_FRONTEND_DIR: frontend/webui
    MAGISK_FRONTEND_BUILD_COMMAND: "bun run build"
    MAGISK_FRONTEND_DIST_DIR: frontend/webui/dist
```

Run `bash ci/tests/test_resolve_bun_version.sh` and `bash ci/tests/test_ensure_bun.sh` for the Bun
helper tests. Keep all toolkit includes and `MAGISK_CI_TOOLKIT_REF` on the same immutable SHA in
production consumers.

## Scripts

### Security

#### manage_dependency_forces.py

Manages dependency force rules for Gradle projects.

**Environment Variables:**
- `MAGISK_DEFAULT_PROJECT`: Default Gradle project (e.g., `:app`, `:mipush`)

#### validate_dependabot_graph.sh

Validates Dependabot dependency graph with graceful degradation.

#### reconcile_dependabot_alerts.sh

Reconciles Dependabot alerts with force rules.

**Environment Variables:**
- `MAGISK_ROOT_DEPTH`: Directory depth to project root (default: 2)
- `MAGISK_PYTHON_SCRIPT`: Path to Python script (default: `scripts/security/manage_dependency_forces.py`)

#### janitor_security_fixes.sh

Applies security fixes for Maven, NPM, and Cargo dependencies.

**Environment Variables:**
- `MAGISK_ROOT_DEPTH`: Directory depth to project root (default: 2)
- `MAGISK_PYTHON_SCRIPT`: Path to Python script (default: `scripts/security/manage_dependency_forces.py`)
- `MAGISK_HAS_FRONTEND`: Enable NPM/Cargo fixes (default: `false`)

### Release

#### check_release_guard.sh

Modular release guard with optional checks.

**Functions:**
- `check_version_extraction`: Verify version from TOML
- `check_commit_subjects`: Check for non-ASCII commit subjects in the pending release range. It uses `MAGISK_RELEASE_COMMIT_RANGE`, `MAGISK_RELEASE_BASE_REF`, `CI_COMMIT_BEFORE_SHA`, the current branch upstream, or the latest release tag in that order.
- `check_changelog_section`: Verify CHANGELOG section exists
- `check_tag_matches_version`: Verify tag matches version
- `check_whatsnew_locales`: Check whatsnew locale files (optional)
- `check_fastlane_metadata`: Check fastlane metadata (optional)

#### release_tag.sh

Modular release tag creation with optional pre-push checks.

**Functions:**
- `release_tag`: Core tag creation logic
- `run_detekt_sarif_check`: Detekt SARIF validation (optional)
- `run_webui_checks`: WebUI checks (optional)
- `run_fastlane_sync`: Fastlane metadata sync (optional)

#### release_ref.sh

Tag reference parsing utilities.

### CI

### CI

#### telegram_send_image_list.sh / `.magisk_telegram_images`

GitLab Telegram notifier for container image publishes (text-only `Images:` list).

Consumer example:

```yaml
telegram:images:
  extends: .magisk_telegram_images
  variables:
    MAGISK_CI_TOOLKIT_REF: "<full-sha>"
    MAGISK_TELEGRAM_PROJECT_NAME: "NapGram"
    MAGISK_TELEGRAM_PROJECT_TAG: "#NapGram"
    MAGISK_TELEGRAM_IMAGE_EVENT: "docker-dev"
    MAGISK_TELEGRAM_IMAGE_LIST_COMMAND: "scripts/ci/gitlab_docker.sh list-images"
  needs:
    - job: container:dev:manifest
      artifacts: false
```

The version hashtag is auto-detected from `gradle/libs.versions.toml` or the
root `package.json`. Set `MAGISK_TELEGRAM_VERSION_NAME` only for non-standard
version sources. The notifier honors `MAGISK_TELEGRAM_PIN=latest` the same way
as the `.gitlab/ci/telegram.yml` templates.

#### .github/actions/setup-android-ci

GitHub composite action for Android CI setup.

#### .github/workflows/send-telegram-notification.yml

Reusable workflow for Telegram notifications. Messages use Telegram HTML parse
mode, escaping dynamic text and rendering workflow/release links with short
labels. The workflow honors `MAGISK_TELEGRAM_PIN=latest` for rolling
notification pins: set the `MAGISK_TELEGRAM_PIN` repository variable to
`latest` in the consumer repository (see `.gitlab/ci/telegram.yml`).

#### .gitlab/ci/android.yml

Reusable GitLab CI templates for Android Gradle projects.

Consumer repositories should include this file from the toolkit project:

```yaml
include:
  - project: magisk3171/magisk-ci-toolkit
    ref: "<full-40-character-commit-sha>"
    file: /.gitlab/ci/android.yml

variables:

  # Keep this identical to every magisk-ci-toolkit include.ref.
  MAGISK_CI_TOOLKIT_REF: "<full-40-character-commit-sha>"
```

Consumer repositories then define thin project-specific jobs with `extends`:

```yaml
android:build:
  extends: .magisk_android_build
  variables:
    MAGISK_ANDROID_BUILD_TASKS: ":app:check :app:assembleDebug"
  artifacts:
    paths:
      - app/build/outputs/apk/**/debug/*.apk
```

The templates install Android command line tools into the job workspace and use
the Gradle wrapper from the consumer repository. Projects can override Android
SDK packages with `MAGISK_ANDROID_COMPILE_SDK` and
`MAGISK_ANDROID_SDK_PACKAGES`. Projects that use preview or newly-published SDK
packages can raise the sdkmanager channel with
`MAGISK_ANDROID_SDKMANAGER_CHANNEL`, or override the platform package name with
`MAGISK_ANDROID_COMPILE_SDK_PACKAGE` when sdkmanager publishes a package such as
`platforms;android-37.0` while Gradle still expects `compileSdk = 37`.
The templates resolve this toolkit into `.magisk-ci-toolkit` at runtime and call
`gradle/run_gradle_with_retry.sh`, which retries transient dependency download
and TLS failures up to three times before giving up.
When the job environment exports proxy variables (`https_proxy`/`HTTPS_PROXY`,
`http_proxy`/`HTTP_PROXY`, and `no_proxy`/`NO_PROXY`), the wrapper derives the
matching JVM proxy system properties (`-Dhttps.proxyHost`,
`-Dhttps.proxyPort`, `-Dhttp.proxyHost`, `-Dhttp.proxyPort`,
`-Dhttp.nonProxyHosts`; `socks5://` maps to the `socksProxy*` properties) and
passes them on the Gradle command line. Command-line `-D` flags reach the
Gradle **daemon**, unlike `GRADLE_OPTS`, which only configures the client JVM —
the daemon performs dependency resolution and ignores both `GRADLE_OPTS` and
`HTTP_PROXY`-style variables. `no_proxy` entries are converted from the
comma-separated environment form to the JVM's `|`-separated wildcard form, so
hosts meant to stay direct (for example `repo.maven.apache.org`) keep bypassing
the proxy. Jobs without proxy variables (GitHub-hosted runners) get no extra
flags. Set `MAGISK_GRADLE_PROXY_DISABLE=1` to opt out explicitly.
The runtime checkout accepts a branch, tag, or full commit SHA. Production consumers should pin an
**full 40-character commit SHA** in every include and runtime checkout; a moving tag is forbidden because
becomes unreachable the moment the toolkit history is rewritten, which then breaks every consumer at
once. Use the same ref for every toolkit `include.ref` and for `MAGISK_CI_TOOLKIT_REF`, so the
parsed templates and the scripts executed by jobs cannot come from different revisions.

When all four signing variables (`RELEASE_KEYSTORE`, `STORE_PASSWORD`,
`KEY_ALIAS`, and `KEY_PASSWORD`) are non-empty, the templates decode the base64
keystore to `release.jks` at the **repository root**, restrict it to mode
`0600`, and export an absolute `KEYSTORE_FILE` so every Android application
module can use the same release-compatible identity. The root is also the first
path the shared signing convention plugin looks at (`release.jks`, then
`app/release.jks`). Override the destination with
`MAGISK_ANDROID_RELEASE_KEYSTORE_PATH`. If any variable is missing, the
template leaves signing unset and the consumer project's own fallback policy
applies; it does not bypass consumer signing guards.

#### .gitlab/ci/android-release.yml

Reusable GitLab CI templates for Android tag releases. Include this file
together with `.gitlab/ci/android.yml` and define thin project jobs with
`extends`:

```yaml
include:
  - project: magisk3171/magisk-ci-toolkit
    ref: "<full-40-character-commit-sha>"
    file: /.gitlab/ci/android.yml
  - project: magisk3171/magisk-ci-toolkit
    ref: "<full-40-character-commit-sha>"
    file: /.gitlab/ci/android-release.yml
```

The release templates run only for tags matching `v<major>.<minor>.<patch>*`.
Build jobs can run on either platform, but publishing side effects are guarded by
`RELEASE_OWNER`. Set `RELEASE_OWNER=gitlab` in GitLab CI/CD variables when
GitLab should create releases or publish to Play; keep it unset or `github`
when GitHub owns publishing.

Available templates:

- `.magisk_linux_base` (lightweight Linux runner for validation and publishing jobs)
- `.magisk_android_release_guard`
- `.magisk_android_release_apk`
- `.magisk_android_release_aab`
- `.magisk_android_gitlab_release`
- `.magisk_android_publish_play`
- `.magisk_android_publish_modules_repo`

Common variables:

- `MAGISK_ANDROID_RELEASE_PACKAGE_NAME`: Android application id.
- `MAGISK_ANDROID_RELEASE_GITHUB_REPOSITORY`: source GitHub repository used for
  generated GitHub notes and as the release badge outside GitLab releases, for
  example `magisk317/XposedSmsCode`. GitLab releases use the current
  `CI_PROJECT_URL` for their release badge.
- `MAGISK_ANDROID_RELEASE_PLAY_URL`: optional canonical Google Play listing URL.
  When unset, release notes and Telegram notifications derive it from
  `MAGISK_ANDROID_RELEASE_PACKAGE_NAME`.
- `MAGISK_ANDROID_RELEASE_SHOW_PLAY_LINK`: set to `false` when the package has
  no publicly reachable Play listing yet; defaults to `true`.
- `MAGISK_TELEGRAM_RELEASE_PLAY_URL`: optional Telegram-only override for the
  canonical Play URL. Override the displayed label with
  `MAGISK_TELEGRAM_RELEASE_PLAY_LABEL`.
- `MAGISK_ANDROID_RELEASE_PUBLISH_PLAY`: set to `true` to build/publish the Play
  AAB.
- `MAGISK_ANDROID_RELEASE_PLAY_TRACK`: default Play track, default
  `production`.
- `MAGISK_ANDROID_RELEASE_MODULES_REPO`: GitHub `owner/repo` target for
  Xposed-Modules-Repo publication. That repository expects release tags shaped
  `<versionCode>-<versionName>`, so the job derives its own tag instead of
  reusing the `v<versionName>` tag of the GitLab and GitHub releases, taking the
  versionCode from the `play-release.env` artifact when present and falling back
  to the commit count floored by `MAGISK_PLAY_INITIAL_VERSION_CODE`. Override
  the tag with `MAGISK_ANDROID_RELEASE_MODULES_REPO_TAG`.
- `MAGISK_ANDROID_RELEASE_CERT_SHA256`: public SHA-256 fingerprint expected for
  release APKs. `.magisk_android_release_apk` validates every APK after Gradle
  finishes, before any publisher job can consume the artifacts.
- `MAGISK_ANDROID_RELEASE_APK_ROOTS`: space-separated APK output roots when a
  project packages more than one Android application, such as MiPushFramework.
  Defaults to `app/build/outputs/apk`. Consumed by `.magisk_android_release_apk`
  (signature validation), `.magisk_android_release_github` and
  `.magisk_android_publish_modules_repo` (release asset collection).
- `MAGISK_ANDROID_RELEASE_APK_TASKS` / `MAGISK_ANDROID_RELEASE_AAB_TASKS`:
  **required** gradle task list for the release build, for example
  `:app:assembleRelease` or `:xmsf:assembleRelease :mipush:assembleGithubRelease`.
  Which modules and flavours a project packages is project knowledge, so the
  shared repo declares the contract and never supplies a default value.
- `MAGISK_ANDROID_RELEASE_GRADLE_EXTRA_ARGS`: optional extra `-P` / system
  properties appended to the gradle invocation, such as `-PbuildSplits=true`.
- `MAGISK_ANDROID_RELEASE_KEYSTORE_PATH`: keystore destination, default
  `$CI_PROJECT_DIR/release.jks`.
- `MAGISK_ANDROID_RELEASE_INJECT_VERSION`: default `true`. Resolves the release
  version once per build (versionName from `gradle/libs.versions.toml`,
  versionCode from the Play track), injects it into gradle, and exports
  `play-release.env` so every downstream job reuses the same numbers instead of
  re-deriving them. Set to `false` to let gradle own the version completely.
- `RELEASE_KEYSTORE`, `STORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`: signing
  credentials. `RELEASE_KEYSTORE` is a base64-encoded keystore. Release APK and
  AAB jobs require all four values and pass an absolute, mode-`0600` keystore
  path to Gradle.
- `ANDROID_PUBLISHER_CREDENTIALS`: Google Play service-account JSON, required
  only by `.magisk_android_publish_play`.
- `XPOSED_MODULES_REPO_TOKEN`: GitHub token for
  `.magisk_android_publish_modules_repo`.
- `GITLAB_RELEASE_TOKEN`: optional token for GitLab Release API. If omitted, the
  job uses `CI_JOB_TOKEN`.

#### .gitlab/ci/cancel-mr-pipelines.yml

Automatic merge and cross-MR pipeline cancellation for trusted consumer
projects. A consumer
extends `.magisk_cancel_older_mr_pipelines` and sets
`MAGISK_CANCEL_OLDER_MR_PIPELINES=true`. The `.pre` trigger job starts the
protected `magisk-ci-toolkit/main` controller pipeline and waits for it, but is
allowed to fail so controller outages never block the consumer pipeline or MR.

The trigger passes only the upstream project and pipeline metadata required by
the controller; it does not forward arbitrary YAML or user variables. The controller uses
GitLab's recorded downstream/upstream relationship to identify the real source
project and accepts only the static project allowlist in
`ci/cancel_older_mr_pipelines.sh`, `ci/cancel_older_renovate_pipelines.sh`, and
`ci/auto_merge_upstream_mr.sh`. MR/push pipelines keep the existing cleanup
behavior. Schedule, web, and API pipelines that contain `renovate:gitlab` are
coordinated separately: the newest Renovate pipeline for the trusted target
branch wins, and older active Renovate pipelines are canceled. This is API-level
latest-wins coordination, not a GitLab resource lock.

GitLab has no cancel-on-merge. Native `auto_cancel:on_new_commit` only fires when
a new pipeline starts on the *same* ref, so a merged MR's own
`merge_request_event` pipeline — its ref receives no further pipeline — runs to
completion against already merged code and keeps occupying the runner. Set
`MAGISK_CANCEL_MERGED_MR_PIPELINES=true` as a consumer pipeline variable to let
every push pipeline additionally cancel the still-active
`merge_request_event` pipelines of the merge requests merged in the window
around that push pipeline's creation (default: 15 minutes before to 1 minute
after). Like `MAGISK_CANCEL_OLDER_MR_PIPELINES`, the opt-in reaches the
controller through GitLab's forwarding of upstream pipeline variables — it must
not be re-declared in the trigger job's `variables:` block, because GitLab
passes a self-referencing trigger variable down as the literal string. The
cleanup is checked against the trusted target branch and stays best-effort, so
it can never affect a merge.

Every controller API call goes through the shared retry ladder in
`ci/api_retry.sh`: transient failures (curl exit 6/7/28/35/52/55/56/60 or HTTP
408/429/5xx) are retried up to 6 times with 2 s doubling backoff, while
deterministic failures (404, 401/403) fail on the first attempt. The cancel
POSTs inside the cancel scripts additionally rely on the reconcile loop, which
re-lists and re-cancels stale pipelines for 3 passes.

Automatic merge is limited to a non-Draft MR whose source project is the same
allowlisted project and whose target is that project's configured default
branch. The controller verifies the MR HEAD against the upstream pipeline SHA,
then calls the immediate Merge API without `auto_merge=true`; running, failed,
or canceled pipeline status is intentionally not a merge gate. Conflicts,
stale SHAs, forks, Drafts, and non-default targets are not merged. A trusted
rollout branch named `ci/skip-post-merge/*` receives a `[skip ci]` merge commit
message so CI-policy smoke changes cannot start a target-branch build, Play
publish, or Telegram notification.

Configure `MAGISK_CI_PIPELINE_CONTROL_TOKEN` only in the toolkit project as a
protected, masked, hidden variable. The token must be a fine-grained personal
access token scoped to the `magisk3171` group with only `Pipeline: Read`,
`Pipeline: Update`, and `Protected Branch: Read`. `Protected Branch: Read`
backs the cross-family cancellation fail-safe that checks whether a merge
request source branch is protected. Consumer projects must be in the toolkit
project's inbound CI job-token allowlist; they never receive the control
token.

Configure `MAGISK_CI_MR_AUTOMERGE_TOKEN` alongside it as another protected,
masked, hidden variable. Use a separate fine-grained personal access token
scoped to the `magisk3171` group with only `Merge Request: Read` and
`Merge Request: Merge`. Do not reuse a broad API token or expose this token in
consumer projects.

#### .gitlab/ci/telegram.yml

Reusable GitLab CI templates for Telegram notifications.

Both templates send **one** Telegram media-group message when multiple APK/ZIP
artifacts match:

- each document caption starts with the original file name
- CI/release text is appended on the last item by default
  (`TG_MEDIA_CAPTION_POSITION=last`)
- HTML links in the group caption use `parse_mode=HTML`

`.magisk_telegram_ci` is restricted by template `rules` to **never run on tags**
and the script further limits to `MAGISK_TELEGRAM_CI_BRANCH` (default `beta`) or
`renovate/*` source branches. It no-ops when `TG_BOT_TOKEN` or `TG_CHAT_ID` is
not configured.

`.magisk_telegram_release` runs for release tag pipelines matching
`v<major>.<minor>.<patch>*`, sends the message to `TG_THREAD_ID` (or
`TG_GITLAB_RELEASE_THREAD_ID`), includes the matching changelog section, and
uploads matching release artifacts in the same media group.

Set `MAGISK_TELEGRAM_PIN` to `latest` to pin every successfully sent
notification message. Each new notification is pinned first; after the pin
succeeds, the template unpins the message it had pinned previously — but only
when that pinned message was sent by the same bot in the same topic (no thread
means General). Human pins, other-bot pins, and the bot's own pins in other
topics are never unpinned. The Bot API only exposes the chat's most recent
pinned message, so if another topic pinned in between, the previous same-topic
pin stays pinned instead of being rolled over. A failed pin/unpin only logs a
warning and never fails the CI job. When the variable is unset or `off`, the
notify script makes no extra Telegram API calls.

Optional variables:

- `TG_API_BASE`: Bot API root (default `https://api.telegram.org`). Point to a
  Local Bot API server (for example `http://telegram-bot-api.internal:18081`)
  only for jobs whose runner can reach it; raise `TG_MAX_FILESIZE` above 50MB
  in that case.
- `TG_MAX_FILESIZE`: upload limit in bytes (default `52428800`).
- `TG_MEDIA_CAPTION_POSITION`: `last` (footer, default) or `first`.
- `TG_BOT_TOKEN`, `TG_CHAT_ID`: Telegram bot settings.
- `TG_CI_THREAD_ID`: CI topic. `TG_GITLAB_THREAD_ID` is used only as a GitLab
  compatibility alias for CI.
- `TG_THREAD_ID`: release topic. `TG_GITLAB_RELEASE_THREAD_ID` can be used as a
  GitLab compatibility alias for release.
- `MAGISK_TELEGRAM_PIN`: `latest` pins each sent notification and rolls the pin
  over to the newest message (unpinning only the bot's own previous pin in the
  same topic); unset/`off` (default) disables pinning entirely.

Messages use Telegram HTML parse mode. The template escapes dynamic text and

#### .gitlab/ci/renovate.yml

Reusable GitLab CI template for self-hosted Renovate. Consumer repositories add
a platform-specific bot config such as `.gitlab/renovate-config.js`. The
template runs the serial orchestrator for scheduled pipelines and for manual
web/API pipelines when `DEPENDENCY_OWNER=gitlab`. One orchestrator performs at
most ten rounds. Each round runs Renovate once, creates at most one independent
MR, waits for the protected controller to merge it, verifies that the target
branch contains the merge commit, and only then starts the next round. A merge
push does not start a second Renovate job.

The shared policy sets `prConcurrentLimit=1`, `branchConcurrentLimit=1`, and
`prHourlyLimit=0`. Renovate's own direct automerge is disabled; trusted MR
pipelines are merged by `auto_merge_upstream_mr.sh` in the protected controller.
The controller retries transient merge responses (HTTP 405, 422, 429, and 5xx)
six times with 2, 4, 8, 16, and 32 second backoff. Authentication failures,
conflicts, stale heads, and other non-transient responses stop the round.

Common variables:

- `RENOVATE_TOKEN`: GitLab token for the Renovate bot.
- `RENOVATE_CONFIG_FILE`: bot/admin config file, default
  `.gitlab/renovate-config.js`. The template copies this file to Renovate's
  default `config.js` path before invoking Renovate.
- `DEPENDENCY_OWNER`: set to `gitlab` when manually running Renovate from a web
  or API pipeline.

### Codegen

#### badges.sh

Sourceable single-source helpers for reading TOML/Gradle versions, escaping
shields.io values, rendering flat-square badges, and replacing a named block in
a README without changing the target file's mode:

```bash
source .magisk-ci-toolkit/codegen/badges.sh
kotlin="$(read_toml_value kotlin gradle/libs.versions.toml)"
badge="$(tech_badge Kotlin "$kotlin" 7F52FF kotlin https://kotlinlang.org)"
replace_block README.md tech "$badge"
```

The target README must contain matching marker lines:

```markdown
<!-- badges:tech:start -->
<!-- badges:tech:end -->
```

#### sync_readme_badges.sh

Shared README badge driver for all consumer repos. Reads the tech badge
values from the consumer's `gradle/libs.versions.toml` +
`gradle/wrapper/gradle-wrapper.properties` and the platform row from the
consumer's `config/readme-badges.conf` (`PLATFORM` / `PROJECT_PATH` /
`DEFAULT_BRANCH` / `LICENSE_ID`), then rewrites the `platform` and `tech`
marker blocks in `README.md` / `README-EN.md`:

```bash
# manual sync
bash .magisk-ci-toolkit/codegen/sync_readme_badges.sh . --write
# read-only check (used by the release guard)
bash .magisk-ci-toolkit/codegen/sync_readme_badges.sh . --check
```

The platform flavour is `gitlab` (repo badge, pipeline status, latest
release, license); GitHub-hosted badges were retired when GitHub was reduced
to a downstream sync mirror.

Wired into:

- `release/check_release_guard.sh` → `check_readme_badges()` (also called by
  the `check_release_guard()` aggregate), so a release with stale badges fails.
- `.gitlab/ci/readme-badges.yml` → `sync:readme-badges` job (schedule / web)
  that syncs and pushes back with the CI job token.

## Local Validation

Run the repository's syntax, behavior, and whitespace checks before publishing
toolkit changes:

```bash
git ls-files -z '*.sh' | xargs -0 -n1 bash -n
ci/tests/test_cancel_older_mr_pipelines.sh
ci/tests/test_auto_merge_upstream_mr.sh
codegen/tests/test_badges.sh
python3 -m unittest discover -s security/tests -v
ruby -rpsych -e 'ARGV.each { |path| Psych.parse_file(path) }' $(git ls-files '*.yml' '*.yaml')
git diff --check
```

The GitLab examples use the current `main` branch. Consumer repositories that
require immutable CI behavior should replace `main` with a validated commit SHA.

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `MAGISK_DEFAULT_PROJECT` | Default Gradle project | `:app` |
| `MAGISK_ROOT_DEPTH` | Directory depth to project root | `2` |
| `MAGISK_PYTHON_SCRIPT` | Path to Python script | `scripts/security/manage_dependency_forces.py` |
| `MAGISK_HAS_FRONTEND` | Enable frontend (NPM/Cargo) support | `false` |
| `RELEASE_REMOTE` | Git remote name | `origin` |
| `RELEASE_SKIP_GUARD` | Skip release guard checks | `false` |
| `RELEASE_TAG_SKIP_DETEKT` | Skip detekt checks | `false` |

## Repository-Specific Configuration

### XposedSmsCode

```bash
export MAGISK_DEFAULT_PROJECT=":app"
export MAGISK_ROOT_DEPTH=2
export MAGISK_HAS_FRONTEND=false
```

### xinyi-relay

```bash
export MAGISK_DEFAULT_PROJECT=":app"
export MAGISK_ROOT_DEPTH=2
export MAGISK_HAS_FRONTEND=true
```

### MiPushFramework

```bash
export MAGISK_DEFAULT_PROJECT=":mipush"
export MAGISK_ROOT_DEPTH=1
export MAGISK_HAS_FRONTEND=false
```

## Observability (GitLab OTEL)

- Schema: [`docs/otel-schema.md`](docs/otel-schema.md)
- CI helper: [`ci/otel_export.sh`](ci/otel_export.sh)
- Android jobs export `ci.job` in `after_script` (disable with `MAGISK_OTEL_EXPORT=0`)
- Group backend: `https://136325658.otel.gitlab-o11y.com:14318`


### GitLab → NapGram/QQ notifications

The `/.gitlab/ci/gitlab-qq.yml` template provides reusable GitLab jobs for authenticated NapGram delivery:

```yaml
include:
  - project: magisk3171/magisk-ci-toolkit
    ref: "<full-40-character-commit-sha>"
    file: /.gitlab/ci/gitlab-qq.yml

variables:
  MAGISK_GITLAB_QQ_ENABLED: "true"
  MAGISK_GITLAB_QQ_TARGET: "xposed-sms-code"
  MAGISK_GITLAB_QQ_CI_BRANCH: "beta"
  MAGISK_GITLAB_QQ_ARTIFACT_PATTERNS: "*arm64-v8a*.apk"
  NAPGRAM_GITLAB_NOTIFIER_URL: "https://napgram.example/api/gitlab-notifier/publish"

qq:ci:
  extends: .magisk_gitlab_qq_ci
  needs:
    - job: android:build
      artifacts: true

qq:release:
  extends: .magisk_gitlab_qq_release
  needs:
    - job: android:release:gitlab
      artifacts: false
    - job: android:release:github-apk
      artifacts: true
```

`NAPGRAM_GITLAB_NOTIFIER_HMAC_SECRET` must be a masked/protected GitLab variable. The template derives project, commit, pipeline, merge-request and release links from GitLab predefined variables, computes artifact SHA-256 values, and uploads multipart data to `napgram-plugin-gitlab-notifier`. The notification jobs are `allow_failure: true` by design.
