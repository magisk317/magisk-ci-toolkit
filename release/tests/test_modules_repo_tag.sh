#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE="$ROOT_DIR/.gitlab/ci/android-release.yml"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Pull the real tag derivation out of the modules-repo job and exercise it,
# rather than re-testing a copy that can drift from the template.
awk '
  /^      # Xposed-Modules-Repo tags every release/ { capture = 1 }
  capture && /^      echo "Xposed-Modules-Repo release tag:/ { print; exit }
  capture { sub(/^      /, ""); print }
' "$TEMPLATE" > "$TMP_DIR/tag_block.sh"

[[ -s "$TMP_DIR/tag_block.sh" ]] || fail "could not extract the tag derivation from the template"
bash -n "$TMP_DIR/tag_block.sh" || fail "the extracted tag derivation is not valid shell"

# The git based fallback counts commits, so it needs a repository to run in.
git -C "$TMP_DIR" init -q
for message in one two; do
  # Throwaway fixture commits: never sign them, whatever the global config says.
  git -C "$TMP_DIR" -c user.email=t@example -c user.name=t -c commit.gpgsign=false \
    commit -q --allow-empty -m "$message"
done

resolve() {
  (
    cd "$TMP_DIR"
    # shellcheck disable=SC2016 # the snippet must expand inside the inner shell.
    env CI_COMMIT_TAG=v1.0.3 "$@" bash -c \
      '. ./tag_block.sh >/dev/null 2>&1; printf "%s" "${modules_release_tag:-}"'
  )
}

assert_tag() {
  local expected=$1 actual=$2 message=$3
  [[ "$actual" == "$expected" ]] || fail "$message (expected '$expected', got '$actual')"
}

printf 'MAGISK_PLAY_VERSION_CODE=1605\nMAGISK_PLAY_VERSION_NAME=1.0.3\n' > "$TMP_DIR/play-release.env"
assert_tag "1605-1.0.3" "$(resolve)" \
  "play-release.env must supply the versionCode and versionName"

rm -f "$TMP_DIR/play-release.env"
assert_tag "1454-0.6.1" "$(resolve MAGISK_ANDROID_RELEASE_MODULES_REPO_TAG=1454-0.6.1)" \
  "an explicit modules repo tag must win over every derivation"

assert_tag "3-1.0.3" "$(resolve)" \
  "without play-release.env the versionCode falls back to the commit count"

assert_tag "1570-1.0.3" "$(resolve MAGISK_PLAY_INITIAL_VERSION_CODE=1569)" \
  "MAGISK_PLAY_INITIAL_VERSION_CODE must floor the derived versionCode"

assert_tag "999-1.0.3" "$(resolve MAGISK_ANDROID_RELEASE_MODULES_REPO_VERSION_CODE=999)" \
  "an explicit versionCode override must be honored"

echo "modules-repo tag contract tests passed"
