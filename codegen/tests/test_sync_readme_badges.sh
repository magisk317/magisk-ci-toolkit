#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
driver="${script_dir}/../sync_readme_badges.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/gradle/wrapper" "$repo/config"

cat > "$repo/gradle/libs.versions.toml" <<'TOML'
kotlin = "2.5.0-Beta1"
java = "27"
compose-bom-alpha = "2026.10.00"
agp = "9.5.0-alpha10"
minSdk = "28"
targetSdk = "37"
libxposed-api = "102.0.0"
TOML
printf 'distributionUrl=https\\://services.gradle.org/distributions/gradle-9.9.0-milestone-2-bin.zip\n' \
  > "$repo/gradle/wrapper/gradle-wrapper.properties"
cat > "$repo/config/readme-badges.conf" <<'CONF'
PLATFORM=gitlab
PROJECT_PATH=magisk3171/Example
DEFAULT_BRANCH=beta
CONF
cat > "$repo/README.md" <<'MD'
# Example
<!-- badges:platform:start -->
stale
<!-- badges:platform:end -->
<!-- badges:tech:start -->
stale
<!-- badges:tech:end -->
body
MD
cp "$repo/README.md" "$repo/README-EN.md"

fail=0
note() { printf '%s\n' "$*"; }

# 1. check mode must fail on stale badges
if bash "$driver" --check "$repo" >/dev/null 2>&1; then
  note "FAIL: --check accepted a stale README"
  fail=1
fi

# 2. write mode fixes both READMEs
bash "$driver" "$repo" >/dev/null

# 3. check mode passes afterwards
if ! bash "$driver" --check "$repo" >/dev/null 2>&1; then
  note "FAIL: --check rejected a freshly synced README"
  fail=1
fi

# 4. expected escaped values are present in both READMEs
for expect in \
  'Kotlin-2.5.0--Beta1' \
  'Java-27%2B' \
  'BOM_2026.10.00' \
  'Gradle-9.9.0--milestone--2' \
  'AGP-9.5.0--alpha10' \
  'Min_SDK-28' \
  'Target_SDK-37' \
  'Xposed_API-102'; do
  for f in README.md README-EN.md; do
    grep -qF "$expect" "$repo/$f" || { note "FAIL: missing $expect in $f"; fail=1; }
  done
done
grep -qF 'gitlab/pipeline-status/magisk3171%2FExample?branch=beta' "$repo/README.md" \
  || { note "FAIL: pipeline-status badge missing"; fail=1; }
grep -qF 'gitlab/v/release/magisk3171%2FExample' "$repo/README.md" \
  || { note "FAIL: release badge missing"; fail=1; }
grep -qF 'License-GPL--3.0' "$repo/README.md" \
  || { note "FAIL: license badge missing"; fail=1; }

# 5. missing config is a hard error
mv "$repo/config/readme-badges.conf" "$tmp/conf.bak"
if bash "$driver" --check "$repo" >/dev/null 2>&1; then
  note "FAIL: missing config should be a hard error"
  fail=1
fi
mv "$tmp/conf.bak" "$repo/config/readme-badges.conf"

# 6. write mode is idempotent
bash "$driver" "$repo" >/dev/null
cp "$repo/README.md" "$tmp/before.md"
bash "$driver" "$repo" >/dev/null
cmp -s "$repo/README.md" "$tmp/before.md" || { note "FAIL: write mode is not idempotent"; fail=1; }

if (( fail == 0 )); then
  note "PASS: sync_readme_badges"
fi
exit "$fail"
