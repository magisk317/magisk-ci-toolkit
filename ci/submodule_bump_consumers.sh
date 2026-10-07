#!/usr/bin/env bash
# Create merge requests in all consumer repos to bump a shared submodule.
#
# Required env:
#   MAGISK_SUBMODULE_NAME        e.g. "magisk-ui-kit"
#   MAGISK_SUBMODULE_BUMP_TOKEN  GitLab token with api + write_repository scope
#   CI_COMMIT_SHA                current submodule commit (set by GitLab CI)
#
# Reads: ci/submodule_consumers.json (registry of submodule → consumers)

set -euo pipefail

SUBMODULE_NAME="${MAGISK_SUBMODULE_NAME:?MAGISK_SUBMODULE_NAME is required}"
BUMP_TOKEN="${MAGISK_SUBMODULE_BUMP_TOKEN:?MAGISK_SUBMODULE_BUMP_TOKEN is required}"
COMMIT_SHA="${CI_COMMIT_SHA:?CI_COMMIT_SHA is required}"
SHORT_SHA="${COMMIT_SHA:0:8}"

TOOLKIT_DIR="${MAGISK_CI_TOOLKIT_DIR:-.}"
REGISTRY="${TOOLKIT_DIR}/ci/submodule_consumers.json"
API_BASE="${CI_API_V4_URL:-https://gitlab.com/api/v4}"

if [ ! -f "$REGISTRY" ]; then
  echo "Registry not found at $REGISTRY" >&2
  exit 1
fi

# Look up this submodule in the registry
CONSUMERS_JSON="$(jq -r --arg name "$SUBMODULE_NAME" '.[$name] // empty' "$REGISTRY")"
if [ -z "$CONSUMERS_JSON" ]; then
  echo "Submodule '$SUBMODULE_NAME' not found in registry; skip."
  exit 0
fi

SUBMODULE_PATH="$(echo "$CONSUMERS_JSON" | jq -r '.submodule_path')"
CONSUMER_COUNT="$(echo "$CONSUMERS_JSON" | jq '.consumers | length')"
echo "Bumping $SUBMODULE_NAME ($SUBMODULE_PATH) in $CONSUMER_COUNT consumer(s) to $SHORT_SHA"

close_superseded_mrs() {
  local consumer_id="$1"
  local current_branch="$2"
  local branch_prefix="chore/bump-${SUBMODULE_NAME}-"
  local open_mrs

  open_mrs="$(curl --fail --silent --show-error --header "PRIVATE-TOKEN: $BUMP_TOKEN" \
    --get \
    --data-urlencode "state=opened" \
    --data-urlencode "target_branch=beta" \
    --data-urlencode "per_page=100" \
    "${API_BASE}/projects/${consumer_id}/merge_requests")" || {
    echo "  Warning: unable to list existing ${SUBMODULE_NAME} bump MRs; leaving them open." >&2
    return 0
  }

  while IFS=$'\t' read -r iid source_branch; do
    [[ -n "$iid" && -n "$source_branch" ]] || continue
    [[ "$source_branch" == "$current_branch" ]] && continue
    echo "  Closing superseded ${SUBMODULE_NAME} bump MR !${iid} (${source_branch})"
    if ! curl --fail --silent --show-error --request PUT \
      --header "PRIVATE-TOKEN: $BUMP_TOKEN" \
      --data-urlencode "state_event=close" \
      "${API_BASE}/projects/${consumer_id}/merge_requests/${iid}" >/dev/null; then
      echo "  Warning: failed to close superseded MR !${iid}; leaving it open." >&2
    fi
  done < <(
    jq -r --arg prefix "$branch_prefix" \
      '.[] | select((.source_branch // "") | startswith($prefix)) | [.iid, .source_branch] | @tsv' \
      <<<"$open_mrs"
  )
}

