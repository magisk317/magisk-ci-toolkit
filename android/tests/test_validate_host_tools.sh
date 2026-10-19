#!/usr/bin/env bash
set -euo pipefail
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$root_dir/android/validate_host_tools.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/build-tools/1.0"
for name in aapt2 aidl aapt zipalign dexdump; do
  printf '#!/bin/sh\nexit 0\n' > "$tmp/build-tools/1.0/$name"
  chmod +x "$tmp/build-tools/1.0/$name"
done

# Current host is x86_64: non-ELF runtime tools must fail.
if bash "$checker" --sdk-root "$tmp" --build-tools 1.0 >/dev/null 2>&1; then
  echo 'x86 non-ELF fixture unexpectedly passed' >&2
  exit 1
fi

# The real runner SDK (when present) must pass the strict x86 branch.
if [[ -x /opt/android-sdk/build-tools/37.0.0/aapt2 ]]; then
  bash "$checker" --sdk-root /opt/android-sdk --build-tools 37.0.0 >/dev/null
fi

echo 'host tool checker contract tests passed'
