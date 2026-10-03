#!/usr/bin/env bash
set -euo pipefail

: "${MAGISK_ANDROID_RELEASE_PACKAGE_NAME:?MAGISK_ANDROID_RELEASE_PACKAGE_NAME is required}"
: "${ANDROID_PUBLISHER_CREDENTIALS:?ANDROID_PUBLISHER_CREDENTIALS is required}"
: "${MAGISK_PLAY_TRACK:?MAGISK_PLAY_TRACK is required}"
: "${MAGISK_PLAY_VERSION_NAME:?MAGISK_PLAY_VERSION_NAME is required}"
: "${MAGISK_PLAY_VERSION_CODE:?MAGISK_PLAY_VERSION_CODE is required}"
: "${MAGISK_PLAY_AAB_FILE:?MAGISK_PLAY_AAB_FILE is required}"

release_env_file="${MAGISK_RELEASE_ENV_FILE:-play-release-status.env}"
metadata_dir=''
credentials_file=''

# Play publishing is best-effort (the .magisk_android_publish_play template
# sets allow_failure: true), so a non-zero exit must not vanish without a
# trace: record a machine-readable "failed" status unless a status file was
# already written (the review-gate skip and the success path write their own).
write_release_status_failed() {
  local rc=$?
  if [ "$rc" -eq 0 ] || [ -z "$release_env_file" ] || [ -f "$release_env_file" ]; then
    return 0
  fi
  {
    printf 'MAGISK_RELEASE_TRACK=%q\n' "$MAGISK_PLAY_TRACK"
    printf 'MAGISK_RELEASE_VERSION_NAME=%q\n' "$MAGISK_PLAY_VERSION_NAME"
    printf 'MAGISK_RELEASE_VERSION_CODE=%q\n' "$MAGISK_PLAY_VERSION_CODE"
    printf 'MAGISK_RELEASE_STATUS=%q\n' "failed"
    printf 'MAGISK_RELEASE_FAIL_REASON=%q\n' "publish_play.sh exited with status $rc; see the job log for the failing command"
  } > "$release_env_file" 2>/dev/null || true
  return 0
}

cleanup() {
  write_release_status_failed
  if [ -n "$metadata_dir" ]; then
    rm -rf "$metadata_dir"
  fi
  if [ -n "$credentials_file" ]; then
    rm -f "$credentials_file"
  fi
  return 0
}
trap cleanup EXIT

case "$MAGISK_PLAY_TRACK" in
  alpha|beta|internal|production) ;;
  *) echo "ERROR: unsupported Play track: $MAGISK_PLAY_TRACK" >&2; exit 2 ;;
esac
[[ -f "$MAGISK_PLAY_AAB_FILE" ]] || {
  echo "ERROR: Play AAB does not exist: $MAGISK_PLAY_AAB_FILE" >&2
  exit 2
}
case "$MAGISK_PLAY_TRACK" in
  production)
    [[ "$MAGISK_PLAY_VERSION_NAME" != *-alpha.* && "$MAGISK_PLAY_VERSION_NAME" != *-beta.* && "$MAGISK_PLAY_VERSION_NAME" != *-internal.* ]] || {
      echo "ERROR: production release cannot use a prerelease version name: $MAGISK_PLAY_VERSION_NAME" >&2
      exit 2
    }
    ;;
  beta)
    [[ "$MAGISK_PLAY_VERSION_NAME" == *-beta.* ]] || {
      echo "ERROR: beta release must use a beta version name: $MAGISK_PLAY_VERSION_NAME" >&2
      exit 2
    }
    ;;
esac

# Review gate: if resolve_play_release.sh flagged the target track's latest
# release as not live yet (IN_REVIEW / APPROVED_NOT_PUBLISHED lifecycle
# states), skip the upload instead of piling up submissions and pressuring
# Play review. Effective on every track, including production.
if [[ "${MAGISK_PLAY_SKIP_RELEASE:-0}" == "1" ]]; then
  skip_reason="${MAGISK_PLAY_TRACK_STATUS:-unknown}"
  if [[ "$skip_reason" == "PLAY_QUERY_FAILED" ]]; then
    echo "ERROR: Play track status query failed for track '${MAGISK_PLAY_TRACK}'; refusing to publish (fail-closed). Restore Play API access and re-run this job." >&2
  else
    echo "INFO: Play track '${MAGISK_PLAY_TRACK}' latest release not live yet (state='${skip_reason}'); skipping publish to avoid review pile-up." >&2
  fi
  {
    printf 'MAGISK_RELEASE_TRACK=%q\n' "$MAGISK_PLAY_TRACK"
    printf 'MAGISK_RELEASE_VERSION_NAME=%q\n' "$MAGISK_PLAY_VERSION_NAME"
    printf 'MAGISK_RELEASE_VERSION_CODE=%q\n' "$MAGISK_PLAY_VERSION_CODE"
    printf 'MAGISK_RELEASE_STATUS=%q\n' "skipped"
    printf 'MAGISK_RELEASE_SKIP_REASON=%q\n' "${MAGISK_PLAY_TRACK_STATUS:-unknown}"
  } > "$release_env_file"
  exit 0
