#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root_dir/ci/container_mirror.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
call_log="$tmp_dir/calls"

skopeo() {
  printf '%s\n' "$*" >>"$call_log"
  [[ "${SKOPEO_RESULT:-success}" == "success" ]]
}

magisk_mirror_container_images \
  ghcr.io source-user source-token ghcr.io/example/project \
  docker.io target-user target-token docker.io/example/project \
  latest v1.2.3

grep -Fq 'login --authfile' "$call_log"
grep -Fq 'docker://ghcr.io/example/project:latest docker://docker.io/example/project:latest' "$call_log"
grep -Fq 'docker://ghcr.io/example/project:v1.2.3 docker://docker.io/example/project:v1.2.3' "$call_log"

SKOPEO_RESULT=failure
if magisk_mirror_container_images \
  ghcr.io source-user source-token ghcr.io/example/project \
  docker.io target-user target-token docker.io/example/project latest; then
  echo 'mirror helper accepted a skopeo failure' >&2
  exit 1
fi

mapfile -t primary_only < <(magisk_list_container_images primary/image optional/image false latest v1)
[[ "${primary_only[*]}" == 'primary/image:latest primary/image:v1' ]]

mapfile -t mirrored < <(magisk_list_container_images primary/image optional/image true latest v1)
[[ "${mirrored[*]}" == 'primary/image:latest optional/image:latest primary/image:v1 optional/image:v1' ]]

echo 'Container mirror contract tests passed'
