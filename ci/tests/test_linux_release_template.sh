#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
template="$root_dir/.gitlab/ci/android-release.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

extract_template() {
  local name="$1"
  sed -n "/^${name//./\\.}:/,/^\\.[[:alnum:]_]*:/p" "$template" | sed '$d'
}

linux_base="$(extract_template '.magisk_linux_base')"
[[ "$linux_base" == *'image: "debian:trixie-slim"'* ]] || fail "lightweight image is missing"
[[ "$linux_base" == *'apt_packages=(bash ca-certificates curl git openssl python3)'* ]] || fail "base tools are incomplete"
[[ "$linux_base" == *'scripts/resolve_ci_toolkit.sh'* ]] || fail "toolkit checkout is missing"

apk_release="$(extract_template '.magisk_android_release_apk')"
[[ "$apk_release" == *'validate_android_apk_signatures.sh'* ]] || fail "APK signer validation is missing"

for name in \
  '.magisk_android_release_guard' \
  '.magisk_android_gitlab_release' \
  '.magisk_android_publish_play' \
  '.magisk_android_publish_modules_repo'; do
  block="$(extract_template "$name")"
  [[ "$block" == *'- .magisk_linux_base'* ]] || fail "$name must use the Linux base"
  [[ "$block" != *'- .magisk_android_base'* ]] || fail "$name must not initialize Android SDK"
done

echo "Linux release template contract passed"
