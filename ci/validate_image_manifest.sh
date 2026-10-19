#!/usr/bin/env bash
set -euo pipefail

image=""
architectures="amd64 arm64"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) image="$2"; shift 2 ;;
    --architectures) architectures="$2"; shift 2 ;;
    -h|--help) echo "usage: $0 --image IMAGE [--architectures 'amd64 arm64']"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$image" ]] || { echo "--image is required" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }

raw="$(docker buildx imagetools inspect "$image" --raw)"
available="$(printf '%s\n' "$raw" | jq -r '.manifests[]?.platform.architecture // .architecture // empty' | sort -u)"
for arch in $architectures; do
  grep -Fx "$arch" <<<"$available" >/dev/null || {
    echo "image $image does not publish architecture $arch" >&2
    printf 'available architectures:\n%s\n' "$available" >&2
    exit 1
  }
done
printf 'Image manifest verified: %s (%s)\n' "$image" "$architectures"
