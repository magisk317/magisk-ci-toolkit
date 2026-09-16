#!/usr/bin/env bash

magisk_ensure_skopeo() {
  if command -v skopeo >/dev/null 2>&1; then
    return 0
  fi

  sudo apt-get update
  sudo apt-get install -y skopeo
}

magisk_mirror_container_images() {
  local source_registry=$1
  local source_username=$2
  local source_password=$3
  local source_image=$4
  local target_registry=$5
  local target_username=$6
  local target_password=$7
  local target_image=$8
  shift 8

  local authfile
  authfile="$(mktemp)"
  printf '{}\n' >"$authfile"

  if ! printf '%s' "$source_password" \
    | skopeo login --authfile "$authfile" --username "$source_username" --password-stdin "$source_registry"; then
    rm -f "$authfile"
    return 1
  fi
  if ! printf '%s' "$target_password" \
    | skopeo login --authfile "$authfile" --username "$target_username" --password-stdin "$target_registry"; then
    rm -f "$authfile"
    return 1
  fi

  local tag
  for tag in "$@"; do
    [[ -n "$tag" ]] || continue
    if ! skopeo copy --all --retry-times 3 --authfile "$authfile" \
      "docker://${source_image}:${tag}" \
      "docker://${target_image}:${tag}"; then
      rm -f "$authfile"
      return 1
    fi
  done

  rm -f "$authfile"
}

magisk_list_container_images() {
  local primary_image=$1
  local optional_image=$2
  local optional_published=$3
  shift 3

  local tag
  for tag in "$@"; do
    [[ -n "$tag" ]] || continue
    printf '%s:%s\n' "$primary_image" "$tag"
    if [[ "$optional_published" == "true" || "$optional_published" == "1" ]]; then
      printf '%s:%s\n' "$optional_image" "$tag"
    fi
  done
}

magisk_container_mirror_main() {
  local mode=${1:-}
  case "$mode" in
    mirror)
      mapfile -t tags < <(printf '%s\n' "${MAGISK_CONTAINER_TAGS:-}" | sed '/^$/d')
      magisk_ensure_skopeo
      magisk_mirror_container_images \
        "${MAGISK_SOURCE_REGISTRY:?}" \
        "${MAGISK_SOURCE_USERNAME:?}" \
        "${MAGISK_SOURCE_PASSWORD:?}" \
        "${MAGISK_SOURCE_IMAGE:?}" \
        "${MAGISK_TARGET_REGISTRY:?}" \
        "${MAGISK_TARGET_USERNAME:?}" \
        "${MAGISK_TARGET_PASSWORD:?}" \
        "${MAGISK_TARGET_IMAGE:?}" \
        "${tags[@]}"
      ;;
    list)
      mapfile -t tags < <(printf '%s\n' "${MAGISK_CONTAINER_TAGS:-}" | sed '/^$/d')
      magisk_list_container_images \
        "${MAGISK_PRIMARY_IMAGE:?}" \
        "${MAGISK_OPTIONAL_IMAGE:-}" \
        "${MAGISK_OPTIONAL_PUBLISHED:-false}" \
        "${tags[@]}"
      ;;
    *)
      echo "usage: $0 <mirror|list>" >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  magisk_container_mirror_main "$@"
fi
