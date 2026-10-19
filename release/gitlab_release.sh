#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../ci/gitlab_api.sh"

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

json_escape_file() {
  python3 - "$@" <<'PY'
import json
import sys
from pathlib import Path

print(json.dumps(Path(sys.argv[1]).read_text()))
PY
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: $name is required" >&2
    exit 2
  fi
}

gitlab_curl() { gitlab_api_curl_url "$@"; }

require_env CI_API_V4_URL
require_env CI_PROJECT_ID
require_env CI_PROJECT_URL
require_env CI_COMMIT_TAG
if [[ -z "${CI_JOB_TOKEN:-}" && -z "${GITLAB_RELEASE_TOKEN:-}" && -z "${GITLAB_TOKEN:-}" && -z "${GITLAB_DEPLOY_TOKEN:-}" ]]; then
  echo "ERROR: a GitLab token is required" >&2
  exit 2
fi

notes_file="${MAGISK_RELEASE_NOTES_FILE:-release-notes.md}"
package_name="${MAGISK_GITLAB_RELEASE_PACKAGE_NAME:-android-release}"
asset_dir="${MAGISK_GITLAB_RELEASE_ASSET_DIR:-release-assets}"
prepared_asset_dir="${MAGISK_GITLAB_RELEASE_PREPARED_ASSET_DIR:-}"
direct_asset_prefix="${MAGISK_GITLAB_RELEASE_DIRECT_ASSET_PREFIX:-/android}"
tag_name="$CI_COMMIT_TAG"
release_name="${MAGISK_RELEASE_NAME:-$tag_name}"
dry_run="${MAGISK_RELEASE_DRY_RUN:-false}"
verify_public_downloads="${MAGISK_GITLAB_RELEASE_VERIFY_PUBLIC_DOWNLOADS:-true}"

if [[ ! -f "$notes_file" ]]; then
  echo "ERROR: release notes file not found: $notes_file" >&2
  exit 1
fi

if [[ -n "$prepared_asset_dir" ]]; then
  asset_dir="$prepared_asset_dir"
  if [[ ! -d "$asset_dir" ]] || ! find "$asset_dir" -maxdepth 1 -type f -print -quit | grep -q .; then
    echo "ERROR: prepared release asset directory is empty or missing: $asset_dir" >&2
    exit 1
  fi