fi

credentials_file="$(mktemp)"

# Play Store release notes are capped at 500 characters. Alpha builds are
# published on every push to beta, so the changelog must be derived from the
# commits that landed since the last successful pipeline rather than from a
# hand-maintained fastlane file (which only exists at tag time).
#
# Boundary resolution (first hit wins):
#   1. GitLab pipelines API — the SHA of the previous successful pipeline on
#      this branch (CI_JOB_TOKEN authorizes the current project's API).
#   2. CI_COMMIT_BEFORE_SHA — the push range provided by GitLab CI.
#   3. The most recent tag reachable from HEAD.
#   4. A fixed tail (last 20 commits) when none of the above are available.
#
# Only commit subjects (%s, newest first) are used; merge commits are dropped.
# When the joined subjects exceed MAGISK_PLAY_CHANGELOG_MAX (default 480,
# leaving headroom below the 500-character Play limit), the LONGEST subject is
# dropped whole (never truncated) and the remainder is re-evaluated, repeating
# until the result fits. If every subject has been dropped, a fixed placeholder
# is emitted so Play never receives an empty changelog.
build_alpha_changelog() {
  local max_len="${MAGISK_PLAY_CHANGELOG_MAX:-480}"
  local fallback_note="${MAGISK_PLAY_CHANGELOG_FALLBACK:-Internal development build. See commit history for details.}"
  local current_sha="${CI_COMMIT_SHA:-$(git rev-parse HEAD 2>/dev/null || true)}"
  local boundary_sha=''

  # 1. Previous successful pipeline SHA via the pipelines API.
  if [[ -n "${CI_API_V4_URL:-}" && -n "${CI_PROJECT_ID:-}" && -n "${CI_COMMIT_BRANCH:-${CI_COMMIT_REF_NAME:-}}" ]]; then
    local ref="${CI_COMMIT_BRANCH:-${CI_COMMIT_REF_NAME}}"
    local pipelines_json pipelines_status
    local token_header=()
    if [[ -n "${GITLAB_RELEASE_TOKEN:-}" ]]; then
      token_header=(--header "PRIVATE-TOKEN: ${GITLAB_RELEASE_TOKEN}")
    else
      token_header=(--header "JOB-TOKEN: ${CI_JOB_TOKEN:-}")
    fi
    pipelines_json="$(mktemp)"
    pipelines_status="$(curl --silent --show-error --location \
      --get \
      --url "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines" \
      "${token_header[@]}" \
      --data-urlencode "ref=${ref}" \
      --data-urlencode "status=success" \
      --data-urlencode "per_page=20" \
      --data-urlencode "order_by=id" \
      --data-urlencode "sort=desc" \
      --output "$pipelines_json" \
      --write-out '%{http_code}' 2>/dev/null || true)"
    if [[ "$pipelines_status" =~ ^2[0-9][0-9]$ ]]; then
      # First successful pipeline whose SHA differs from the current build.
      boundary_sha="$(python3 - "$pipelines_json" "$current_sha" <<'PY' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
current = sys.argv[2]
for item in data if isinstance(data, list) else []:
    sha = item.get("sha", "")
    if sha and sha != current:
        print(sha)
        break
PY
)"
    fi
    rm -f "$pipelines_json"
  fi

  # 2. Fall back to the push range GitLab CI reports.
  if [[ -z "$boundary_sha" && -n "${CI_COMMIT_BEFORE_SHA:-}" \
        && "${CI_COMMIT_BEFORE_SHA}" != "0000000000000000000000000000000000000000" \
        && "${CI_COMMIT_BEFORE_SHA}" != "$current_sha" ]]; then
    boundary_sha="${CI_COMMIT_BEFORE_SHA}"
  fi

  # 3. Fall back to the most recent tag reachable from HEAD.
  if [[ -z "$boundary_sha" ]]; then
    boundary_sha="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  fi

  # Collect commit subjects (newest first), dropping merge commits.
  local -a subjects=()
  local range
  if [[ -n "$boundary_sha" ]]; then
    range="${boundary_sha}..HEAD"
  else
    range="HEAD~20..HEAD"
  fi
  while IFS= read -r subject; do
    [[ -n "$subject" ]] || continue
    [[ "$subject" =~ ^Merge\ branch ]] && continue
    subjects+=("$subject")
  done < <(git log --no-merges --format='%s' "$range" 2>/dev/null || true)

  # 4. Absolute fallback when no subjects could be collected.
  if [[ ${#subjects[@]} -eq 0 ]]; then
    printf '%s\n' "$fallback_note"
    return
  fi

  # Drop the LONGEST subject (whole, never truncated) and re-evaluate until the
  # joined length fits. Ties go to the oldest among the longest, so recent
  # entries survive longer. When only one subject remains and it still exceeds
  # the limit, drop it too and fall through to the placeholder.
  local candidate
  candidate="$(printf '%s\n' "${subjects[@]}")"
  while [[ ${#candidate} -ge $max_len && ${#subjects[@]} -gt 1 ]]; do
    drop_longest_subject
    candidate="$(printf '%s\n' "${subjects[@]}")"
  done

  if [[ ${#candidate} -lt $max_len ]]; then
    printf '%s\n' "$candidate"
  else
    printf '%s\n' "$fallback_note"
  fi
}

# Remove the longest entry from the subjects array, breaking ties toward the
# oldest (highest index) so the newest commits are retained the longest.
drop_longest_subject() {
  local i best_idx=0 best_len=-1
  for (( i=0; i<${#subjects[@]}; i++ )); do
    local len=${#subjects[i]}
    if (( len > best_len )); then
      best_len=$len
      best_idx=$i
    fi
  done
  unset "subjects[$best_idx]"
  subjects=("${subjects[@]}")
}

stage_repository_metadata() {
  local source_dir=''
  for candidate in "fastlane/metadata/android" "metadata/android"; do
    if [[ -d "$candidate" ]]; then
      source_dir="$candidate"
      break
    fi
  done
  [[ -n "$source_dir" ]] || return 1

  metadata_dir="$(mktemp -d)"
  cp -a "$source_dir/." "$metadata_dir/"

  # The checked-in versionCode may differ from the Play-resolved code used by
  # CI. Stage a matching changelog filename without touching the repository.
  local source_version_code=''
  if [[ -f "gradle/libs.versions.toml" ]]; then
    source_version_code="$(sed -nE 's/^versionCode[[:space:]]*=[[:space:]]*"([0-9]+)"/\1/p' gradle/libs.versions.toml | head -n 1)"
  fi
  if [[ -n "$source_version_code" && "$source_version_code" != "$MAGISK_PLAY_VERSION_CODE" ]]; then
    while IFS= read -r changelog_file; do
      locale_dir="$(dirname "$(dirname "$changelog_file")")"
      source_changelog="$locale_dir/changelogs/$source_version_code.txt"
      target_changelog="$locale_dir/changelogs/$MAGISK_PLAY_VERSION_CODE.txt"
      if [[ -f "$source_changelog" ]]; then
        cp "$source_changelog" "$target_changelog"
      fi
    done < <(find "$metadata_dir" -type f -path '*/changelogs/*.txt' | sort -u)
  fi
}

if [[ "$MAGISK_PLAY_TRACK" == alpha ]]; then
  read_alpha_metadata() {
    local variable_name="$1"
    local file_name="$2"
    local value="${!variable_name:-}"
    if [[ -z "$value" ]]; then
      for metadata_file in \
        "fastlane/metadata/android/en-US/$file_name" \
        "metadata/android/en-US/$file_name"; do
        if [[ -s "$metadata_file" ]]; then
          value="$(<"$metadata_file")"
          break
        fi
      done
    fi
    printf '%s' "$value"
  }

  alpha_title="$(read_alpha_metadata MAGISK_PLAY_TITLE title.txt)"
  alpha_short_description="$(read_alpha_metadata MAGISK_PLAY_SHORT_DESCRIPTION short_description.txt)"
  alpha_full_description="$(read_alpha_metadata MAGISK_PLAY_FULL_DESCRIPTION full_description.txt)"
  : "${alpha_title:?MAGISK_PLAY_TITLE or an en-US title.txt is required for Alpha publishing}"
  : "${alpha_short_description:?MAGISK_PLAY_SHORT_DESCRIPTION or an en-US short_description.txt is required for Alpha publishing}"
  : "${alpha_full_description:?MAGISK_PLAY_FULL_DESCRIPTION or an en-US full_description.txt is required for Alpha publishing}"
  changelog="${MAGISK_PLAY_CHANGELOG:-}"
  if [[ -z "$changelog" ]]; then
    changelog="$(build_alpha_changelog)"
  fi
  if [[ -z "$changelog" ]]; then
    changelog="Development build for ${MAGISK_PLAY_VERSION_NAME}"
  fi
  metadata_dir="$(mktemp -d)"
  # Fastlane treats each direct child of metadata_path as a locale. Keep the
  # temporary Alpha metadata rooted at en-US; `android/` is only used by the
  # repository's fastlane metadata layout.
  mkdir -p "$metadata_dir/en-US/changelogs"
  printf '%s\n' "$alpha_title" > "$metadata_dir/en-US/title.txt"
  printf '%s\n' "$alpha_short_description" > "$metadata_dir/en-US/short_description.txt"
  printf '%s\n' "$alpha_full_description" > "$metadata_dir/en-US/full_description.txt"
  printf '%s\n' "$changelog" > "$metadata_dir/en-US/changelogs/${MAGISK_PLAY_VERSION_CODE}.txt"
elif stage_repository_metadata; then
  :
elif [[ "$MAGISK_PLAY_TRACK" == beta || "$MAGISK_PLAY_TRACK" == production ]]; then
  echo "ERROR: ${MAGISK_PLAY_TRACK} publishing requires fastlane/metadata/android or metadata/android" >&2
  exit 2
fi

chmod 0600 "$credentials_file"
if [[ "$ANDROID_PUBLISHER_CREDENTIALS" == \{* ]]; then
  printf '%s' "$ANDROID_PUBLISHER_CREDENTIALS" > "$credentials_file"
else
  printf '%s' "$ANDROID_PUBLISHER_CREDENTIALS" | base64 --decode > "$credentials_file"
fi

# Fastlane/Ruby require an explicit UTF-8 locale in the slim image.
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export LANGUAGE=C.UTF-8
export FASTLANE_OPT_OUT_USAGE=1
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends build-essential ruby ruby-dev >/dev/null
rm -rf /var/lib/apt/lists/*
gem_user_bin="$(ruby -r rubygems -e 'print Gem.user_dir')/bin"
export PATH="$gem_user_bin:$PATH"
gem install --user-install fastlane --no-document >/dev/null

cmd=(fastlane supply
  --aab "$MAGISK_PLAY_AAB_FILE"
  --package_name "$MAGISK_ANDROID_RELEASE_PACKAGE_NAME"
  --track "$MAGISK_PLAY_TRACK"
  --release_status completed
  --json_key "$credentials_file"
  --skip_upload_images true
  --skip_upload_screenshots true)
if [[ -n "$metadata_dir" ]]; then
  cmd+=(--metadata_path "$metadata_dir" --skip_upload_metadata false)
else
  cmd+=(--skip_upload_metadata true)
fi
if [[ -n "${MAGISK_PLAY_MAPPING_FILE:-}" && -n "${MAGISK_PLAY_SYMBOLS_FILE:-}" ]]; then
  cmd+=(--mapping_paths "${MAGISK_PLAY_MAPPING_FILE},${MAGISK_PLAY_SYMBOLS_FILE}")
elif [[ -n "${MAGISK_PLAY_MAPPING_FILE:-}" ]]; then
  cmd+=(--mapping "${MAGISK_PLAY_MAPPING_FILE}")
elif [[ -n "${MAGISK_PLAY_SYMBOLS_FILE:-}" ]]; then
  cmd+=(--mapping_paths "$MAGISK_PLAY_SYMBOLS_FILE")
fi
FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_DISABLE_COLORS=1 FASTLANE_OPT_OUT_USAGE=1 CI=true "${cmd[@]}"

if [[ -n "$release_env_file" ]]; then
  {
    printf 'MAGISK_RELEASE_TRACK=%q\n' "$MAGISK_PLAY_TRACK"
    printf 'MAGISK_RELEASE_VERSION_NAME=%q\n' "$MAGISK_PLAY_VERSION_NAME"
    printf 'MAGISK_RELEASE_VERSION_CODE=%q\n' "$MAGISK_PLAY_VERSION_CODE"
    printf 'MAGISK_RELEASE_STATUS=published\n'
  } > "$release_env_file"
fi
