#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file=$1 expected=$2 message=$3
  grep -Fq "$expected" "$file" || fail "$message"
}

assert_not_contains() {
  local file=$1 unexpected=$2 message=$3
  if grep -Fq "$unexpected" "$file"; then
    fail "$message"
  fi
}

cat > "$TMP_DIR/CHANGELOG.md" <<'CHANGELOG'
# Changelog

---

## [v1.2.3] - 2026-08-31
- Release notes.

> Full Changelog: https://gitlab.example/group/project/-/compare/v1.2.2...v1.2.3

---
CHANGELOG

bash "$ROOT_DIR/release/release_notes.sh" \
  --tag v1.2.3 \
  --package-name com.example.demo \
  --source-repo example/demo \
  --play-url https://play.example/apps/demo \
  --gitlab-project-url https://gitlab.example/group/project/ \
  --changelog "$TMP_DIR/CHANGELOG.md" \
  --output "$TMP_DIR/gitlab-notes.md"

assert_contains "$TMP_DIR/gitlab-notes.md" \
  'https://play.example/apps/demo' \
  "GitLab notes should include the configured Play link"
assert_contains "$TMP_DIR/gitlab-notes.md" \
  'href="https://gitlab.example/group/project/-/releases/v1.2.3"' \
  "GitLab notes should link to the current GitLab release"
assert_contains "$TMP_DIR/gitlab-notes.md" \
  'alt="Get it on GitLab"' \
  "GitLab notes should render a GitLab badge"
assert_not_contains "$TMP_DIR/gitlab-notes.md" \
  'alt="Get it on GitHub"' \
  "GitLab notes must not render the GitHub badge"

bash "$ROOT_DIR/release/release_notes.sh" \
  --tag v1.2.3 \
  --package-name com.example.demo \
  --source-repo example/demo \
  --no-play-link \
  --changelog "$TMP_DIR/CHANGELOG.md" \
  --output "$TMP_DIR/github-notes.md"

assert_not_contains "$TMP_DIR/github-notes.md" \
  'alt="Get it on Google Play"' \
  "disabled Play links must not render a Play badge"
assert_contains "$TMP_DIR/github-notes.md" \
  'href="https://github.com/example/demo/releases/tag/v1.2.3"' \
  "non-GitLab notes should preserve the GitHub release badge"
assert_contains "$TMP_DIR/github-notes.md" \
  'alt="Get it on GitHub"' \
  "non-GitLab notes should preserve the GitHub badge"

echo "release notes badge contract tests passed"
