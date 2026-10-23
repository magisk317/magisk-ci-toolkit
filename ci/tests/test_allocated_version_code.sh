#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
script="$root_dir/ci/allocated_version_code.sh"
template="$root_dir/.gitlab/ci/android.yml"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$script" ] || fail "$script is missing"
bash -n "$script" || fail "$script has a syntax error"

# The point of this helper is that GitLab gives after_script its own shell, so the
# allocated versionCode has to travel through the workspace. Both halves of that
# hand-off are checked here: the template must write the file, and the helper must
# read it with no exported variable present. 2026-10-23: without the file, every
# staged manifest silently disappeared -- the job stayed green and only the
# artifact list warned about ci-dist/app-ci-manifest.json.
# SC2016: the two assertions below match GitLab CI expression literals from the
# template; they are text to compare, not commands to expand here.
# shellcheck disable=SC2016
grep -Fq 'printf '"'"'%s\n'"'"' "$allocated_code" > "${MAGISK_VERSION_CODE_FILE:-$CI_PROJECT_DIR/.magisk-version-code}"' "$template" \
  || fail 'the build template no longer writes the allocated code to the workspace'
if grep -Fq 'Exported for after_script' "$template"; then
  fail 'the template claims an export reaches after_script; GitLab runs it in a separate shell'
fi

work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT

# 1. MAGISK_VERSION_CODE wins when it is set, with no file anywhere.
out="$(cd "$work_dir" && MAGISK_VERSION_CODE=4242 bash "$script")"
[ "$out" = "4242" ] || fail "env path returned '$out'"

# 2. The hand-off itself: one shell exports the number and writes the file the way
#    the template does, then a second shell starts without that export -- which is
#    exactly what GitLab does between script and after_script -- and still resolves
#    the same number.
handoff="$(bash -c '
  set -euo pipefail
  allocated_code=778
  export MAGISK_VERSION_CODE="$allocated_code"
  printf "%s\n" "$allocated_code" > "$1/.magisk-version-code"
  env -u MAGISK_VERSION_CODE -u CI_PROJECT_DIR \
    MAGISK_VERSION_CODE_FILE="$1/.magisk-version-code" bash "$2"
' _ "$work_dir" "$script")"
[ "$handoff" = "778" ] || fail "script -> after_script returned '$handoff'"

# 3. File only, default location under CI_PROJECT_DIR.
printf '999\n' > "$work_dir/.magisk-version-code"
out="$(cd "$work_dir" && CI_PROJECT_DIR="$work_dir" bash "$script")"
[ "$out" = "999" ] || fail "default file path returned '$out'"

# 4. Padding is tolerated; letters are not.
printf ' 1234 \n' > "$work_dir/.magisk-version-code"
out="$(cd "$work_dir" && CI_PROJECT_DIR="$work_dir" bash "$script")"
[ "$out" = "1234" ] || fail "padded code returned '$out'"
printf 'iid\n' > "$work_dir/.magisk-version-code"
if out="$(cd "$work_dir" && CI_PROJECT_DIR="$work_dir" bash "$script" 2>&1)"; then
  fail "a non-numeric file must not print a code (got '$out')"
fi
case "$out" in
  *'not a versionCode'*) ;;
  *) fail "non-numeric rejection said: $out" ;;
esac

# 5. An empty file is not a code either: staging 0 would make every build look
#    newer than the manifest says it is.
: > "$work_dir/.magisk-version-code"
if out="$(cd "$work_dir" && CI_PROJECT_DIR="$work_dir" bash "$script" 2>&1)"; then
  fail "an empty file must not print a code (got '$out')"
fi
case "$out" in
  *'no allocated versionCode'*) ;;
  *) fail "empty-file failure said: $out" ;;
esac

# 6. Nothing at all: fail, and name both knobs so the operator can fix the job
#    without reading the helper first.
rm -f "$work_dir/.magisk-version-code"
if out="$(cd "$work_dir" && CI_PROJECT_DIR="$work_dir" bash "$script" 2>&1)"; then
  fail "missing code must fail (got '$out')"
fi
case "$out" in
  *MAGISK_VERSION_CODE*) ;;
  *) fail "the failure message must name MAGISK_VERSION_CODE: $out" ;;
esac
case "$out" in
  *MAGISK_VERSION_SCOPE* | *.magisk-version-code*) ;;
  *) fail "the failure message must name the scope or the file: $out" ;;
esac

echo "OK: allocated_version_code keeps the version axis reachable from after_script"
