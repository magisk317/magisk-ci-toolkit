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

# AGP validates that every build-tools revision contains the binaries it may
# invoke (aapt, dexdump, d8, ...) and fails with "Installed Build Tools
# revision X is corrupted" when any is missing. On ARM only aidl and aapt2 are
# actually executed; the rest are checked for existence only, so a partially
# installed or pruned revision breaks the whole build for no good reason.
# Backfill missing entries from the most complete sibling revision; version
# metadata is never copied.
reference=""
best=-1
for candidate in "$sdk_root"/build-tools/*; do
  [[ -d "$candidate" ]] || continue
  count="$(find "$candidate" -mindepth 1 -maxdepth 1 | wc -l)"
  if [[ -z "$reference" || "$count" -gt "$best" ]]; then
    reference="$candidate"
    best="$count"
  fi
done
if [[ -n "$reference" ]]; then
  echo "Build-tools reference revision: $reference"
  for build_tools_dir in "$sdk_root"/build-tools/*; do
    [[ -d "$build_tools_dir" ]] || continue
    if [[ "$build_tools_dir" == "$reference" ]]; then
      continue
    fi
    for entry in "$reference"/*; do
      name="$(basename "$entry")"
      case "$name" in
        source.properties | package.xml | runtime.properties) continue ;;
      esac
      if [[ ! -e "$build_tools_dir/$name" ]]; then
        if [[ -d "$entry" ]]; then
          cp -r "$entry" "$build_tools_dir/$name"
        else
          install -m 0755 "$entry" "$build_tools_dir/$name"
        fi
        echo "Backfilled $name for AGP validation: $build_tools_dir/$name"
      fi
    done
  done
else
  echo "WARNING: no build-tools revision found under $sdk_root" >&2
fi

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
