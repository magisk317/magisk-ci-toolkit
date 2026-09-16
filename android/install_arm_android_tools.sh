#!/usr/bin/env bash
set -euo pipefail

sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$sdk_root" || ! -d "$sdk_root/build-tools" ]]; then
  echo "ERROR: Android SDK build-tools directory is unavailable: ${sdk_root:-<unset>}" >&2
  exit 1
fi

for tool in aidl aapt2; do
  source_tool="/usr/local/bin/$tool"
  if [[ ! -x "$source_tool" ]]; then
    echo "ERROR: ARM Android tool is unavailable: $source_tool" >&2
    exit 1
  fi

  found=0
  for build_tools_dir in "$sdk_root"/build-tools/*; do
    [[ -d "$build_tools_dir" ]] || continue
    install -m 0755 "$source_tool" "$build_tools_dir/$tool"
    found=1
    echo "Using ARM $tool: $build_tools_dir/$tool"
  done
  if [[ "$found" -eq 0 ]]; then
    echo "ERROR: no Android build-tools installation exists under $sdk_root" >&2
    exit 1
  fi
done

# AGP resolves AAPT2 from its Maven artifact and extracts it into Gradle's
# transform cache. On ARM that artifact is an x86 binary, so replacing only
# the SDK build-tools copy is insufficient. Keep the override in the caller's
# environment for every Gradle invocation in this job.
arm_aapt2="$(find "$sdk_root/build-tools" -type f -name aapt2 -perm -u+x -print | sort -V | tail -n 1)"
if [[ -z "$arm_aapt2" ]]; then
  echo "ERROR: no ARM aapt2 was installed under $sdk_root" >&2
  exit 1
fi
# Keep the path in a named environment variable for scripts that need it.
export MAGISK_ANDROID_AAPT2_OVERRIDE="$arm_aapt2"

# Gradle maps org.gradle.project.* system properties to project properties.
# GRADLE_OPTS is inherited by Gradle TestKit and any future nested Gradle
# process, unlike a -P argument passed only to the outer wrapper.
gradle_aapt2_property="-Dorg.gradle.project.android.aapt2FromMavenOverride=$arm_aapt2"
if [[ " ${GRADLE_OPTS:-} " != *" $gradle_aapt2_property "* ]]; then
  export GRADLE_OPTS="${GRADLE_OPTS:-}${GRADLE_OPTS:+ }$gradle_aapt2_property"
fi

echo "Using ARM AAPT2 override: $arm_aapt2"
