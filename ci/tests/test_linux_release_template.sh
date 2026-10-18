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
[[ "$linux_base" == *'utility:3.24.1'* ]] || fail "lightweight utility image is missing"
[[ "$linux_base" == *'scripts/resolve_ci_toolkit.sh'* ]] || fail "toolkit checkout is missing"

# The release templates run on Alpine (utility:3.24.1): Debian-only tooling
# must never come back. gh/python3/openssl are pre-baked into the image.
[[ "$(grep -c 'apt-get' "$template")" -eq 0 ]] || fail "release template must not shell out to apt-get"

apk_release="$(extract_template '.magisk_android_release_apk')"
[[ "$apk_release" == *'validate_android_apk_signatures.sh'* ]] || fail "APK signer validation is missing"

play_publish="$(extract_template '.magisk_android_publish_play')"
[[ "$play_publish" == *'allow_failure: true'* ]] || fail ".magisk_android_publish_play must stay best-effort (allow_failure: true)"
[[ "$play_publish" == *'publish_play.py'* ]] || fail "play publishing must call the native publish_play.py"
[[ "$play_publish" != *'fastlane supply'* ]] || fail "play publishing must not use the fastlane supply binary"
[[ "$play_publish" != *'gem install'* ]] || fail "play publishing must not install ruby gems at runtime"

for name in \
  '.magisk_android_release_github' \
  '.magisk_android_publish_modules_repo'; do
  block="$(extract_template "$name")"
  [[ "$block" == *'MAGISK_ANDROID_RELEASE_APK_ROOTS'* ]] || fail "$name must honor MAGISK_ANDROID_RELEASE_APK_ROOTS"
  [[ "$block" != *'find app/build/outputs/apk'* ]] || fail "$name must not hardcode app/build/outputs/apk"
done

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
