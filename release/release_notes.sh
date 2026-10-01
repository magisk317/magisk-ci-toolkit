#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  release_notes.sh --tag <tag> --package-name <android-package> --output <file> [options]

Options:
  --changelog <file>           Changelog file. Default: docs/CHANGELOG.md
  --source-repo <owner/repo>   GitHub source repository for badge and generated notes.
  --play-url <url>             Canonical Google Play listing URL.
  --no-play-link               Omit the Google Play badge.
  --gitlab-project-url <url>   GitLab project URL for the GitLab release badge.
  --generate-github-notes      Append GitHub generated release notes when gh is available.
EOF
}

tag_name=""
package_name=""
output_file=""
changelog_file="docs/CHANGELOG.md"
source_repo=""
play_url=""
show_play_link="true"
gitlab_project_url=""
generate_github_notes="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      tag_name="${2:-}"
      shift 2
      ;;
    --package-name)
      package_name="${2:-}"
      shift 2
      ;;
    --output)
      output_file="${2:-}"
      shift 2
      ;;
    --changelog)
      changelog_file="${2:-}"
      shift 2
      ;;
    --source-repo)
      source_repo="${2:-}"
      shift 2
      ;;
    --play-url)
      play_url="${2:-}"
      shift 2
      ;;
    --no-play-link)
      show_play_link="false"
      shift
      ;;
    --gitlab-project-url)
      gitlab_project_url="${2:-}"
      shift 2
      ;;
    --generate-github-notes)
      generate_github_notes="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$tag_name" || -z "$package_name" || -z "$output_file" ]]; then
  usage
  exit 2
fi
if [[ ! -f "$changelog_file" ]]; then
  echo "ERROR: changelog not found: $changelog_file" >&2
  exit 1
fi

release_name="$tag_name"
notes_dir="$(dirname "$output_file")"
mkdir -p "$notes_dir"
changelog_extract="$(mktemp)"
trap 'rm -f "$changelog_extract"' EXIT

if [[ -z "$play_url" ]]; then
  play_url="https://play.google.com/store/apps/details?id=${package_name}"
fi

cat > "$output_file" <<'EOF'
<div align="center">
EOF
# Every channel badge comes from the same shields.io "for-the-badge" family so
# the row renders at one uniform height; the official Google Play PNG is a
# different aspect ratio and made the GitLab badge look undersized next to it.
badge_height="28"
if [[ "$show_play_link" == "true" ]]; then
  cat >> "$output_file" <<EOF
  <a href="${play_url}">
    <img src="https://img.shields.io/badge/Get%20it%20on-Google%20Play-01875F?style=for-the-badge&logo=googleplay&logoColor=white" alt="Get it on Google Play" height="${badge_height}"/>
  </a>
EOF
fi
if [[ -n "$gitlab_project_url" ]]; then
  gitlab_project_url="${gitlab_project_url%/}"
  cat >> "$output_file" <<EOF
  <a href="${gitlab_project_url}/-/releases/${tag_name}">
    <img src="https://img.shields.io/badge/Get%20it%20on-GitLab-FC6D26?style=for-the-badge&logo=gitlab&logoColor=white" alt="Get it on GitLab" height="${badge_height}"/>
  </a>
EOF
fi
if [[ -n "$source_repo" ]]; then
  cat >> "$output_file" <<EOF
  <a href="https://github.com/${source_repo}/releases/tag/${tag_name}">
    <img src="https://img.shields.io/badge/Get%20it%20on-GitHub-181717?style=for-the-badge&logo=github&logoColor=white" alt="Get it on GitHub" height="${badge_height}"/>
  </a>
EOF
fi
cat >> "$output_file" <<'EOF'
</div>

EOF

if ! awk -v version="$release_name" '
  $0 == "---" && found { exit }
  found { print; next }
  index($0, "## [" version "]") == 1 { found = 1; print; next }
  END { if (!found) exit 1 }
' "$changelog_file" > "$changelog_extract"; then
  echo "ERROR: no changelog entry for $release_name in $changelog_file" >&2
  exit 1
fi

# Without a trailing "---" the extract keeps going and the notes end up
# carrying every older release entry, so refuse to build them.
heading_count="$(grep -c '^## \[' "$changelog_extract" || true)"
if [[ "${heading_count:-0}" -gt 1 ]]; then
  echo "ERROR: the $release_name entry in $changelog_file is not closed by a '---' separator." >&2
  echo "       The release notes would also carry $((heading_count - 1)) older entry/entries:" >&2
  grep -n '^## \[' "$changelog_extract" | sed 's/^/       /' >&2
  echo "       Add the separator after the entry (before the next '## [vX.Y.Z]' heading)." >&2
  exit 1
fi

generated_notes=""
if [[ "$generate_github_notes" == "true" && -n "$source_repo" ]] && command -v gh >/dev/null 2>&1; then
  previous_tag=""
  compare_range="$(sed -nE 's#.*compare/([^[:space:]]+)\.\.\.([^[:space:]]+).*#\1 \2#p' "$changelog_extract" | head -n 1)"
  if [[ -n "$compare_range" ]]; then
    read -r previous_tag compare_to <<< "$compare_range"
    if [[ "$compare_to" != "$tag_name" ]]; then
      previous_tag=""
    fi
  fi
  if [[ -z "$previous_tag" ]]; then
    previous_tag="$(git describe --tags --abbrev=0 "${tag_name}^{commit}^" 2>/dev/null || true)"
  fi
  generate_args=(-X POST -f "tag_name=${tag_name}")
  if [[ -n "$previous_tag" ]]; then
    generate_args+=(-f "previous_tag_name=${previous_tag}")
  fi
  generated_notes="$(gh api "repos/${source_repo}/releases/generate-notes" \
    "${generate_args[@]}" \
    --jq '.body' 2>/dev/null || true)"
  if [[ -n "$generated_notes" ]]; then
    sed -i '/^[[:space:]]*>[[:space:]]*Full Changelog:/d' "$changelog_extract"
  fi
fi

cat "$changelog_extract" >> "$output_file"
if [[ -n "$generated_notes" ]]; then
  printf '\n%s\n' "$generated_notes" >> "$output_file"
fi
if [[ ! -s "$output_file" ]]; then
  echo "ERROR: generated release notes are empty: $output_file" >&2
  exit 1
fi
