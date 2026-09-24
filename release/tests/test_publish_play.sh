#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/../publish_play.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Stub the host toolchain the script bootstraps (apt/gem/ruby/fastlane) and the
# privileged cleanup it performs, so the real script can run unprivileged.
stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/apt-get" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$stub_bin/gem" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$stub_bin/ruby" <<'EOF'
#!/usr/bin/env bash
printf '%s' "/nonexistent"
EOF
cat > "$stub_bin/rm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$stub_bin/fastlane" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FASTLANE_STUB_LOG:?FASTLANE_STUB_LOG is required}"
exit "${FASTLANE_STUB_EXIT:-0}"
EOF
chmod +x "$stub_bin"/*

aab_file="$tmp_dir/app.aab"
printf 'not-a-real-aab' > "$aab_file"

# Best-effort contract: every exit path must leave a machine-readable status in
# the release env file (skipped / published / failed), because the publish job
# runs with allow_failure: true and an orange job still owes an explanation.
run_publish() {
  local env_file="$tmp_dir/status.env"
  rm -f "$env_file" "$tmp_dir/fastlane.log"
  env PATH="$stub_bin:$PATH" \
    FASTLANE_STUB_LOG="$tmp_dir/fastlane.log" \
    FASTLANE_STUB_EXIT="${FASTLANE_STUB_EXIT:-0}" \
    MAGISK_RELEASE_ENV_FILE="$env_file" \
    MAGISK_ANDROID_RELEASE_PACKAGE_NAME="example.app" \
    ANDROID_PUBLISHER_CREDENTIALS='{"type":"service_account"}' \
    MAGISK_PLAY_AAB_FILE="$aab_file" \
    "$@" \
    bash "$script" >"$tmp_dir/run.log" 2>&1
}

alpha_env=(
  MAGISK_PLAY_TRACK=alpha
  MAGISK_PLAY_VERSION_NAME=1.0.0-alpha.1
  MAGISK_PLAY_VERSION_CODE=100
  MAGISK_PLAY_TITLE="Example"
  MAGISK_PLAY_SHORT_DESCRIPTION="Example app"
  MAGISK_PLAY_FULL_DESCRIPTION="Example app description"
  MAGISK_PLAY_CHANGELOG="test changelog"
)

# 1. Review-gate skip: exits 0 and records the skip reason.
rc=0
run_publish "${alpha_env[@]}" \
  MAGISK_PLAY_SKIP_RELEASE=1 MAGISK_PLAY_TRACK_STATUS=IN_REVIEW || rc=$?
[ "$rc" -eq 0 ] || fail "skip path must exit 0 (got $rc)"
grep -Fq 'MAGISK_RELEASE_STATUS=skipped' "$tmp_dir/status.env" ||
  fail "skip path must record status=skipped"
grep -Fq 'MAGISK_RELEASE_SKIP_REASON=IN_REVIEW' "$tmp_dir/status.env" ||
  fail "skip path must record the reason"

# 2. Successful publish: exits 0, records published, calls fastlane supply.
rc=0
run_publish "${alpha_env[@]}" || rc=$?
[ "$rc" -eq 0 ] || fail "publish path must exit 0 (got $rc); log: $(cat "$tmp_dir/run.log")"
grep -Fq 'MAGISK_RELEASE_STATUS=published' "$tmp_dir/status.env" ||
  fail "publish path must record status=published"
grep -Fq -- '--track alpha' "$tmp_dir/fastlane.log" ||
  fail "fastlane must be invoked with the resolved track"
grep -Fq -- '--release_status completed' "$tmp_dir/fastlane.log" ||
  fail "fastlane must complete the release"

# 3. Play-side rejection (fastlane fails): non-zero exit, records failed.
rc=0
FASTLANE_STUB_EXIT=1 run_publish "${alpha_env[@]}" || rc=$?
[ "$rc" -ne 0 ] || fail "fastlane failure must exit non-zero"
grep -Fq 'MAGISK_RELEASE_STATUS=failed' "$tmp_dir/status.env" ||
  fail "fastlane failure must record status=failed"
grep -Fq 'MAGISK_RELEASE_FAIL_REASON=' "$tmp_dir/status.env" ||
  fail "fastlane failure must record a reason"

# 4. Pre-flight validation failure also leaves the audit trail.
rc=0
run_publish MAGISK_PLAY_TRACK=bogus MAGISK_PLAY_VERSION_NAME=1.0.0 \
  MAGISK_PLAY_VERSION_CODE=100 || rc=$?
[ "$rc" -ne 0 ] || fail "unsupported track must exit non-zero"
grep -Fq 'MAGISK_RELEASE_STATUS=failed' "$tmp_dir/status.env" ||
  fail "validation failure must record status=failed"

echo 'PASS: publish_play.sh best-effort status contract'
