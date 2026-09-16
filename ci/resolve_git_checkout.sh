#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <repository> <ref> <destination>" >&2
}

resolve_git_checkout() {
  if [[ "$#" -ne 3 ]]; then
    usage
    return 2
  fi

  local repository="$1"
  local ref="$2"
  local destination="$3"

  if [[ -z "$repository" || -z "$ref" || -z "$destination" ]]; then
    echo "repository, ref, and destination must be non-empty" >&2
    return 2
  fi
  case "$destination" in
    / | . | ..)
      echo "refusing unsafe checkout destination: $destination" >&2
      return 2
      ;;
  esac

  if [[ ! -d "$destination/.git" ]]; then
    rm -rf -- "$destination"
    git init --quiet "$destination" >&2
    git -C "$destination" remote add origin "$repository" >&2
  elif git -C "$destination" remote get-url origin >/dev/null 2>&1; then
    git -C "$destination" remote set-url origin "$repository" >&2
  else
    git -C "$destination" remote add origin "$repository" >&2
  fi

  # Fetch the requested object directly. Unlike `git clone --branch`, this accepts
  # branch names, tags, and full commit SHAs without interpreting a SHA as a branch.
  git -C "$destination" fetch --depth 1 origin "$ref" >&2
  git -C "$destination" checkout --detach --force FETCH_HEAD >&2

  if [[ "$ref" =~ ^[0-9a-fA-F]{40}$ ]]; then
    local resolved_ref normalized_ref
    resolved_ref="$(git -C "$destination" rev-parse HEAD)"
    normalized_ref="$(printf '%s' "$ref" | tr '[:upper:]' '[:lower:]')"
    if [[ "$resolved_ref" != "$normalized_ref" ]]; then
      echo "resolved commit $resolved_ref does not match pinned ref $ref" >&2
      return 1
    fi
  fi

  printf '%s\n' "$destination"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  resolve_git_checkout "$@"
fi
