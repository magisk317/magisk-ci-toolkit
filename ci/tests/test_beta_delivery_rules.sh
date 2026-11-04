#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"

python3 - "$root_dir/.gitlab/ci/android-release.yml" "$root_dir/.gitlab/ci/telegram.yml" <<'PY'
from pathlib import Path
import sys


def extract(path: Path, name: str) -> str:
    lines = path.read_text(encoding="utf-8").splitlines()
    marker = f"{name}:"
    try:
        start = lines.index(marker)
    except ValueError as error:
        raise SystemExit(f"FAIL: {name} is missing from {path}") from error

    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line and not line.startswith(" "):
            end = index
            break
    return "\n".join(lines[start:end]).rstrip()


android = Path(sys.argv[1])
telegram = Path(sys.argv[2])

expected_aab = r'''.magisk_android_ci_aab_rules:
  rules:
    - if: '$DEPENDENCY_OWNER == "gitlab" && $CI_PIPELINE_SOURCE == "web"'
      when: never
    - if: '$DEPENDENCY_OWNER == "gitlab" && $CI_PIPELINE_SOURCE == "api"'
      when: never
    - if: '$CI_COMMIT_BRANCH == "beta" && $CI_PIPELINE_SOURCE == "push" && $RELEASE_KEYSTORE != "" && $STORE_PASSWORD != "" && $KEY_ALIAS != "" && $KEY_PASSWORD != ""'
      when: on_success
    - if: '$CI_COMMIT_BRANCH == "beta" && $CI_PIPELINE_SOURCE == "web" && $RELEASE_KEYSTORE != "" && $STORE_PASSWORD != "" && $KEY_ALIAS != "" && $KEY_PASSWORD != ""'
      when: on_success
    - if: '$CI_COMMIT_BRANCH == "beta" && $CI_PIPELINE_SOURCE == "api" && $RELEASE_KEYSTORE != "" && $STORE_PASSWORD != "" && $KEY_ALIAS != "" && $KEY_PASSWORD != ""'
      when: on_success
    - when: never'''

expected_publish = r'''.magisk_android_ci_publish_play_rules:
  rules:
    - if: '$DEPENDENCY_OWNER == "gitlab" && $CI_PIPELINE_SOURCE == "web"'
      when: never
    - if: '$DEPENDENCY_OWNER == "gitlab" && $CI_PIPELINE_SOURCE == "api"'
      when: never
    - if: '$CI_COMMIT_BRANCH == "beta" && $CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_AUTHOR =~ /Renovate317@users.noreply/ && $MAGISK_ANDROID_RELEASE_PUBLISH_PLAY == "true" && $ANDROID_PUBLISHER_CREDENTIALS != ""'
      when: on_success
    - if: '$CI_COMMIT_BRANCH == "beta" && $CI_PIPELINE_SOURCE == "push" && $MAGISK_ANDROID_RELEASE_PUBLISH_PLAY == "true" && $ANDROID_PUBLISHER_CREDENTIALS != ""'
      when: manual
      allow_failure: true
    - if: '$CI_COMMIT_BRANCH == "beta" && $CI_PIPELINE_SOURCE == "web" && $MAGISK_ANDROID_RELEASE_PUBLISH_PLAY == "true" && $ANDROID_PUBLISHER_CREDENTIALS != ""'
      when: manual
      allow_failure: true
    - if: '$CI_COMMIT_BRANCH == "beta" && $CI_PIPELINE_SOURCE == "api" && $MAGISK_ANDROID_RELEASE_PUBLISH_PLAY == "true" && $ANDROID_PUBLISHER_CREDENTIALS != ""'
      when: manual
      allow_failure: true
    - when: never'''

expected_telegram = r'''.magisk_telegram_ci_delivery_rules:
  rules:
    - if: '$DEPENDENCY_OWNER == "gitlab" && $CI_PIPELINE_SOURCE == "web"'
      when: never
    - if: '$DEPENDENCY_OWNER == "gitlab" && $CI_PIPELINE_SOURCE == "api"'
      when: never
    - if: '$CI_COMMIT_BRANCH == "beta" && $CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_AUTHOR =~ /Renovate317@users.noreply/ && $RELEASE_KEYSTORE != "" && $STORE_PASSWORD != "" && $KEY_ALIAS != "" && $KEY_PASSWORD != ""'
      when: on_success
    - if: '$CI_COMMIT_BRANCH == "beta" && $CI_PIPELINE_SOURCE == "push" && $RELEASE_KEYSTORE != "" && $STORE_PASSWORD != "" && $KEY_ALIAS != "" && $KEY_PASSWORD != ""'
      when: manual
      allow_failure: true
    - if: '$CI_COMMIT_BRANCH == "beta" && $CI_PIPELINE_SOURCE == "web" && $RELEASE_KEYSTORE != "" && $STORE_PASSWORD != "" && $KEY_ALIAS != "" && $KEY_PASSWORD != ""'
      when: manual
      allow_failure: true
    - if: '$CI_COMMIT_BRANCH == "beta" && $CI_PIPELINE_SOURCE == "api" && $RELEASE_KEYSTORE != "" && $STORE_PASSWORD != "" && $KEY_ALIAS != "" && $KEY_PASSWORD != ""'
      when: manual
      allow_failure: true
    - when: never'''

contracts = (
    (android, ".magisk_android_ci_aab_rules", expected_aab),
    (android, ".magisk_android_ci_publish_play_rules", expected_publish),
    (telegram, ".magisk_telegram_ci_delivery_rules", expected_telegram),
)
for path, name, expected in contracts:
    actual = extract(path, name)
    if actual != expected:
        raise SystemExit(
            f"FAIL: {name} changed outside the reviewed beta-delivery contract\n"
            f"--- expected ---\n{expected}\n--- actual ---\n{actual}"
        )

if "ANDROID_PUBLISHER_CREDENTIALS" in expected_aab or "MAGISK_ANDROID_RELEASE_PUBLISH_PLAY" in expected_aab:
    raise SystemExit("FAIL: AAB packaging must not depend on Play publishing state")
for name, expected in (
    ("AAB", expected_aab),
    ("Play", expected_publish),
    ("Telegram", expected_telegram),
):
    if 'CI_PIPELINE_SOURCE == "schedule"' in expected:
        raise SystemExit(f"FAIL: {name} delivery must not run in Renovate schedules")
    for source in ("web", "api"):
        deny = (
            f'- if: \'$DEPENDENCY_OWNER == "gitlab" && '
            f'$CI_PIPELINE_SOURCE == "{source}"\'\n'
            '      when: never'
        )
        if deny not in expected:
            raise SystemExit(f"FAIL: {name} delivery does not suppress Renovate {source} triggers")

print("beta delivery rule contracts passed")
PY
