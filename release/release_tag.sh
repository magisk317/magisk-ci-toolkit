#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Release Tag — Modular Version
# Source this file and call release_tag with appropriate variables set.
# ============================================================================

# Default root depth (2 for scripts/release/, 1 for scripts/)
MAGISK_ROOT_DEPTH="${MAGISK_ROOT_DEPTH:-2}"

# Release-branch snapshot. check_branch_state_before_checks() records it;
# push_release_branch() and release_tag() consume it. Declared up front so a
# direct push_release_branch() call (tests, ad-hoc recovery) cannot trip over
# `set -u`.
release_head_commit="${release_head_commit:-}"
release_remote_branch_commit="${release_remote_branch_commit:-}"
release_force_push_required="${release_force_push_required:-false}"

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

# Find the protected-tag rule matching a tag name, if any.
# GitLab matches protected-tag names as globs (e.g. "v*"), so mirror that here.
# Return codes: 0 = rule found (PROTECTED_TAG_RULE set); 1 = API answered but no
# rule matches this tag; 2 = could not determine (API/parse failure). Callers
# MUST treat 2 as fatal: a blind push at a possibly-protected tag just bounces
# off GitLab's pre-receive hook.
find_matching_protected_tag() {
  local root_dir="$1"
  local tag_name="$2"

  local rules
  if ! rules="$(cd "$root_dir" && glab api "projects/:fullpath/protected_tags" 2>&1)"; then
    echo "ERROR: cannot query protected tags via glab api. glab output:" >&2
    printf '%s\n' "$rules" | head -3 >&2
    echo "HINT: check 'glab auth status' and HTTPS reachability of the GitLab host (export https_proxy where required)." >&2
    return 2
  fi
  [[ -n "$rules" && "$rules" != "null" ]] || return 1

  PROTECTED_TAG_RULE="$(
    printf '%s' "$rules" | python3 -c '
import fnmatch, json, sys
tag = sys.argv[1]
try:
    rules = json.load(sys.stdin)
except Exception:
    sys.exit(3)
for rule in rules or []:
    if fnmatch.fnmatchcase(tag, rule.get("name", "")):
        print(json.dumps(rule))
        break
' "$tag_name"
  )" || {
    echo "ERROR: cannot parse protected-tags API response" >&2
    return 2
  }
  [[ -n "$PROTECTED_TAG_RULE" ]]
}

