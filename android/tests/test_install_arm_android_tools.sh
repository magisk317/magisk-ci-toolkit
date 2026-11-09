#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
installer="$root_dir/android/install_arm_android_tools.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sdk_root="$tmp/android-sdk"
mkdir -p "$sdk_root/build-tools/36.0.0" "$sdk_root/build-tools/37.0.0"
tool_prefix="$tmp/bin"
mkdir -p "$tool_prefix"

for tool in aidl aapt2; do
  printf "#!/bin/sh\necho \"%s\"\n" "$tool" > "$tool_prefix/$tool"
  chmod +x "$tool_prefix/$tool"
done

export ANDROID_HOME="$sdk_root"
export MAGISK_ARM_TOOL_PREFIX="$tool_prefix"

# First install: must copy to both build-tools directories
output="$(bash "$installer")"
[[ -x "$sdk_root/build-tools/36.0.0/aidl" ]] || { echo "aidl missing in 36.0.0" >&2; exit 1; }
[[ -x "$sdk_root/build-tools/37.0.0/aapt2" ]] || { echo "aapt2 missing in 37.0.0" >&2; exit 1; }

# Second install: must detect existing copies via cmp and not reinstall
second_output="$(bash "$installer")"
if ! echo "$second_output" | grep -q "(already installed)"; then
  echo "Expected idempotence logging not found: $second_output" >&2
  exit 1
fi

echo "install_arm_android_tools tests passed"