else
  rm -rf "$asset_dir"
  mkdir -p "$asset_dir"

  mapfile -t source_files < <(
    find app/build/outputs/apk \
         app/build/outputs/bundle \
         app/build/outputs/mapping \
         app/build/outputs/native-debug-symbols \
         -type f \( -name '*.apk' -o -name '*.aab' -o -name 'mapping.txt' -o -name 'native-debug-symbols.zip' \) \
         2>/dev/null | sort
  )
  if [[ ${#source_files[@]} -eq 0 ]]; then
    echo "ERROR: no release files found under app/build/outputs" >&2
    exit 1
  fi

  declare -A used_names=()
  for source_file in "${source_files[@]}"; do
    base_name="$(basename "$source_file")"
    asset_name="$base_name"
    if [[ -n "${used_names[$asset_name]:-}" ]]; then
      prefix="$(dirname "$source_file" | tr '/[:space:]' '__')"
      asset_name="${prefix}_${base_name}"
    fi
    used_names[$asset_name]=1
    cp "$source_file" "$asset_dir/$asset_name"
  done
fi

direct_asset_prefix="/${direct_asset_prefix#/}"
direct_asset_prefix="${direct_asset_prefix%/}"

encoded_project="$(urlencode "$CI_PROJECT_ID")"
encoded_tag="$(urlencode "$tag_name")"
encoded_package="$(urlencode "$package_name")"
links_json="$(mktemp)"
payload_json="$(mktemp)"
update_json="$(mktemp)"
existing_links_json="$(mktemp)"
trap 'rm -f "$links_json" "$payload_json" "$update_json" "$existing_links_json"' EXIT

printf '[\n' > "$links_json"
first_link="true"
for asset_path in "$asset_dir"/*; do
  asset_name="$(basename "$asset_path")"
  encoded_asset="$(urlencode "$asset_name")"
  package_url="${CI_API_V4_URL}/projects/${encoded_project}/packages/generic/${encoded_package}/${encoded_tag}/${encoded_asset}"
  # The web package route redirects anonymous users to sign-in even for public
  # projects. Use the API route so release assets remain directly downloadable.
  download_url="${CI_API_V4_URL}/projects/${encoded_project}/packages/generic/${encoded_package}/${encoded_tag}/${encoded_asset}"

  if [[ "$dry_run" == "true" ]]; then
    echo "DRY-RUN upload $asset_path -> $package_url"
  else
    upload_status="$(
      gitlab_curl --output /tmp/gitlab-package-upload.json --write-out "%{http_code}" \
        --request PUT \
        --upload-file "$asset_path" \
        "$package_url" || true
    )"
    case "$upload_status" in
      200|201|409) ;;
      400)
        if ! grep -qiE 'already|taken|exist' /tmp/gitlab-package-upload.json; then
          echo "ERROR: failed to upload $asset_name (HTTP $upload_status)" >&2
          cat /tmp/gitlab-package-upload.json >&2 || true
          exit 1
        fi
        ;;
      *)
        echo "ERROR: failed to upload $asset_name (HTTP $upload_status)" >&2
        cat /tmp/gitlab-package-upload.json >&2 || true
        exit 1
        ;;
    esac
  fi

  if [[ "$first_link" != "true" ]]; then
    printf ',\n' >> "$links_json"
  fi
  first_link="false"
  python3 - "$asset_name" "$download_url" "${direct_asset_prefix}/${asset_name}" >> "$links_json" <<'PY'
import json
import sys

name, url, direct_asset_path = sys.argv[1:4]
print(json.dumps({
    "name": name,
    "url": url,
    "direct_asset_path": direct_asset_path,
    "link_type": "package",
}))
PY
done
printf '\n]\n' >> "$links_json"

python3 - "$release_name" "$tag_name" "$notes_file" "$links_json" > "$payload_json" <<'PY'
import json
import sys
from pathlib import Path

release_name, tag_name, notes_file, links_file = sys.argv[1:5]
payload = {
    "name": release_name,
    "tag_name": tag_name,
    "description": Path(notes_file).read_text(),
    "assets": {
        "links": json.loads(Path(links_file).read_text()),
    },
}
print(json.dumps(payload))
PY

python3 - "$release_name" "$notes_file" > "$update_json" <<'PY'
import json
import sys
from pathlib import Path

release_name, notes_file = sys.argv[1:3]
print(json.dumps({
    "name": release_name,
    "description": Path(notes_file).read_text(),
}))
PY

release_url="${CI_API_V4_URL}/projects/${encoded_project}/releases/${encoded_tag}"
create_url="${CI_API_V4_URL}/projects/${encoded_project}/releases"

if [[ "$dry_run" == "true" ]]; then
  echo "DRY-RUN release payload:"
  cat "$payload_json"
  exit 0
fi

status="$(gitlab_curl --output /tmp/gitlab-release-get.json --write-out "%{http_code}" "$release_url" || true)"
case "$status" in
  200)
    gitlab_curl --fail \
      --request PUT \
      --header "Content-Type: application/json" \
      --data @"$update_json" \
      "$release_url" >/dev/null
    links_url="${release_url}/assets/links"
    gitlab_curl --fail "$links_url" > "$existing_links_json"
    python3 - "$links_json" > /tmp/gitlab-release-links.tsv <<'PY'
import json
import sys
from pathlib import Path

for link in json.loads(Path(sys.argv[1]).read_text()):
    print("\t".join([link["name"], link["url"], link["direct_asset_path"], link["link_type"]]))
PY
    while IFS=$'\t' read -r link_name link_url direct_asset_path link_type; do
      link_id="$(python3 - "$existing_links_json" "$link_name" <<'PY'
import json
import sys
from pathlib import Path

name = sys.argv[2]
for link in json.loads(Path(sys.argv[1]).read_text()):
    if link.get("name") == name:
        print(link["id"])
        break
PY
)"
      if [[ -n "$link_id" ]]; then
        link_method="PUT"
        link_endpoint="${links_url}/${link_id}"
      else
        link_method="POST"
        link_endpoint="$links_url"
      fi
      link_status="$(
        gitlab_curl --output /tmp/gitlab-release-link.json --write-out "%{http_code}" \
          --request "$link_method" \
          --data-urlencode "name=${link_name}" \
          --data-urlencode "url=${link_url}" \
          --data-urlencode "direct_asset_path=${direct_asset_path}" \
          --data "link_type=${link_type}" \
          "$link_endpoint" || true
      )"
      case "$link_status" in
        200|201) ;;
        *)
          echo "ERROR: failed to update release link $link_name (HTTP $link_status)" >&2
          cat /tmp/gitlab-release-link.json >&2 || true
          exit 1
          ;;
      esac
    done < /tmp/gitlab-release-links.tsv
    ;;
  404)
    gitlab_curl --fail \
      --request POST \
      --header "Content-Type: application/json" \
      --data @"$payload_json" \
      "$create_url" >/dev/null
    ;;
  *)
    echo "ERROR: failed to inspect GitLab release $tag_name (HTTP $status)" >&2
    cat /tmp/gitlab-release-get.json >&2 || true
    exit 1
    ;;
esac

if [[ "$verify_public_downloads" == "true" ]]; then
  python3 - "$links_json" <<'PY' | while IFS= read -r download_url; do
import json
import sys
from pathlib import Path

for link in json.loads(Path(sys.argv[1]).read_text()):
    print(link["url"])
PY
    for attempt in 1 2 3; do
      if curl --fail --silent --show-error --location --head --max-time 30 "$download_url" >/dev/null; then
        break
      fi
      if [ "$attempt" -eq 3 ]; then
        echo "ERROR: release asset is not publicly downloadable after 3 attempts: $download_url" >&2
        exit 1
      fi
      echo "WARNING: download verify attempt $attempt failed for $download_url; retrying in 5s..." >&2
      sleep 5
    done
  done
fi

echo "Published GitLab release: $tag_name"

# Best-effort sync release to mobile-apps-site backend (D1)
if [[ -n "${MAGISK_ENTITLEMENT_SYNC_URL:-}" && -n "${MAGISK_ENTITLEMENT_SYNC_SECRET:-}" ]]; then
  app_id="${MAGISK_ENTITLEMENT_APP_ID:-}"
  version_code="${MAGISK_RELEASE_VERSION_CODE:-}"
  version_name="${MAGISK_RELEASE_VERSION_NAME:-$tag_name}"
  if [[ -z "$version_code" && -f "play-release.env" ]]; then
    version_code="$(grep '^MAGISK_PLAY_VERSION_CODE=' play-release.env | cut -d= -f2 | tr -d "'\"" || true)"
  fi
  if [[ -n "$app_id" && -n "$version_code" ]]; then
    curl --silent --show-error --max-time 15 \
      --request POST \
      --header "Content-Type: application/json" \
      --header "X-Release-Sync-Secret: ${MAGISK_ENTITLEMENT_SYNC_SECRET}" \
      --data "{\"app_id\":\"${app_id}\",\"channel\":\"sideload\",\"version_code\":${version_code},\"version_name\":\"${version_name}\",\"min_supported_version_code\":${version_code}}" \
      "${MAGISK_ENTITLEMENT_SYNC_URL}/admin/releases/sync" -w '\n[release-sync] HTTP %{http_code}\n' -o /dev/null || echo '[release-sync] request failed (non-fatal)'
  fi
fi