# Temporarily drop a protected-tag rule so the tag can be deleted, then put it
# back. GitLab only allows removing protected tags through the API/web UI, so a
# plain `git push :refs/tags/<tag>` is rejected while the rule is in place.
with_protected_tag_unlocked() {
  local root_dir="$1"
  local tag_name="$2"
  shift 2

  local rule_json rc=0
  find_matching_protected_tag "$root_dir" "$tag_name" || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    # Fail closed: protection state unknown, so do NOT blind-push.
    return 1
  elif [[ "$rc" -ne 0 ]]; then
    "$@"   # API answered, no rule matches: run the command directly
    return $?
  fi
  rule_json="$PROTECTED_TAG_RULE"

  local rule_name
  rule_name="$(printf '%s' "$rule_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"

  echo "WARN: protected-tag rule '$rule_name' covers $tag_name; temporarily lifting it" >&2

  local restore_needed=true
  restore_protected_tag() {
    if [[ "$restore_needed" == "true" ]]; then
      echo "Restoring protected-tag rule: $rule_name" >&2
      # Rebuild the rule from --field arguments: `glab api --input -` sends no
      # JSON content type and GitLab answers HTTP 415, silently leaving the tag
      # unprotected.
      local -a fields=(--field "name=$rule_name")
      local level
      while IFS= read -r level; do
        [[ -n "$level" ]] && fields+=(--field "create_access_level=$level")
      done < <(printf '%s' "$rule_json" | python3 -c '
import json, sys
rule = json.load(sys.stdin)
for entry in rule.get("create_access_levels") or []:
    level = entry.get("access_level")
    if level is not None:
        print(level)
')
      if ! (cd "$root_dir" && glab api --method POST "projects/:fullpath/protected_tags" "${fields[@]}") >/dev/null; then
        echo "WARN: failed to restore protected-tag rule '$rule_name'" >&2
      fi
    fi
  }
  trap restore_protected_tag EXIT

  if ! (cd "$root_dir" && glab api --method DELETE "projects/:fullpath/protected_tags/$rule_name") >/dev/null; then
    echo "ERROR: failed to lift protected-tag rule '$rule_name'" >&2
    return 1
  fi

  local status=0
  "$@" || status=$?

  restore_protected_tag
  restore_needed=false
  trap - EXIT

  return "$status"
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
    if ! with_protected_tag_unlocked "$root_dir" "$tag_name" \
        git -C "$root_dir" push "$remote_name" ":refs/tags/$tag_name"; then
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

# Snapshot the release branch *before* any check runs, because the pre-push
# checks (Gradle, WebUI, test shards) can take long enough for the remote
# branch to move. The later push must not clobber a branch that advanced.
# Sets: release_head_commit, release_remote_branch_commit,
#       release_force_push_required.
check_branch_state_before_checks() {
  local root_dir="$1"
  local remote_name="$2"
  local current_branch="$3"
  local head_commit remote_query remote_branch_commit

  head_commit="$(git -C "$root_dir" rev-parse HEAD)"
  release_head_commit="$head_commit"

  # Deliberately not piping straight into awk: with `pipefail` off inside a
  # command substitution the ls-remote failure would be shadowed by awk's
  # success, and a blind push would follow.
  if ! remote_query="$(git -C "$root_dir" ls-remote "$remote_name" "refs/heads/$current_branch")"; then
    echo "ERROR: failed to query remote branch $remote_name/$current_branch" >&2
    exit 1
  fi
  remote_branch_commit="$(printf '%s\n' "$remote_query" | awk 'NR == 1 {print $1}')"
  release_remote_branch_commit="$remote_branch_commit"
  release_force_push_required=false

  # Branch missing on the remote, or already exactly at HEAD: nothing to force.
  if [[ -z "$remote_branch_commit" || "$remote_branch_commit" == "$head_commit" ]]; then
    return 0
  fi

  # Remote is an ancestor of HEAD: a normal push would fast-forward.
  if git -C "$root_dir" merge-base --is-ancestor "$remote_branch_commit" "$head_commit" 2>/dev/null; then
    return 0
  fi

  release_force_push_required=true
  echo "WARN: remote branch $current_branch is not fast-forwardable; will use --force-with-lease." >&2
  echo "WARN: expected remote branch HEAD: $remote_branch_commit" >&2
}

# Push the release branch. GitLab's "allowed to force push" switch is lifted
# only when the branch has actually diverged, so the common fast-forwardable
# release never opens that window at all.
#
# The lease always carries the remote branch commit observed by
# check_branch_state_before_checks(). An empty expectation is intentional: the
# remote was missing the branch, and git then requires it to still be absent at
# push time (verified: it rejects the push with "stale info" otherwise).
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

    if [[ "$release_force_push_required" == "true" ]]; then
      if ! command -v glab >/dev/null 2>&1; then
        echo "ERROR: glab is required to temporarily allow force push on protected branch $current_branch." >&2
        exit 1
      fi
      echo "Temporarily allowing force push on protected branch: $current_branch"
      set_protected_branch_force_push "$root_dir" true
      force_push_enabled=true
      trap restore_force_push_protection EXIT
    fi

    local push_status=0
    git -C "$root_dir" push \
      --force-with-lease="refs/heads/$current_branch:${release_remote_branch_commit}" \
      -o ci.skip "$remote_name" "$current_branch" || push_status=$?

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
  # --force so a pre-existing (possibly protected) tag cannot block the release
  # once delete_remote_tag_if_exists has had its chance to clear it.
  git -C "$root_dir" push --force "$remote_name" "$tag_name"
}

# Core release tag logic — call this from your repo's wrapper script
check_changelog_entry_boundary() {
  local root_dir="$1"
  local tag_name="$2"
  local changelog_file="${MAGISK_CHANGELOG_FILE:-${root_dir}/docs/CHANGELOG.md}"

  if [[ ! -f "$changelog_file" ]]; then
    echo "ERROR: changelog not found: $changelog_file" >&2
    exit 1
  fi

  local changelog_extract
  changelog_extract="$(mktemp)"
  if ! awk -v version="$tag_name" '
    $0 == "---" && found { exit }
    found { print; next }
    index($0, "## [" version "]") == 1 { found = 1; print; next }
    END { if (!found) exit 1 }
  ' "$changelog_file" > "$changelog_extract"; then
    rm -f "$changelog_extract"
    echo "ERROR: no changelog entry for $tag_name in $changelog_file" >&2
    exit 1
  fi

  # A missing "---" separator makes the extract run into the next entry, which
  # is how an older release log ends up inside the current release notes.
  local heading_count
  heading_count="$(grep -c '^## \[' "$changelog_extract" || true)"
  if [[ "${heading_count:-0}" -gt 1 ]]; then
    echo "ERROR: the $tag_name entry in $changelog_file is not closed by a '---' separator." >&2
    echo "       The notes would also carry $((heading_count - 1)) older entry/entries:" >&2
    grep -n '^## \[' "$changelog_extract" | sed 's/^/       /' >&2
    rm -f "$changelog_extract"
    exit 1
  fi
  rm -f "$changelog_extract"
  echo "Changelog entry for $tag_name is bounded by a '---' separator."
}

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

  # Snapshot the branch *before* the checks: they can run long enough for the
  # remote to move, and the push below must not silently overwrite it.
  check_branch_state_before_checks "$root_dir" "$remote_name" "$current_branch"

  # Run release guard (optional — set RELEASE_SKIP_GUARD=true to skip)
  if [[ "${RELEASE_SKIP_GUARD:-false}" != "true" ]]; then
    local guard_script="${MAGISK_RELEASE_GUARD_SCRIPT:-$(dirname "${BASH_SOURCE[0]}")/check_release_guard.sh}"
    if [[ -f "$guard_script" ]]; then
      bash "$guard_script" "$root_dir" "$tag_name"
    else
      echo "WARN: release guard script not found: $guard_script"
    fi
  fi

  # Fail fast: an unbounded changelog entry silently leaks older release logs.
  check_changelog_entry_boundary "$root_dir" "$tag_name"

  # Run pre-push checks (override this function in your wrapper)
  if type run_pre_push_checks >/dev/null 2>&1; then
    run_pre_push_checks
  fi

  # Refuse to tag anything other than the commit that passed the checks: an
  # amended commit or a rebase landing while the checks ran would otherwise
  # ship unverified.
  if [[ "$(git -C "$root_dir" rev-parse HEAD)" != "$release_head_commit" ]]; then
    echo "ERROR: HEAD changed during release checks; refusing to create tag." >&2
    exit 1
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
