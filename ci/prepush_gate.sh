#!/usr/bin/env bash
# Pre-push local gate for magisk-ci-toolkit: run the CI jobs this change can
# actually affect, on this machine, BEFORE pushing. Rationale: pushing first
# and reading the pipeline is a slow feedback loop, and a red pipeline on an
# unrelated transient (a proxy 502 during a docker apt layer, 2026-11-23) is
# noise nobody can act on.
#
# What runs:
#   1. shell:test equivalent -- ALWAYS. The deterministic quality gate
#      (bash syntax check over the same globs, shellcheck over the SAME file
#      list as .gitlab-ci.yml -- extracted at runtime, never hand-copied --
#      and every ci/tests/test_*.sh). Executed inside the utility image so
#      the tool versions match CI.
#   2. docker image builds -- only when the diff touches docker/ or the
#      image inputs, or when --with-docker is passed. The builds are slow
#      and network-dependent; unrelated changes must not pay for them.
#      Replicates .docker:build:base (same targets, build args, smoke tests).
#
# Requires on the host: docker, python3 with PyYAML (the file list is parsed
# from .gitlab-ci.yml at runtime). Run it on debian, where the utility image
# already lives.
#
# Usage:
#   bash ci/prepush_gate.sh                 # from the toolkit repo root
#   bash ci/prepush_gate.sh --with-docker   # force the image builds too
#   bash ci/prepush_gate.sh --base origin/main
set -uo pipefail

REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO" || exit 1

BASE="origin/main"
WITH_DOCKER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --with-docker) WITH_DOCKER=1; shift ;;
    --base) BASE="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

IMAGE="registry.gitlab.com/magisk3171/shared/magisk-ci-toolkit/utility:3.24.2"
LOG_DIR="$REPO/.build-logs"
mkdir -p "$LOG_DIR"

echo "== prepush gate: base=$BASE with-docker=$WITH_DOCKER"

# ---- extract the CI job's exact step inputs from the yml (never hand-copy) --
# Two lists come from .gitlab-ci.yml at runtime: the shellcheck file list and
# the test-script list. Hand-copying either is how a fabricated filename and a
# superset test run both slipped in (2026-11-23); the yml is the only source.
FILES_LIST="$LOG_DIR/prepush-shellcheck-files.txt"
TESTS_LIST="$LOG_DIR/prepush-test-files.txt"
python3 - "$FILES_LIST" "$TESTS_LIST" <<'PY' || exit 1
import os
import sys
import yaml

with open(".gitlab-ci.yml", encoding="utf-8") as f:
    data = yaml.safe_load(f)
script = data["shell:test"]["script"]

shellcheck_files = []
test_files = []
for step in script:
    if step.startswith("shellcheck -x"):
        shellcheck_files = step.split()[2:]
    elif step.startswith("bash ci/tests/"):
        test_files.append(step.split()[1])

problems = []
if not shellcheck_files:
    problems.append("shellcheck step not found")
if not test_files:
    problems.append("test steps not found")
for path in shellcheck_files + test_files:
    if not os.path.exists(path):
        problems.append("missing file: %s" % path)
if problems:
    for problem in problems:
        print(problem, file=sys.stderr)
    sys.exit(1)

with open(sys.argv[1], "w", encoding="utf-8") as out:
    out.write("\n".join(shellcheck_files) + "\n")
with open(sys.argv[2], "w", encoding="utf-8") as out:
    out.write("\n".join(test_files) + "\n")
print("shellcheck list: %d files; test list: %d scripts (both from .gitlab-ci.yml)"
      % (len(shellcheck_files), len(test_files)))
PY

# ---- 1. shell:test equivalent, inside the CI utility image -----------------
echo "== [1/2] shell:test equivalent (utility image)"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "  utility image missing locally; pulling"
  docker pull "$IMAGE" | tee "$LOG_DIR/prepush-utility-pull.log" || {
    echo "  cannot prepare the utility image; refusing to guess" >&2
    exit 1
  }
