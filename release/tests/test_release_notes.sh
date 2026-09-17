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

# The channel badges share one row, so they must also share one height and count.
assert_badge_row() {
  local file=$1 expected_count=$2 count heights
  count="$(grep -c '<img src=' "$file")"
  [[ "$count" == "$expected_count" ]] || fail "expected $expected_count badges, found $count"
  heights="$(grep -o 'height="[0-9]*"' "$file" | sort -u | wc -l)"
  [[ "$heights" == "1" ]] || fail "badges must render at one height, got: $(grep -o 'height="[0-9]*"' "$file" | sort -u | tr '\n' ' ')"
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
  'href="https://play.example/apps/demo"' \
  "GitLab notes should include the configured Play link"
assert_contains "$TMP_DIR/gitlab-notes.md" \
  'href="https://gitlab.example/group/project/-/releases/v1.2.3"' \
  "GitLab notes should link to the current GitLab release"
assert_contains "$TMP_DIR/gitlab-notes.md" \
  'href="https://github.com/example/demo/releases/tag/v1.2.3"' \
  "GitLab notes should also link to the GitHub mirror"
for badge in 'Google Play' 'GitLab' 'GitHub'; do
  assert_contains "$TMP_DIR/gitlab-notes.md" "alt=\"Get it on ${badge}\"" \
    "GitLab notes should render the ${badge} badge"
done
assert_badge_row "$TMP_DIR/gitlab-notes.md" 3
assert_not_contains "$TMP_DIR/gitlab-notes.md" \
  'raw.githubusercontent.com' \
  "badges must not depend on a third-party image host"

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
assert_not_contains "$TMP_DIR/github-notes.md" \
  'alt="Get it on GitLab"' \
  "notes without a GitLab project URL must not render a GitLab badge"
assert_badge_row "$TMP_DIR/github-notes.md" 1

echo "release notes badge contract tests passed"
