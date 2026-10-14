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
[[ "$linux_base" == *'utility:3.24'* ]] || fail "lightweight utility image is missing"
[[ "$linux_base" == *'scripts/resolve_ci_toolkit.sh'* ]] || fail "toolkit checkout is missing"

apk_release="$(extract_template '.magisk_android_release_apk')"
[[ "$apk_release" == *'validate_android_apk_signatures.sh'* ]] || fail "APK signer validation is missing"

play_publish="$(extract_template '.magisk_android_publish_play')"
[[ "$play_publish" == *'allow_failure: true'* ]] || fail ".magisk_android_publish_play must stay best-effort (allow_failure: true)"

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