fi
docker run --rm -v "$REPO:/work" -w /work "$IMAGE" bash -c '
  set -e
  bash ci/check_shell_syntax.sh ci/*.sh ci/git_hooks/*.sh ci/tests/*.sh codegen/*.sh codegen/tests/*.sh gradle/*.sh gradle/tests/*.sh release/*.sh release/tests/*.sh
  echo "== shellcheck (list from .gitlab-ci.yml)"
  tr "\n" "\0" < .build-logs/prepush-shellcheck-files.txt | xargs -0 shellcheck -x
  echo "== tests (list from .gitlab-ci.yml -- exactly what CI runs)"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    echo "== RUN $t"
    bash "$t"
  done < .build-logs/prepush-test-files.txt
  echo "== shell:test equivalent: PASS"
' | tee "$LOG_DIR/prepush-shell-test.log"
rc=${PIPESTATUS[0]}
if [ "$rc" != "0" ]; then
  echo "FAIL: shell:test equivalent failed (rc=$rc); see $LOG_DIR/prepush-shell-test.log" >&2
  exit 1
fi

# ---- 2. docker builds, only when the diff can affect the images ------------
NEED_DOCKER=$WITH_DOCKER
if [ "$NEED_DOCKER" = "0" ]; then
  if git diff --name-only "$BASE"...HEAD 2>/dev/null | grep -qE '^(docker/|\.gitlab/ci/docker\.yml)'; then
    NEED_DOCKER=1
    echo "  diff touches docker/ -- image builds are required"
  fi
fi

if [ "$NEED_DOCKER" = "1" ]; then
  echo "== [2/2] docker image builds (local, same command as .docker:build:base)"
  # Replicates .gitlab/ci/docker.yml: multi-target build + smoke test per target.
  ARCH="${MAGISK_CI_DOCKER_ARCH:-amd64}"
  set -a
  # shellcheck disable=SC1091
  . "$REPO/docker/ci/versions.env"
  set +a
  BUILD_ARGS="--build-arg ALPINE_VERSION=${MAGISK_CI_ALPINE_VERSION} \
    --build-arg GH_VERSION=${MAGISK_CI_GH_VERSION} \
    --build-arg TEMURIN_TAG=${MAGISK_CI_TEMURIN_TAG} \
    --build-arg RUST_TAG=${MAGISK_CI_RUST_TAG} \
    --build-arg BUN_TAG=${MAGISK_CI_BUN_TAG}"
  # The CI runner injects the fleet proxy into builds; local runs must do the
  # same or apt/apk inside the build has no route out. A host-loopback proxy
  # (127.0.0.1/localhost) is NOT reachable from inside the build container --
  # rewrite it to the docker bridge gateway. MAGISK_BUILD_PROXY overrides the
  # whole set (used to reproduce the runner's exact proxy).
  if [ -n "${MAGISK_BUILD_PROXY:-}" ]; then
    BUILD_ARGS="$BUILD_ARGS --build-arg http_proxy=$MAGISK_BUILD_PROXY --build-arg https_proxy=$MAGISK_BUILD_PROXY --build-arg no_proxy=${no_proxy:-}"
  else
    BRIDGE_GW="$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || echo 172.17.0.1)"
    for var in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
      eval "val=\${$var:-}"
      if [ -n "$val" ]; then
        val="$(printf '%s' "$val" | sed -E "s#(127\.0\.0\.1|localhost)#$BRIDGE_GW#g")"
        BUILD_ARGS="$BUILD_ARGS --build-arg $var=$val"
      fi
    done
  fi
  failed=0
  for target in ${MAGISK_CI_TARGETS:-utility android-jdk zygisk-rust webui-bun plugin-bun}; do
    echo "== building ${target} (linux/${ARCH})"
    # shellcheck disable=SC2086
    docker build --platform "linux/${ARCH}" --target "$target" $BUILD_ARGS \
      --file docker/ci/Dockerfile --tag "magisk-ci-tmp:${target}" . 2>&1 \
      | tee "$LOG_DIR/prepush-docker-${target}.log" || { failed=1; break; }
    case "$target" in
      utility)
        docker run --rm --entrypoint sh "magisk-ci-tmp:${target}" \
          -c 'gh --version && shellcheck --version | head -n1' || { failed=1; break; } ;;
      android-jdk)
        docker run --rm --entrypoint sh "magisk-ci-tmp:${target}" \
          -c 'java --version && fakeroot --version' || { failed=1; break; } ;;
      zygisk-rust)
        docker run --rm --entrypoint sh "magisk-ci-tmp:${target}" \
          -c 'rustc --version && cargo --version && rustup target list --installed | grep -q aarch64-linux-android' || { failed=1; break; } ;;
      webui-bun)
        docker run --rm --entrypoint sh "magisk-ci-tmp:${target}" \
          -c 'bun --version && git --version' || { failed=1; break; } ;;
    esac
  done
  if [ "$failed" != "0" ]; then
    echo "FAIL: local docker build/smoke failed; see $LOG_DIR/prepush-docker-*.log" >&2
    exit 1
  fi
  echo "  docker builds + smoke tests: PASS"
else
  echo "== [2/2] docker builds: skipped (diff does not touch docker/)"
fi

echo "== prepush gate: ALL GREEN -- safe to push"
