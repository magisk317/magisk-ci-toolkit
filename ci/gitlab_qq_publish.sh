#!/usr/bin/env bash
set -euo pipefail

# Build and upload a signed gitlab.notification/v1 envelope.
# Usage: gitlab_qq_publish.sh EVENT [APK ...]

usage() {
  echo "Usage: $0 ci|release|merge_request|pipeline_failure [artifact.apk ...]" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
event=$1
shift
case "$event" in
  ci|release|merge_request|pipeline_failure) ;;
  *) usage ;;
esac

if [[ "${MAGISK_GITLAB_QQ_ENABLED:-false}" != "true" ]]; then
  echo "GitLab QQ notifier disabled; skip."
  exit 0
fi

: "${NAPGRAM_GITLAB_NOTIFIER_URL:?NAPGRAM_GITLAB_NOTIFIER_URL is required}"
: "${NAPGRAM_GITLAB_NOTIFIER_HMAC_SECRET:?NAPGRAM_GITLAB_NOTIFIER_HMAC_SECRET is required}"
: "${MAGISK_GITLAB_QQ_TARGET:?MAGISK_GITLAB_QQ_TARGET is required}"
: "${CI_PROJECT_PATH:?CI_PROJECT_PATH is required}"
: "${CI_PROJECT_URL:?CI_PROJECT_URL is required}"

if [[ ! "$MAGISK_GITLAB_QQ_TARGET" =~ ^[a-zA-Z0-9_-]{1,64}$ ]]; then
  echo "Invalid MAGISK_GITLAB_QQ_TARGET" >&2
  exit 2
fi

if [[ "$event" == merge_request && "$#" -gt 0 ]]; then
  echo "Merge request notifications cannot upload artifacts" >&2
  exit 2
fi

for artifact in "$@"; do
  [[ -f "$artifact" ]] || { echo "Artifact not found: $artifact" >&2; exit 1; }
  [[ "${artifact##*.}" == apk || "${artifact##*.}" == APK ]] || { echo "Only .apk artifacts are supported: $artifact" >&2; exit 2; }
done

short_sha="${CI_COMMIT_SHORT_SHA:-${CI_COMMIT_SHA:-unknown}}"
commit_title="${CI_COMMIT_TITLE:-${CI_COMMIT_MESSAGE:-}}"
commit_title="${commit_title%%$'\n'*}"
if [[ -n "${CI_COMMIT_SHA:-}" ]] && command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  source_commit_title="$(git log -1 --no-merges --format=%s "${CI_COMMIT_SHA}^2" 2>/dev/null || true)"
  [[ -n "$source_commit_title" ]] && commit_title="$source_commit_title"
fi

release_notes=""
if [[ -n "${MAGISK_GITLAB_QQ_RELEASE_NOTES_SOURCE:-}" && -f "$MAGISK_GITLAB_QQ_RELEASE_NOTES_SOURCE" ]]; then
  release_notes="$(cat "$MAGISK_GITLAB_QQ_RELEASE_NOTES_SOURCE")"
  release_notes="$(printf '%s' "$release_notes" | jq -Rsr 'gsub("(?is)<div[^>]*>.*?</div>"; "") | gsub("<[^>]*>"; "") | gsub("\r\n?"; "\n") | gsub("\n[ \t]*\n(?:[ \t]*\n)+"; "\n\n") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")')"
fi

metadata_file="$(mktemp)"
cleanup() {
  rm -f "$metadata_file"
}
trap cleanup EXIT

artifact_json='[]'
for artifact in "$@"; do
  filename="$(basename "$artifact")"
  size="$(stat -c '%s' "$artifact")"
  sha256="$(sha256sum "$artifact" | awk '{print $1}')"
  artifact_json="$(jq -cS \
    --arg filename "$filename" \
    --argjson size "$size" \
    --arg sha256 "$sha256" \
    '. + [{filename: $filename, size: $size, sha256: $sha256}]' <<<"$artifact_json")"
done

ref_kind="branch"
ref_name="${CI_COMMIT_REF_NAME:-${CI_COMMIT_BRANCH:-}}"
if [[ -n "${CI_COMMIT_TAG:-}" ]]; then
  ref_kind="tag"
  ref_name="$CI_COMMIT_TAG"
fi

release_url=""
if [[ -n "${CI_COMMIT_TAG:-}" ]]; then
  release_url="${CI_PROJECT_URL%/}/-/releases/${CI_COMMIT_TAG}"
fi

merge_request_url=""
if [[ -n "${CI_MERGE_REQUEST_IID:-}" ]]; then
  merge_request_url="${CI_PROJECT_URL%/}/-/merge_requests/${CI_MERGE_REQUEST_IID}"
fi

commit_url=""
if [[ -n "${CI_COMMIT_SHA:-}" ]]; then
  commit_url="${CI_PROJECT_URL%/}/-/commit/${CI_COMMIT_SHA}"
fi