bump_consumer() {
  local consumer_path="$1"
  local consumer_id="$2"
  local branch_name="chore/bump-${SUBMODULE_NAME}-${SHORT_SHA}"

  echo "--- $consumer_path ---"

  # Clone consumer (shallow)
  local work_dir
  work_dir="$(mktemp -d)"
  local clone_url="https://oauth2:${BUMP_TOKEN}@gitlab.com/${consumer_path}.git"

  if ! git clone --quiet --depth 1 --branch beta "$clone_url" "$work_dir" 2>/dev/null; then
    echo "  Failed to clone $consumer_path; skip."
    rm -rf "$work_dir"
    return 0
  fi

  # Init and update the specific submodule
  cd "$work_dir"
  # Same bot identity as the shared catalog sync in build-logic: the consumer
  # repos' telegram:ci auto-notify rules match CI_COMMIT_AUTHOR against
  # Renovate317@users.noreply, and the id prefix is what lets GitLab attribute
  # the commit to the Renovate317 account. Keep both fields in step with
  # build-logic/scripts/sync_and_push_consumers.sh - a human name here used to
  # push bot work under the maintainer's identity.
  git config user.name "Renovate"
  git config user.email "40025304-Renovate317@users.noreply.gitlab.com"

  # Fetch the submodule at the target commit
  local submodule_url
  submodule_url="$(git config -f .gitmodules --get "submodule.${SUBMODULE_PATH}.url" 2>/dev/null || true)"
  if [ -z "$submodule_url" ]; then
    echo "  Submodule '$SUBMODULE_PATH' not found in .gitmodules; skip."
    cd /
    rm -rf "$work_dir"
    return 0
  fi

  # Check current submodule commit
  local old_commit
  old_commit="$(git ls-tree HEAD "$SUBMODULE_PATH" 2>/dev/null | awk '{print $3}' || true)"
  if [ "$old_commit" = "$COMMIT_SHA" ]; then
    echo "  Already at $SHORT_SHA; skip."
    cd /
    rm -rf "$work_dir"
    return 0
  fi

  # Update submodule pointer
  git -c "url.https://oauth2:${BUMP_TOKEN}@gitlab.com/.insteadOf=https://gitlab.com/" \
    submodule init "$SUBMODULE_PATH"
  git -c "url.https://oauth2:${BUMP_TOKEN}@gitlab.com/.insteadOf=https://gitlab.com/" \
    submodule update --depth 1 "$SUBMODULE_PATH"
  cd "$SUBMODULE_PATH"
  git -c "url.https://oauth2:${BUMP_TOKEN}@gitlab.com/.insteadOf=https://gitlab.com/" \
    fetch --depth 1 origin "$COMMIT_SHA"
  git checkout --detach FETCH_HEAD
  cd "$work_dir"
  git add "$SUBMODULE_PATH"

  # Commit
  git commit -m "chore(deps): update submodule ${SUBMODULE_PATH} to ${SHORT_SHA}" --quiet

  # Push branch
  git push --quiet origin HEAD:"refs/heads/${branch_name}" --force 2>/dev/null || {
    echo "  Failed to push branch; skip."
    cd /
    rm -rf "$work_dir"
    return 0
  }

  # Create MR via API
  local mr_response
  mr_response="$(curl -sS --header "PRIVATE-TOKEN: $BUMP_TOKEN" \
    --data-urlencode "source_branch=${branch_name}" \
    --data-urlencode "target_branch=beta" \
    --data-urlencode "title=chore(deps): update submodule ${SUBMODULE_PATH} to ${SHORT_SHA}" \
    --data-urlencode "remove_source_branch=true" \
    "${API_BASE}/projects/${consumer_id}/merge_requests" 2>/dev/null || true)"

  local mr_iid
  mr_iid="$(echo "$mr_response" | jq -r '.iid // empty' 2>/dev/null || true)"
  local mr_web_url
  mr_web_url="$(echo "$mr_response" | jq -r '.web_url // empty' 2>/dev/null || true)"

  if [ -n "$mr_iid" ]; then
    echo "  Created MR !${mr_iid}: ${mr_web_url}"

    # Set merge_when_pipeline_succeeds
    curl -sS --request PUT --header "PRIVATE-TOKEN: $BUMP_TOKEN" \
      --data "merge_when_pipeline_succeeds=true" \
      "${API_BASE}/projects/${consumer_id}/merge_requests/${mr_iid}/merge" >/dev/null 2>&1 || true

    # Keep only the newest bump MR for this consumer/submodule pair.
    close_superseded_mrs "$consumer_id" "$branch_name"
  else
    echo "  Failed to create MR: $mr_response" >&2
  fi

  cd /
  rm -rf "$work_dir"
}

for ((i = 0; i < CONSUMER_COUNT; i++)); do
  consumer_path="$(echo "$CONSUMERS_JSON" | jq -r ".consumers[$i].path")"
  consumer_id="$(echo "$CONSUMERS_JSON" | jq -r ".consumers[$i].id")"
  bump_consumer "$consumer_path" "$consumer_id"
done

echo "Done."
