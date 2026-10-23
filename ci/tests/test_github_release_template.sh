#!/usr/bin/env bash
# SC2016: the assertions below match Actions expression literals from the
# workflow file verbatim; expanding them would be the bug.
# shellcheck disable=SC2016
# Guards the shape of .github/workflows/release-android.yml, the GitHub-side
# twin of .gitlab/ci/android-release.yml. It is the chain that runs when the
# GitLab runner fleet is down, so the assertions are about the parts that make
# it equivalent to the GitLab pipeline: the same toolkit scripts at a pinned
# SHA, one version authority, the signed-tag contract Xposed-Modules-Repo
# expects, and publish side effects that can be gated off.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
chain="$root_dir/.github/workflows/release-android.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$chain" ]] || fail "the reusable GitHub release chain is missing"

expect() {
  local needle="$1" label="$2"
  grep -qF -- "$needle" "$chain" || fail "$label: missing \"$needle\""
}

expect_count() {
  local needle="$1" want="$2" label="$3"
  local got
  got="$(grep -cF -- "$needle" "$chain" || true)"
  (( got == want )) || fail "$label: found $got occurrence(s) of \"$needle\", expected $want"
}

expect_ordered() {
  local first="$1" second="$2" label="$3"
  local first_line second_line
  first_line="$(grep -nF -- "$first" "$chain" | head -n 1 | cut -d: -f1)"
  second_line="$(grep -nF -- "$second" "$chain" | head -n 1 | cut -d: -f1)"
  [[ -n "$first_line" && -n "$second_line" ]] || fail "$label: could not locate both markers"
  (( first_line < second_line )) || fail "$label: \"$first\" must precede \"$second\""
}

expect 'on:' 'workflow_call trigger'
expect '  workflow_call:' 'workflow_call trigger'

# The four inputs no consumer can be allowed to guess.
for input in toolkit_ref package_name apk_tasks release_cert_sha256; do
  grep -A3 "^      $input:" "$chain" | grep -q 'required: true' ||
    fail "input $input must be required"
done

# One version authority. GitLab resolves the Play decision inside each build
# job; on GitHub the tag, the track and the next versionCode are resolved once
# and every other job reads that result, so a second concurrent resolution can
# never hand two jobs different numbers.
expect_count 'release/resolve_play_release.sh' 1 'a single version authority'
expect 'release/release_ref.sh' 'the shared tag grammar'
expect 'scripts/release/check_release_guard.sh' 'the release guard runs before anything is published'
expect 'release/validate_android_apk_signatures.sh' 'built APKs are checked against the release certificate'
expect 'release/release_notes.sh' 'release notes come from the shared generator'
expect 'release/publish_play.sh' 'Play submission goes through the shared publisher'
expect 'gradle/run_gradle_with_retry.sh' 'gradle runs through the shared retry wrapper'

# The resolved numbers have to reach Gradle in both build jobs, exactly as the
# GitLab templates inject them.
expect_count '-PversionCode=' 2 'version injection into both build jobs'
# -PisCiBuild relaxes minification for throwaway CI builds; GitLab pins it false
# for releases and the chain must not rely on Gradle reading an absent property
# as false.
expect_count '-PisCiBuild=' 2 'the CI-build relaxation is stated off in both build jobs'
expect 'no scripts/release/check_release_guard.sh' \
  'a missing caller release-guard shim fails with a reason'

expect 'modules_release_tag="${VERSION_CODE}-${version_name}"' 'the Xposed-Modules-Repo channel tag is versionCode-versionName'
expect 'refs/tags/${RELEASE_TAG_NAME}:refs/tags/${MODULES_RELEASE_TAG}' 'the channel tag is pushed as an existing tag object'
expect '!= "tag"' 'an unsigned lightweight tag is refused'
expect '^-----BEGIN PGP SIGNATURE-----$' 'an untag-object signature is refused'
# Order matters: gh release create would otherwise mint an unsigned tag on a
# throwaway commit and back-date created_at.
expect_ordered 'refs/tags/${RELEASE_TAG_NAME}:refs/tags/${MODULES_RELEASE_TAG}' \
  'gh release create "$MODULES_RELEASE_TAG"' \
  'the signed channel tag must be pushed before the channel release is created'

# Publishing is opt-out at three levels: per channel, and dry_run for the whole
# chain. A fallback run must be possible without touching any external store.
expect_count '!inputs.dry_run' 3 'dry_run gates every publish job'
expect 'if: inputs.enabled && (inputs.publish_github_release || inputs.publish_modules_repo || inputs.dry_run)' \
  'the caller RELEASE_OWNER gate and the publish switches drive the build job'
expect '      - name: Publish release' 'the GitHub Release step exists'
grep -A8 'publish-github-release:' "$chain" | grep -q 'permissions:' ||
  fail "publish-github-release must declare its permissions"

# Outputs the consumer notification workflow needs; the Telegram sender is a
# separate reusable workflow because chat ids are per repository.
for output in release_tag version_name version_code play_track modules_release_tag github_release_url; do
  expect "$output:" "the chain exports $output for the caller"
done

# A toolkit clone by branch name is the drift the pin contract exists for.
if grep -qE -- '--branch[[:space:]]+[0-9a-fA-F]{1,39}([^0-9a-fA-F]|$)' "$chain"; then
  fail "the chain must not clone the toolkit by a moving ref"
fi
if grep -qE 'fastlane (supply|run)|gem install' "$chain"; then
  fail "the chain must not depend on fastlane; publish_play.sh drives the Play API directly"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Every inline shell block in the chain has to parse. ${{ ... }} expressions are
# valid Actions syntax and invalid bash, so they are replaced before parsing.
python3 - "$chain" "$tmp_dir" <<'PYEOF'
import pathlib
import re
import sys

chain = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
out_dir = pathlib.Path(sys.argv[2])
number = 0
index = 0
while index < len(chain):
    line = chain[index]
    if not re.match(r"^\s*run:\s*[|>]", line):
        index += 1
        continue
    indent = len(re.match(r"^(\s*)", line).group(1))
    body = []
    body_indent = None
    for following in chain[index + 1:]:
        if following.strip() == "":
            body.append("")
            continue
        current = len(re.match(r"^(\s*)", following).group(1))
        if current <= indent:
            break
        if body_indent is None:
            body_indent = current
        body.append(following[body_indent:])
    number += 1
    text = re.sub(r"\$\{\{[^}]*\}\}", "EXPR", "\n".join(body))
    out_dir.joinpath("block-%02d.sh" % number).write_text(
        "#!/usr/bin/env bash\n" + text + "\n", encoding="utf-8")
    index += len(body) + 1
print(number)
PYEOF

for script in "$tmp_dir"/block-*.sh; do
  bash -n "$script" || fail "inline shell in $(basename "$script" .sh) does not parse"
done

if (( $(find "$tmp_dir" -maxdepth 1 -name 'block-*.sh' | wc -l) < 10 )); then
  fail "the extraction found too few run blocks; the guard would pass on an empty set"
fi

if command -v actionlint >/dev/null 2>&1; then
  workdir="$tmp_dir/actionlint"
  mkdir -p "$workdir/.github/workflows"
  cp "$chain" "$workdir/.github/workflows/release-android.yml"
  (cd "$workdir" && actionlint .github/workflows/release-android.yml) ||
    fail "actionlint reported problems in the reusable release chain"
else
  echo "note: actionlint is not installed; skipped the Actions-lint pass"
fi

printf 'ok: the reusable GitHub release chain keeps its GitLab-equivalent shape\n'