pipeline_url="${CI_PIPELINE_URL:-}"
metadata="$(jq -n -cS \
  --arg schema 'gitlab.notification/v1' \
  --arg event "$event" \
  --arg target "$MAGISK_GITLAB_QQ_TARGET" \
  --arg project_id "${CI_PROJECT_ID:-}" \
  --arg project_path "$CI_PROJECT_PATH" \
  --arg project_name "${CI_PROJECT_NAME:-}" \
  --arg project_url "$CI_PROJECT_URL" \
  --arg ref_name "$ref_name" \
  --arg ref_kind "$ref_kind" \
  --arg ref_protected "${CI_COMMIT_REF_PROTECTED:-false}" \
  --arg sha "${CI_COMMIT_SHA:-}" \
  --arg short_sha "$short_sha" \
  --arg commit_title "$commit_title" \
  --arg commit_message "${CI_COMMIT_MESSAGE:-}" \
  --arg commit_author "${CI_COMMIT_AUTHOR:-}" \
  --arg commit_url "$commit_url" \
  --arg pipeline_id "${CI_PIPELINE_ID:-}" \
  --arg pipeline_iid "${CI_PIPELINE_IID:-}" \
  --arg pipeline_url "$pipeline_url" \
  --arg pipeline_source "${CI_PIPELINE_SOURCE:-}" \
  --arg pipeline_status "${CI_PIPELINE_STATUS:-success}" \
  --arg mr_iid "${CI_MERGE_REQUEST_IID:-}" \
  --arg mr_title "${CI_MERGE_REQUEST_TITLE:-}" \
  --arg mr_author "${GITLAB_USER_NAME:-${CI_COMMIT_AUTHOR:-}}" \
  --arg mr_source "${CI_MERGE_REQUEST_SOURCE_BRANCH_NAME:-}" \
  --arg mr_target "${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-}" \
  --arg mr_head "${CI_MERGE_REQUEST_SOURCE_BRANCH_SHA:-${CI_COMMIT_SHA:-}}" \
  --arg mr_url "$merge_request_url" \
  --arg release_tag "${CI_COMMIT_TAG:-}" \
  --arg release_name "${CI_RELEASE_NAME:-${CI_COMMIT_TAG:-}}" \
  --arg release_url "$release_url" \
  --arg release_description "$release_notes" \
  --argjson artifacts "$artifact_json" \
  --argjson ref_protected_json "${CI_COMMIT_REF_PROTECTED:-false}" \
  '{
    schema: $schema,
    event: $event,
    target: $target,
    project: {id: $project_id, path: $project_path, name: $project_name, url: $project_url},
    ref: {name: $ref_name, kind: $ref_kind, protected: $ref_protected_json},
    commit: {sha: $sha, shortSha: $short_sha, title: $commit_title, message: $commit_message, author: $commit_author, url: $commit_url},
    pipeline: {id: $pipeline_id, iid: $pipeline_iid, url: $pipeline_url, source: $pipeline_source, status: $pipeline_status},
    mergeRequest: {iid: $mr_iid, title: $mr_title, author: $mr_author, sourceBranch: $mr_source, targetBranch: $mr_target, headSha: $mr_head, url: $mr_url},
    release: {tag: $release_tag, name: $release_name, url: $release_url, description: $release_description},
    artifacts: $artifacts
  }' | jq -cS 'walk(if type == "object" then with_entries(select(.value != null and .value != "")) else . end)')"
printf '%s\n' "$metadata" > "$metadata_file"

timestamp="$(date +%s)"
request_id="${CI_PROJECT_ID:-unknown}:${event}:${CI_COMMIT_SHA:-${CI_COMMIT_TAG:-unknown}}"
signing_payload="$(printf '%s\n%s\n%s\n%s' "$timestamp" "$request_id" "$MAGISK_GITLAB_QQ_TARGET" "$metadata")"
signature="$(printf '%s' "$signing_payload" | openssl dgst -sha256 -hmac "$NAPGRAM_GITLAB_NOTIFIER_HMAC_SECRET" -binary | od -An -tx1 -v | tr -d '[:space:]')"

curl_args=(
  --fail-with-body
  --silent
  --show-error
  --location
  --retry 2
  --retry-all-errors
  --connect-timeout "${NAPGRAM_GITLAB_NOTIFIER_CONNECT_TIMEOUT_SECONDS:-10}"
  --max-time "${NAPGRAM_GITLAB_NOTIFIER_TIMEOUT_SECONDS:-300}"
  -X POST
  -H "X-GitLab-Notifier-Timestamp: $timestamp"
  -H "X-GitLab-Notifier-Request-Id: $request_id"
  -H "X-GitLab-Notifier-Target: $MAGISK_GITLAB_QQ_TARGET"
  -H "X-GitLab-Notifier-Signature: sha256=$signature"
  -F "metadata=<${metadata_file};type=application/json"
)
for artifact in "$@"; do
  filename="$(basename "$artifact")"
  curl_args+=( -F "artifact=@${artifact};filename=${filename};type=application/vnd.android.package-archive" )
done

response="$(curl "${curl_args[@]}" "${NAPGRAM_GITLAB_NOTIFIER_URL%/}")"
printf '%s\n' "$response"
