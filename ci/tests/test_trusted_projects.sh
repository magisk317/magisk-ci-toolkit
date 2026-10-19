#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$(cd "$script_dir/.." && pwd)/trusted_projects.sh"

# Every consumer renovates its protected beta branch.
for trusted_path in \
  magisk3171/MiPushFramework \
  magisk3171/XposedSmsCode \
  magisk3171/xinyi-relay \
  magisk3171/napgram-ecosystem/NapGram \
  magisk3171/napgram-ecosystem/napgram-ui-dist \
  magisk3171/SerialBridge \
  magisk3171/MiPushZygisk \
  magisk3171/MiPushConfigurations \
  magisk3171/napgram-ecosystem/NapLink \
  magisk3171/android-host-tools-arm64; do
  [[ "$(trusted_target_branch "$trusted_path")" == "beta" ]] || {
    echo "unexpected target branch for $trusted_path" >&2
    exit 1
  }
done

# The shared toolkit is the controller project, not an upstream: it cannot
# bridge into itself, so its own Renovate merge requests are merged by
# ci/auto_merge_self_renovate_mrs.sh from its own schedule pipeline. It must
# not appear in the controller allowlist.
if trusted_project_id "magisk3171/shared/magisk-ci-toolkit" >/dev/null; then
  echo "controller project must not resolve a trusted upstream ID" >&2
  exit 1
fi
if trusted_target_branch "magisk3171/shared/magisk-ci-toolkit" >/dev/null; then
  echo "controller project must not have a trusted target branch" >&2
  exit 1
fi

# Unknown projects resolve neither an ID nor a target branch.
if trusted_project_id "magisk3171/not-a-project" >/dev/null; then
  echo "unknown project must not resolve an ID" >&2
  exit 1
fi
if trusted_target_branch "magisk3171/not-a-project" >/dev/null; then
  echo "unknown project must not resolve a target branch" >&2
  exit 1
fi

# The reconcile sweep (ci/reconcile_trusted_renovate_mrs.sh) visits exactly
# the enumerated paths: every one of them must resolve an ID and a target
# branch, none of them may be the controller project itself, and the set must
# cover every upstream in the two case statements above.
expected_paths=(
  "magisk3171/shared/magisk-build-logic"
  "magisk3171/MiPushFramework"
  "magisk3171/XposedSmsCode"
  "magisk3171/xinyi-relay"
  "magisk3171/SerialBridge"
  "magisk3171/napgram-ecosystem/NapGram"
  "magisk3171/napgram-ecosystem/napgram-ui-dist"
  "magisk3171/MiPushConfigurations"
  "magisk3171/MiPushZygisk"
  "magisk3171/napgram-ecosystem/NapLink"
  "magisk3171/android-host-tools-arm64"
)
mapfile -t enumerated_paths < <(trusted_project_paths)
if [[ "${#enumerated_paths[@]}" -ne "${#expected_paths[@]}" ]]; then
  echo "trusted_project_paths must enumerate ${#expected_paths[@]} projects, got ${#enumerated_paths[@]}" >&2
  exit 1
fi
for index in "${!expected_paths[@]}"; do
  if [[ "${enumerated_paths[$index]}" != "${expected_paths[$index]}" ]]; then
    echo "unexpected enumerated path ${enumerated_paths[$index]} at position ${index}" >&2
    exit 1
  fi
  trusted_path="${expected_paths[$index]}"
  trusted_project_id "$trusted_path" >/dev/null || {
    echo "enumerated path $trusted_path must resolve a project ID" >&2
    exit 1
  }
  trusted_target_branch "$trusted_path" >/dev/null || {
    echo "enumerated path $trusted_path must resolve a target branch" >&2
    exit 1
  }
done

echo "Trusted project mapping tests passed"
