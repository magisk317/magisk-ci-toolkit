#!/usr/bin/env bash
# ci/verify_toolkit_pin.sh has to see toolkit drift on both hosts. The GitLab
# includes decide what the pinned pipeline runs; on GitHub the `uses:` ref
# decides which workflow body or composite action the runner fetches, the
# toolkit_ref/ref input decides which toolkit checkout the scripts come from,
# and a `--branch <name>` clone follows a moving ref. A consumer that pins one
# side and drifts the other gets two different release chains from one commit,
# which is exactly what happened before the GitHub refs were covered.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
guard="$root_dir/ci/verify_toolkit_pin.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$guard" ]] || fail "ci/verify_toolkit_pin.sh is missing"

sha_pinned="$(printf 'a%.0s' {1..40})"
sha_other="$(printf 'b%.0s' {1..40})"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

build_consumer() {
  local dir="$1"
  mkdir -p "$dir/.github/workflows" "$dir/.github/actions/resolve-ci-toolkit" "$dir/scripts"
  cat > "$dir/.gitlab-ci.yml" <<EOF
include:
  - project: magisk3171/shared/magisk-ci-toolkit
    ref: $sha_pinned
    file: /.gitlab/ci/utility.yml
  - project: magisk3171/shared/magisk-ci-toolkit
    ref: $sha_pinned
    file: /.gitlab/ci/android.yml
variables:
  MAGISK_CI_TOOLKIT_REF: "$sha_pinned"
EOF
  cat > "$dir/scripts/resolve_ci_toolkit.sh" <<EOF
TOOLKIT_REF="\${MAGISK_CI_TOOLKIT_REF:-$sha_pinned}"
EOF
  cat > "$dir/.github/actions/resolve-ci-toolkit/action.yml" <<EOF
inputs:
  ref:
    required: false
    default: '$sha_pinned'
EOF
  cat > "$dir/.github/workflows/release.yml" <<EOF
jobs:
  release:
    uses: magisk317/magisk-ci-toolkit/.github/workflows/release-android.yml@$sha_pinned
    with:
      toolkit_ref: $sha_pinned
      package_name: com.example.app
EOF
  # An unrelated `with: ref:` must not be read as a toolkit ref: a checkout of
  # a branch is normal, and a guard that fails on it would never be kept.
  cat > "$dir/.github/workflows/ci.yml" <<EOF
jobs:
  build:
    steps:
      - uses: actions/checkout@v7
        with:
          ref: beta
      - uses: ./.github/actions/resolve-ci-toolkit
        with:
          ref: $sha_pinned
EOF
}

expect_pass() {
  local dir="$1" label="$2" output=''
  if ! output="$(bash "$guard" --root "$dir" 2>&1)"; then
    printf 'FAIL: %s should pass, got:\n%s\n' "$label" "$output" >&2
    exit 1
  fi
  printf '%s\n' "$output" | grep -q 'CI toolkit pin verified' || fail "$label printed no verification line"
}

expect_fail() {
  local dir="$1" label="$2" needle="$3" output='' status=0
  output="$(bash "$guard" --root "$dir" 2>&1)" || status=$?
  if (( status == 0 )); then
    printf 'FAIL: %s should be rejected, but it passed:\n%s\n' "$label" "$output" >&2
    exit 1
  fi
  printf '%s\n' "$output" | grep -qF -- "$needle" || {
    printf 'FAIL: %s failed for the wrong reason, expected %s in:\n%s\n' "$label" "$needle" "$output" >&2
    exit 1
  }
}

clean="$tmp_dir/clean"
build_consumer "$clean"
expect_pass "$clean" "a consumer pinned identically on both hosts"

drift="$tmp_dir/drift-uses"
build_consumer "$drift"
sed -i "s#release-android.yml@$sha_pinned#release-android.yml@$sha_other#" "$drift/.github/workflows/release.yml"
expect_fail "$drift" "a cross-repo uses: at another SHA" "GitHub uses ref differs"

branch="$tmp_dir/branch-uses"
build_consumer "$branch"
sed -i "s#release-android.yml@$sha_pinned#release-android.yml@main#" "$branch/.github/workflows/release.yml"
expect_fail "$branch" "a cross-repo uses: at a branch name" "must be one full toolkit SHA"

drift_input="$tmp_dir/drift-toolkit-ref"
build_consumer "$drift_input"
sed -i "s/^      toolkit_ref: $sha_pinned$/      toolkit_ref: $sha_other/" "$drift_input/.github/workflows/release.yml"
expect_fail "$drift_input" "a toolkit_ref input at another SHA" "GitHub toolkit ref differs"

drift_action="$tmp_dir/drift-action-ref"
build_consumer "$drift_action"
sed -i "s/^          ref: $sha_pinned$/          ref: $sha_other/" "$drift_action/.github/workflows/ci.yml"
expect_fail "$drift_action" "a resolve-ci-toolkit ref input at another SHA" "GitHub toolkit ref differs"

moving="$tmp_dir/clone-branch"
build_consumer "$moving"
cat >> "$moving/.github/workflows/ci.yml" <<EOF
      - name: Resolve CI toolkit
        run: git clone --depth 1 --branch main https://gitlab.com/magisk3171/shared/magisk-ci-toolkit.git .magisk-ci-toolkit
EOF
expect_fail "$moving" "a toolkit clone of a moving branch" "clones the toolkit without a pinned"

pinned_clone="$tmp_dir/clone-pinned"
build_consumer "$pinned_clone"
cat >> "$pinned_clone/.github/workflows/ci.yml" <<EOF
      - name: Resolve CI toolkit
        run: git clone --depth 1 --branch $sha_pinned https://gitlab.com/magisk3171/shared/magisk-ci-toolkit.git .magisk-ci-toolkit
EOF
expect_pass "$pinned_clone" "a toolkit clone pinned to one full SHA"

drift_clone="$tmp_dir/clone-other"
build_consumer "$drift_clone"
cat >> "$drift_clone/.github/workflows/ci.yml" <<EOF
      - name: Resolve CI toolkit
        run: git clone --depth 1 --branch $sha_other https://gitlab.com/magisk3171/shared/magisk-ci-toolkit.git .magisk-ci-toolkit
EOF
expect_fail "$drift_clone" "a toolkit clone at a different SHA" "GitHub toolkit clone ref differs"

# The guard must still catch the GitLab-side drifts it was written for.  One
# drifted include among several is enough to make the pipeline run a different
# toolkit than the pin declares.  This rewrites the first occurrence with bash
# parameter expansion rather than `sed 0,/re/`, because the utility image is
# Alpine and BusyBox sed has no first-match range -- a GNU-only extension fails
# the fixture into staying clean and the guard then correctly passes it.
include_drift="$tmp_dir/include-drift"
build_consumer "$include_drift"
include_yaml="$(cat "$include_drift/.gitlab-ci.yml")"
printf '%s\n' "${include_yaml/    ref: $sha_pinned/    ref: $sha_other}" \
  > "$include_drift/.gitlab-ci.yml"
grep -q "ref: $sha_other" "$include_drift/.gitlab-ci.yml" \
  || fail "the include-drift fixture did not change"
expect_fail "$include_drift" "an include ref at another SHA" "include ref differs"

printf 'ok: verify_toolkit_pin covers the GitLab includes and every GitHub toolkit ref\n'
