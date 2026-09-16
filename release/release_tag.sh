#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Release Tag — Modular Version
# Source this file and call release_tag with appropriate variables set.
# ============================================================================

# Default root depth (2 for scripts/release/, 1 for scripts/)
MAGISK_ROOT_DEPTH="${MAGISK_ROOT_DEPTH:-2}"

# Extract a TOML value from libs.versions.toml
extract_toml_value() {
  local key="$1"
  local file="$2"
  sed -nE "s/^${key}[[:space:]]*=[[:space:]]*\"([^\"]+)\"/\1/p" "$file" | head -n1
}

# Check if working tree is dirty
working_tree_dirty() {
  local root_dir="$1"
  if ! git -C "$root_dir" diff --quiet || ! git -C "$root_dir" diff --cached --quiet; then
    return 0
  fi
  [[ -n "$(git -C "$root_dir" status --porcelain)" ]]
}

# Check if detekt should be skipped
release_skip_detekt() {
  case "${RELEASE_TAG_SKIP_DETEKT:-}" in
    1|true|TRUE|yes|YES|on|ON)
      return 0
      ;;
    ""|0|false|FALSE|no|NO|off|OFF)
      return 1
      ;;
    *)
      echo "ERROR: RELEASE_TAG_SKIP_DETEKT must be 1/true/yes/on or 0/false/no/off." >&2
      exit 2
      ;;
  esac
}

# Delete local tag if it exists
delete_local_tag_if_exists() {
  local root_dir="$1"
  local tag_name="$2"

  if git -C "$root_dir" rev-parse -q --verify "refs/tags/$tag_name" >/dev/null; then
    local old_ref
    old_ref="$(git -C "$root_dir" rev-list -n 1 "$tag_name" 2>/dev/null || true)"
    echo "WARN: local tag exists, deleting before retag: $tag_name (${old_ref:-unknown})"
    git -C "$root_dir" tag -d "$tag_name" >/dev/null
  fi
}

# Delete remote tag if it exists
delete_remote_tag_if_exists() {
  local root_dir="$1"
  local tag_name="$2"
  local remote_name="$3"

  local remote_output
  local remote_ref
  if ! remote_output="$(git -C "$root_dir" ls-remote --tags "$remote_name" "refs/tags/$tag_name")"; then
    echo "ERROR: failed to query remote tags from $remote_name" >&2
    exit 1
  fi
  remote_ref="$(printf '%s\n' "$remote_output" | awk '{print $1}' | head -n1)"
  if [[ -n "$remote_ref" ]]; then
    echo "WARN: remote tag exists, deleting before retag: $tag_name ($remote_ref)"
    if ! git -C "$root_dir" push "$remote_name" ":refs/tags/$tag_name"; then
      echo "ERROR: failed to delete remote tag $tag_name from $remote_name" >&2
      exit 1
    fi
  fi
}

set_protected_branch_force_push() {
  local root_dir="$1"
  local allow_force_push="$2"

  (
    cd "$root_dir"
    glab api \
      --method PATCH \
      "projects/:fullpath/protected_branches/:branch" \
      --field "allow_force_push=$allow_force_push" \
      >/dev/null
  )
}

push_release_branch() {
  local root_dir="$1"
  local remote_name="$2"
  local current_branch="$3"

  (
    set -euo pipefail
    local force_push_enabled=false

    restore_force_push_protection() {
      if [[ "$force_push_enabled" == "true" ]]; then
        echo "Restoring force-push protection for branch: $current_branch"
        set_protected_branch_force_push "$root_dir" false
      fi
    }
    trap restore_force_push_protection EXIT

    echo "Temporarily allowing force push for protected branch: $current_branch"
    set_protected_branch_force_push "$root_dir" true
    force_push_enabled=true

    local push_status=0
    git -C "$root_dir" push --force-with-lease -o ci.skip "$remote_name" "$current_branch" || push_status=$?

    restore_force_push_protection
    force_push_enabled=false
    trap - EXIT
    return "$push_status"
  )
}

# Create signed tag and push
create_signed_tag() {
  local root_dir="$1"
  local tag_name="$2"
  local remote_name="$3"
  local current_branch="$4"

  git -C "$root_dir" tag -s "$tag_name" -m "$tag_name"
  # The tag push owns the release pipeline. Avoid creating a redundant branch
  # pipeline for the same release commit immediately beforehand.
  push_release_branch "$root_dir" "$remote_name" "$current_branch" || return $?
  git -C "$root_dir" push "$remote_name" "$tag_name"
}

