#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../badges.sh"

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
    return 1
  fi
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

versions_file="$tmp_dir/versions.toml"
wrapper_file="$tmp_dir/gradle-wrapper.properties"
readme_file="$tmp_dir/README with spaces.md"

printf 'kotlin = "2.3.0-RC1"\n' > "$versions_file"
printf 'distributionUrl=https\\://services.gradle.org/distributions/gradle-9.1.0-bin.zip\n' > "$wrapper_file"
printf '%s\n' \
  'before' \
  '<!-- badges:tech:start -->' \
  'old' \
  '<!-- badges:tech:end -->' \
  'after' > "$readme_file"
chmod 0640 "$readme_file"

assert_eq "Kotlin_2.3.0--RC%2B1" "$(badge_escape 'Kotlin 2.3.0-RC+1')" "badge escaping"
assert_eq "2.3.0-RC1" "$(read_toml_value kotlin "$versions_file")" "TOML version lookup"
assert_eq "9.1.0" "$(read_gradle_version "$wrapper_file")" "Gradle version lookup"

badge="$(tech_badge Kotlin '2.3.0-RC1' 7F52FF kotlin https://kotlinlang.org)"
replace_block "$readme_file" tech "$badge"

expected_content="$(printf '%s\n' \
  'before' \
  '<!-- badges:tech:start -->' \
  '[![Kotlin](https://img.shields.io/badge/Kotlin-2.3.0--RC1-7F52FF?style=flat-square&logo=kotlin&logoColor=white)](https://kotlinlang.org)' \
  '<!-- badges:tech:end -->' \
  'after')"
assert_eq "$expected_content" "$(cat "$readme_file")" "marker-delimited block replacement"
assert_eq "640" "$(stat -c '%a' "$readme_file")" "target mode preservation"

replace_block "$readme_file" tech "$badge"
assert_eq "$expected_content" "$(cat "$readme_file")" "idempotent replacement"
if find "$tmp_dir" -maxdepth 1 -name '*.tmp.*' -print -quit | grep -q .; then
  echo "FAIL: temporary replacement file was not cleaned up" >&2
  exit 1
fi

echo "badge helper tests passed"
