#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root_dir/ci/optional_registry.sh"

docker() {
  [[ "${DOCKER_LOGIN_RESULT:-success}" == "success" ]]
}

publish_stub() {
  [[ "${PUBLISH_RESULT:-success}" == "success" ]]
}

assert_status() {
  local expected=$1
  local message=$2
  if [[ "$MAGISK_OPTIONAL_REGISTRY_PUBLISH_OK" != "$expected" ]]; then
    echo "FAIL: $message (expected=$expected actual=$MAGISK_OPTIONAL_REGISTRY_PUBLISH_OK)" >&2
    exit 1
  fi
}

magisk_publish_optional_registry false DockerHub docker.io user token publish_stub
assert_status 0 "disabled mirror must be skipped"

magisk_publish_optional_registry true DockerHub docker.io '' '' publish_stub
assert_status 0 "missing credentials must be skipped"

DOCKER_LOGIN_RESULT=failure
magisk_publish_optional_registry true DockerHub docker.io user token publish_stub
assert_status 0 "login failure must remain non-blocking"

DOCKER_LOGIN_RESULT=success
PUBLISH_RESULT=failure
magisk_publish_optional_registry true DockerHub docker.io user token publish_stub
assert_status 0 "publish failure must remain non-blocking"

PUBLISH_RESULT=success
magisk_publish_optional_registry true DockerHub docker.io user token publish_stub
assert_status 1 "successful mirror must be reported"

echo "Optional registry contract tests passed"