# Core release tag logic — call this from your repo's wrapper script
release_tag() {
  local root_dir="${1:-.}"
  local version_file="${root_dir}/gradle/libs.versions.toml"
  local remote_name="${RELEASE_REMOTE:-origin}"

  # Extract version
  local version_name
  version_name="$(extract_toml_value "versionName" "$version_file")"
  if [[ -z "$version_name" ]]; then
    echo "ERROR: failed to parse versionName from $version_file" >&2
    exit 2
  fi

  local tag_name="v$version_name"

  # Get current branch
  local current_branch
  current_branch="$(git -C "$root_dir" branch --show-current)"
  if [[ -z "$current_branch" ]]; then
    echo "ERROR: detached HEAD is not supported for release_tag.sh" >&2
    exit 1
  fi

  echo "Release tag: $tag_name (branch: $current_branch, remote: $remote_name)"

  # Run release guard (optional — set RELEASE_SKIP_GUARD=true to skip)
  if [[ "${RELEASE_SKIP_GUARD:-false}" != "true" ]]; then
    local guard_script="${MAGISK_RELEASE_GUARD_SCRIPT:-$(dirname "${BASH_SOURCE[0]}")/check_release_guard.sh}"
    if [[ -f "$guard_script" ]]; then
      bash "$guard_script" "$root_dir" "$tag_name"
    else
      echo "WARN: release guard script not found: $guard_script"
    fi
  fi

  # Run pre-push checks (override this function in your wrapper)
  if type run_pre_push_checks >/dev/null 2>&1; then
    run_pre_push_checks
  fi

  # Check working tree is clean
  if working_tree_dirty "$root_dir"; then
    echo "ERROR: working tree is not clean. Commit/stash changes before tagging." >&2
    exit 1
  fi

  # Delete existing tags and create new one
  delete_local_tag_if_exists "$root_dir" "$tag_name"
  delete_remote_tag_if_exists "$root_dir" "$tag_name" "$remote_name"
  create_signed_tag "$root_dir" "$tag_name" "$remote_name" "$current_branch"

  echo "Created and pushed tag: $tag_name"
}

# Optional: Run common Gradle CI/Test checks
run_common_gradle_checks() {
  local root_dir="$1"
  shift
  # If extra args are passed, use them, otherwise use defaults
  local custom_args=("$@")
  local gradle_args=()

  if (( ${#custom_args[@]} > 0 )); then
    gradle_args=("${custom_args[@]}")
  else
    # Generic fallback if no specific tasks provided
    gradle_args=(
      check
      assembleDebug
    )
  fi

  if [[ ! -f "$root_dir/gradlew" ]]; then
    echo "WARN: gradlew not found in $root_dir, skipping Gradle checks."
    return 0
  fi

  if release_skip_detekt; then
    echo "WARN: RELEASE_TAG_SKIP_DETEKT is enabled; detekt tasks will be skipped."
    gradle_args+=(-x detekt -x qualityGateDetekt)
  else
    echo "Detekt checks are blocking. Set RELEASE_TAG_SKIP_DETEKT=1 to bypass them."
  fi

  echo "Running pre-push Gradle CI checks with retry helper: ./gradlew ${gradle_args[*]}"
  # Resolve against this toolkit file, not the repo wrapper's SCRIPT_DIR.
  local toolkit_release_dir
  toolkit_release_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  (
    cd "$root_dir"
    bash "${toolkit_release_dir}/../gradle/run_gradle_with_retry.sh" "${gradle_args[@]}"
  )
  echo "Gradle checks passed."
}

# Optional: Run WebUI checks (xinyi-relay only)
run_webui_checks() {
  local root_dir="$1"
  local package_json="$root_dir/frontend/webui/package.json"
  local toolkit_release_dir
  toolkit_release_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  [[ -f "$package_json" ]] || {
    echo "ERROR: WebUI package.json not found: $package_json" >&2
    exit 1
  }

  local package_manager=""
  if command -v node >/dev/null 2>&1; then
    package_manager="$(node -e 'const fs=require("fs");try{process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).packageManager||""))}catch(e){}' "$package_json" 2>/dev/null || true)"
  fi
  if [[ -z "$package_manager" ]]; then
    package_manager="$(grep -o '"packageManager"[[:space:]]*:[[:space:]]*"[^"]*"' "$package_json" 2>/dev/null \
      | head -n1 \
      | sed -E 's/.*"packageManager"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true)"
  fi

  echo "Running WebUI checks (install/lint/typecheck/test/build) with ${package_manager:-unknown}..."
  case "$package_manager" in
    bun@*)
      bash "$toolkit_release_dir/../ci/ensure_bun.sh" "$package_json"
      (
        cd "$root_dir/frontend/webui"
        bun install --frozen-lockfile
        bun run lint
        bun run typecheck
        bun run test
        bun run build
      )
      ;;
    pnpm@*)
      bash "$toolkit_release_dir/../ci/ensure_pnpm.sh" "$package_json"
      (
        cd "$root_dir"
        pnpm -C frontend/webui install --frozen-lockfile
        pnpm -C frontend/webui run lint
        pnpm -C frontend/webui run typecheck
        pnpm -C frontend/webui run test
        pnpm -C frontend/webui run build
      )
      ;;
    *)
      echo "ERROR: WebUI packageManager must be bun@x.y.z or pnpm@x.y.z, got '${package_manager:-<empty>}'" >&2
      exit 1
      ;;
  esac
  echo "WebUI checks passed."
}

# Optional: Run fastlane sync (xinyi-relay only)
run_fastlane_sync() {
  local root_dir="$1"
  local sync_script="${root_dir}/scripts/release/sync_fastlane_metadata.sh"

  if [[ ! -f "$sync_script" ]]; then
    echo "WARN: fastlane sync script not found: $sync_script"
    return 0
  fi

  echo "Running fastlane metadata sync..."
  bash "$sync_script"
  echo "Fastlane metadata sync completed."
}

# If sourced directly (not from a wrapper), run with defaults
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ -n "${1:-}" ]] && [[ -d "$1" ]]; then
    ROOT_DIR="$1"
  else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ROOT_DIR="$(cd "${SCRIPT_DIR}$(printf '/..%.s' $(seq 1 "${MAGISK_ROOT_DEPTH}"))" && pwd)"
  fi

  release_tag "$ROOT_DIR"
fi
