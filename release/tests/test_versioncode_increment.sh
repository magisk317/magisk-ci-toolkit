#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
guard="$root_dir/release/check_release_guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Source only the pieces under test (extract_toml_value + the new check).
awk '/^extract_toml_value\(\) \{/,/^\}/' "$guard" > "$tmp_dir/stub.sh"
awk '/^check_versioncode_increment\(\) \{/,/^\}/' "$guard" >> "$tmp_dir/stub.sh"
# shellcheck source=/dev/null
source "$tmp_dir/stub.sh"

fail=0
note() { printf '%s\n' "$*"; }

mk_repo() {
  local dir="$1" code="$2" prev="$3"
  mkdir -p "$dir/gradle" "$dir/docs"
  printf 'versionCode = "%s"\nversionName = "9.9.9"\n' "$code" > "$dir/gradle/libs.versions.toml"
  {
    printf '## [v9.9.9] - Unreleased\n'
    printf -- '- 版本：`versionCode %s` / `versionName 9.9.9`。\n' "$code"
    printf -- '---\n'
    printf '## [v9.9.8] - 2026-01-01\n'
    printf -- '- 版本：`versionCode %s` / `versionName 9.9.8`。\n' "$prev"
  } > "$dir/docs/CHANGELOG.md"
}

# 1. exact +1 passes with the expected message
mk_repo "$tmp_dir/ok" 44 43
if out="$(check_versioncode_increment "$tmp_dir/ok" 2>&1)"; then
  case "$out" in
    *"PASS: versionCode 44 = last released 43 + 1"*) ;;
    *) note "FAIL: unexpected pass text: $out"; fail=1 ;;
  esac
else
  note "FAIL: the +1 case was rejected: $out"
  fail=1
fi

# 2. a jump (e.g. 43 -> 46) fails
mk_repo "$tmp_dir/jump" 46 43
if check_versioncode_increment "$tmp_dir/jump" >/dev/null 2>&1; then
  note "FAIL: a versionCode jump was accepted"
  fail=1
fi

# 3. reusing the last released code fails
mk_repo "$tmp_dir/same" 43 43
if check_versioncode_increment "$tmp_dir/same" >/dev/null 2>&1; then
  note "FAIL: reusing the last released code was accepted"
  fail=1
fi

# 4. a non-numeric versionCode fails
mk_repo "$tmp_dir/nan" "abc" 43
if check_versioncode_increment "$tmp_dir/nan" >/dev/null 2>&1; then
  note "FAIL: a non-numeric versionCode was accepted"
  fail=1
fi

# 5. a changelog without a previous released section fails closed
mkdir -p "$tmp_dir/noprev/gradle" "$tmp_dir/noprev/docs"
printf 'versionCode = "44"\n' > "$tmp_dir/noprev/gradle/libs.versions.toml"
printf '## [v9.9.9]\n- 版本：`versionCode 44`。\n' > "$tmp_dir/noprev/docs/CHANGELOG.md"
if check_versioncode_increment "$tmp_dir/noprev" >/dev/null 2>&1; then
  note "FAIL: a missing baseline was accepted"
  fail=1
fi

(( fail == 0 )) && note "PASS: check_versioncode_increment"
exit "$fail"
