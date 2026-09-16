#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root_dir/gitlab_qq_publish.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -x "$script" ]] || fail "gitlab_qq_publish.sh must be executable"
bash -n "$script"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'apk-test-content\n' > "$work/Demo_arm64-v8a.apk"
metadata_capture="$work/metadata.json"
args_capture="$work/curl.args"

curl() {
  printf '%s\n' "$@" > "$ARGS_CAPTURE"
  for arg in "$@"; do
    if [[ "$arg" == metadata=\<* ]]; then
      field="${arg#metadata=<}"
      field="${field%%;*}"
      cp "$field" "$METADATA_CAPTURE"
    fi
  done
  printf '{"ok":true}\n'
}
export -f curl

ARGS_CAPTURE="$args_capture" METADATA_CAPTURE="$metadata_capture" \
MAGISK_GITLAB_QQ_ENABLED=true \
MAGISK_GITLAB_QQ_TARGET=demo \
NAPGRAM_GITLAB_NOTIFIER_URL=https://napgram.example/api/gitlab-notifier/publish \
NAPGRAM_GITLAB_NOTIFIER_HMAC_SECRET=test-secret \
CI_PROJECT_ID=42 \
CI_PROJECT_PATH=group/demo \
CI_PROJECT_NAME=Demo \
CI_PROJECT_URL=https://gitlab.example/group/demo \
CI_COMMIT_SHA=$(printf 'a%.0s' {1..40}) \
CI_COMMIT_SHORT_SHA=aaaaaaaa \
CI_COMMIT_TITLE='feat: publish apk' \
CI_COMMIT_AUTHOR='CI Bot <ci@example.invalid>' \
CI_COMMIT_BRANCH=beta \
CI_COMMIT_REF_NAME=beta \
CI_PIPELINE_ID=100 \
CI_PIPELINE_URL=https://gitlab.example/group/demo/-/pipelines/100 \
  bash "$script" ci "$work/Demo_arm64-v8a.apk" >/dev/null

jq -e '.schema == "gitlab.notification/v1" and .event == "ci" and .target == "demo" and .project.path == "group/demo" and .artifacts[0].filename == "Demo_arm64-v8a.apk"' "$metadata_capture" >/dev/null || fail "metadata contract failed"
jq -e '(.mergeRequest.iid == null) and (.mergeRequest.title == null) and (.release.tag == null) and (.release.name == null)' "$metadata_capture" >/dev/null || fail "empty optional metadata fields were not pruned"
grep -Eq '^X-GitLab-Notifier-Signature: sha256=[0-9a-f]{64}$' "$args_capture" || fail "signature header missing"
signature="$(sed -n 's/^X-GitLab-Notifier-Signature: sha256=//p' "$args_capture")"
timestamp="$(sed -n 's/^X-GitLab-Notifier-Timestamp: //p' "$args_capture")"
request_id="$(sed -n 's/^X-GitLab-Notifier-Request-Id: //p' "$args_capture")"
target="$(sed -n 's/^X-GitLab-Notifier-Target: //p' "$args_capture")"
expected_signature="$(printf '%s\n%s\n%s\n%s' "$timestamp" "$request_id" "$target" "$(cat "$metadata_capture")" | openssl dgst -sha256 -hmac 'test-secret' -binary | od -An -tx1 -v | tr -d '[:space:]')"
[[ "$signature" == "$expected_signature" ]] || fail "signature does not match canonical metadata"
grep -Fq 'Demo_arm64-v8a.apk' "$args_capture" || fail "artifact form field missing"

echo "GitLab QQ publish script contract test passed"

release_notes_file="$work/release-notes.md"
cat > "$release_notes_file" <<'NOTES'
<div align="center">
  <a href="https://play.google.com/example"><img src="badge.png"/></a>
</div>

## [v1.0.0]
- change

> Full Changelog: https://example.invalid/changelog
NOTES

ARGS_CAPTURE="$args_capture" METADATA_CAPTURE="$metadata_capture" \
MAGISK_GITLAB_QQ_ENABLED=true \
MAGISK_GITLAB_QQ_TARGET=demo \
NAPGRAM_GITLAB_NOTIFIER_URL=https://napgram.example/api/gitlab-notifier/publish \
NAPGRAM_GITLAB_NOTIFIER_HMAC_SECRET=test-secret \
MAGISK_GITLAB_QQ_RELEASE_NOTES_SOURCE="$release_notes_file" \
CI_PROJECT_ID=42 \
CI_PROJECT_PATH=group/demo \
CI_PROJECT_NAME=Demo \
CI_PROJECT_URL=https://gitlab.example/group/demo \
CI_COMMIT_SHA=$(printf 'a%.0s' {1..40}) \
CI_COMMIT_SHORT_SHA=aaaaaaaa \
CI_COMMIT_TITLE='chore: release' \
CI_COMMIT_AUTHOR='CI Bot <ci@example.invalid>' \
CI_COMMIT_TAG=v1.0.0 \
CI_COMMIT_REF_NAME=v1.0.0 \
CI_PIPELINE_ID=101 \
CI_PIPELINE_URL=https://gitlab.example/group/demo/-/pipelines/101 \
  bash "$script" release "$work/Demo_arm64-v8a.apk" >/dev/null

jq -e '.event == "release" and .release.tag == "v1.0.0" and .release.description == "## [v1.0.0]\n- change\n\n> Full Changelog: https://example.invalid/changelog"' "$metadata_capture" >/dev/null || fail "release HTML was not sanitized"
grep -Eq '^X-GitLab-Notifier-Signature: sha256=[0-9a-f]{64}$' "$args_capture" || fail "release signature header missing"
signature="$(sed -n 's/^X-GitLab-Notifier-Signature: sha256=//p' "$args_capture")"
timestamp="$(sed -n 's/^X-GitLab-Notifier-Timestamp: //p' "$args_capture")"
request_id="$(sed -n 's/^X-GitLab-Notifier-Request-Id: //p' "$args_capture")"
target="$(sed -n 's/^X-GitLab-Notifier-Target: //p' "$args_capture")"
expected_signature="$(printf '%s\n%s\n%s\n%s' "$timestamp" "$request_id" "$target" "$(cat "$metadata_capture")" | openssl dgst -sha256 -hmac 'test-secret' -binary | od -An -tx1 -v | tr -d '[:space:]')"
[[ "$signature" == "$expected_signature" ]] || fail "release signature does not match sanitized canonical metadata"
