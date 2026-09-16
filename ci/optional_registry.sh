#!/usr/bin/env bash

# Runs a secondary registry publisher without weakening the primary registry.
# The publish command is invoked only after an optional registry login succeeds.
magisk_publish_optional_registry() {
  local enabled=$1
  local label=$2
  local registry=$3
  local username=$4
  local password=$5
  shift 5

  # shellcheck disable=SC2034 # Read by the caller after this sourced helper returns.
  MAGISK_OPTIONAL_REGISTRY_PUBLISH_OK=0

  if [[ "$enabled" != "true" ]]; then
    echo "INFO: ${label} mirror disabled; skipping" >&2
    return 0
  fi
  if [[ -z "$username" || -z "$password" ]]; then
    echo "INFO: ${label} credentials not configured; skipping optional mirror" >&2
    return 0
  fi
  if ! printf '%s' "$password" | docker login "$registry" --username "$username" --password-stdin; then
    echo "WARN: optional ${label} login failed; primary registry publish remains valid" >&2
    return 0
  fi
  if ! "$@"; then
    echo "WARN: optional ${label} publish failed; primary registry publish remains valid" >&2
    return 0
  fi

  # shellcheck disable=SC2034 # Read by the caller after this sourced helper returns.
  MAGISK_OPTIONAL_REGISTRY_PUBLISH_OK=1
  echo "Published optional ${label} mirror" >&2
}
