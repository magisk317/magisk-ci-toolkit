#!/usr/bin/env bash
# bash -n parses one script; the remaining arguments become that script's arguments.
set -euo pipefail

if (($# == 0)); then
  printf 'Usage: %s SCRIPT [SCRIPT ...]\n' "$0" >&2
  exit 2
fi

status=0
for script in "$@"; do
  if ! bash -n -- "$script"; then
    status=1
  fi
done
exit "$status"
