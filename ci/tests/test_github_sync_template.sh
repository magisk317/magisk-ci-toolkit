#!/usr/bin/env bash
# Guards the shape of .gitlab/ci/github-sync.yml: the inline shell has to keep
# parsing, keep failing closed on a missing target or token, and keep removing
# the credential-bearing remote.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
template="$root_dir/.gitlab/ci/github-sync.yml"
utility="$root_dir/.gitlab/ci/utility.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$template" ]] || fail "github-sync template is missing"
[[ -f "$utility" ]] || fail "utility anchor template is missing"

grep -qF -- '.magisk_github_sync:' "$template" || fail ".magisk_github_sync anchor is missing"
grep -qF -- 'extends: .magisk_utility_base' "$template" || fail "template does not extend the utility anchor"
grep -qF -- 'MAGISK_GITHUB_MIRROR_REPOSITORY' "$template" || fail "mirror target variable is not read"
# The template holds GitLab CI expressions, resolved at runner time, not here.
# shellcheck disable=SC2016
grep -qF -- '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH' "$template" || fail "default-branch rule is missing"
grep -qF -- '- when: never' "$template" || fail "catch-all deny rule is missing"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$template" > "$tmp_dir/sync_script.sh" <<'PYEOF'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
try:
    start = lines.index("    - |")
except ValueError:
    sys.exit("no block scalar found")
body = []
for line in lines[start + 1:]:
    if line.strip() == "":
        body.append("")
        continue
    if not line.startswith("      "):
        break
    body.append(line[6:])
if not body:
    sys.exit("block scalar is empty")
print(chr(10).join(body))
PYEOF

bash -n "$tmp_dir/sync_script.sh" || fail "inline mirror script no longer parses"

# Each entry is a literal fragment of the template, including the GitLab and
# shell expressions it must not expand here.
# shellcheck disable=SC2016
for required in \
  'MAGISK_GITHUB_MIRROR_REPOSITORY:-' \
  'GITHUB_PAT' \
  'git remote add github' \
  'MAGISK_GITHUB_MIRROR_EXCLUDED_TAG_PREFIXES:-backup/ archive/ tmp/ wip/ keep/}' \
  'git push github --force $tag_refspecs' \
  'git remote remove github'; do
  grep -qF -- "$required" "$tmp_dir/sync_script.sh" || fail "inline script lost: $required"
done

# A blanket tag push is how internal backup/ and archive/ tags reached GitHub once
# already; it must never come back.
if grep -qF -- 'git push github --tags' "$tmp_dir/sync_script.sh"; then
  fail "inline script pushes every tag, including the excluded safety-net prefixes"
fi

# The remote URL embeds the credential, so it is removed both defensively
# before the push and for real after it.
[[ "$(grep -cF 'git remote remove github' "$tmp_dir/sync_script.sh")" -ge 2 ]] ||
  fail "remote is not removed before and after the push"

echo "github-sync template checks passed"
