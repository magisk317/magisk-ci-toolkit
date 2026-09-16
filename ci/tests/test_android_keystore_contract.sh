#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Verify android.yml template contains mkdir -p before writing keystore
android_yml="$root_dir/.gitlab/ci/android.yml"
grep -q 'mkdir -p "$(dirname "$keystore_path")"' "$android_yml" || fail "android.yml is missing mkdir -p for keystore_path"

# Verify android-release.yml template contains mkdir -p before writing keystore
android_release_yml="$root_dir/.gitlab/ci/android-release.yml"
mkdir_count=$(grep -c 'mkdir -p "$(dirname "$keystore_path")"' "$android_release_yml" || true)
if [ "$mkdir_count" -lt 2 ]; then
  fail "android-release.yml must have mkdir -p for keystore_path in both apk and aab release jobs (found $mkdir_count)"
fi

# Simulate keystore creation in a project root lacking app/ directory
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

CI_PROJECT_DIR="$tmp_dir"
RELEASE_KEYSTORE="$(printf 'fake-keystore-content' | base64)"
STORE_PASSWORD="password"
KEY_ALIAS="alias"
KEY_PASSWORD="password"

# Execute logic as written in android.yml
if [ -n "${RELEASE_KEYSTORE:-}" ] && [ -n "${STORE_PASSWORD:-}" ] && [ -n "${KEY_ALIAS:-}" ] && [ -n "${KEY_PASSWORD:-}" ]; then
  keystore_path="$CI_PROJECT_DIR/app/release.jks"
  mkdir -p "$(dirname "$keystore_path")"
  printf '%s' "$RELEASE_KEYSTORE" | base64 --decode > "$keystore_path"
  chmod 0600 "$keystore_path"
fi

[ -f "$tmp_dir/app/release.jks" ] || fail "keystore file was not created successfully"
content="$(cat "$tmp_dir/app/release.jks")"
[ "$content" = "fake-keystore-content" ] || fail "keystore content mismatch: $content"

echo "Keystore path contract tests passed"
