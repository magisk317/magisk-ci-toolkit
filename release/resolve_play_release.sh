#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: resolve_play_release.sh --package-name PACKAGE --version-file FILE --output FILE [--initial-version-code CODE]
EOF
  exit 2
}

package_name=''
version_file=''
output_file=''
initial_version_code=0
while (($#)); do
  case "$1" in
    --package-name) package_name="$2"; shift 2 ;;
    --version-file) version_file="$2"; shift 2 ;;
    --output) output_file="$2"; shift 2 ;;
    --initial-version-code) initial_version_code="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$package_name" && -f "$version_file" && -n "$output_file" ]] || usage
[[ "$initial_version_code" =~ ^[0-9]+$ ]] || { echo "ERROR: invalid initial version code" >&2; exit 2; }

version_name="$(python3 - "$version_file" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r'^versionName\s*=\s*"([^"]+)"', text, re.MULTILINE)
if not match:
    raise SystemExit("versionName is missing")
print(match.group(1).removeprefix("v"))
PY
)"

tag="${CI_COMMIT_TAG:-}"
if [[ -z "$tag" && "${GITHUB_REF_TYPE:-}" == tag ]]; then
  tag="${GITHUB_REF_NAME:-}"
fi
track_override="${MAGISK_PLAY_TRACK_OVERRIDE:-}"
if [[ -n "$track_override" ]]; then
  case "$track_override" in
    alpha|beta|internal|production) track="$track_override" ;;
    *) echo "ERROR: unsupported Play track override: $track_override" >&2; exit 1 ;;
  esac
elif [[ -n "$tag" ]]; then
  if [[ "$tag" == *beta* ]]; then
    track=beta
  elif [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    track=production
  else
    echo "ERROR: unsupported release tag: $tag" >&2
    exit 1
  fi
elif [[ "${CI_COMMIT_BRANCH:-${GITHUB_REF_NAME:-}}" == beta ]]; then
  track=alpha
else
  echo "ERROR: Play release requires beta branch or a supported version tag" >&2
  exit 1
fi

ci_number="${CI_PIPELINE_IID:-${GITHUB_RUN_NUMBER:-}}"
if [[ "$track" != production ]]; then
  [[ "$ci_number" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: CI pipeline number is required for $track" >&2; exit 1; }
  version_name="${version_name}-${track}.${ci_number}"
fi

commit_count="$(git rev-list --first-parent --count HEAD 2>/dev/null || printf '0')"
[[ "$commit_count" =~ ^[0-9]+$ ]] || commit_count=0
fallback_code=$((commit_count + 1))
if (( initial_version_code > 0 && fallback_code <= initial_version_code )); then
  fallback_code=$((initial_version_code + 1))
fi

play_max=''
track_status=''
play_query_status=unavailable
if [[ -n "${ANDROID_PUBLISHER_CREDENTIALS:-}" ]]; then
  credentials_file="$(mktemp)"
  key_file="$(mktemp)"
  token_response="$(mktemp)"
  api_response="$(mktemp)"
  cleanup() { rm -f "$credentials_file" "$key_file" "$token_response" "$api_response"; }
  trap cleanup EXIT
  if [[ "$ANDROID_PUBLISHER_CREDENTIALS" == \{* ]]; then
    printf '%s' "$ANDROID_PUBLISHER_CREDENTIALS" > "$credentials_file"
  else
    printf '%s' "$ANDROID_PUBLISHER_CREDENTIALS" | base64 --decode > "$credentials_file" 2>/dev/null || true
  fi
  if python3 - "$credentials_file" "$key_file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
open(sys.argv[2], "w", encoding="utf-8").write(data["private_key"])
print(data["client_email"])
PY
  then
    client_email="$(python3 - "$credentials_file" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["client_email"])
PY
)"
    now="$(date +%s)"
    jwt_header='{"alg":"RS256","typ":"JWT"}'
    jwt_claims="{\"iss\":\"$client_email\",\"scope\":\"https://www.googleapis.com/auth/androidpublisher\",\"aud\":\"https://oauth2.googleapis.com/token\",\"iat\":$now,\"exp\":$((now + 3600))}"
    b64() { printf '%s' "$1" | openssl base64 -A | tr '+/' '-_' | tr -d '='; }
    unsigned="$(b64 "$jwt_header").$(b64 "$jwt_claims")"
    signature="$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$key_file" | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
    token_status="$(curl -sS --retry 2 -X POST \
      -o "$token_response" -w '%{http_code}' https://oauth2.googleapis.com/token \
      -d grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \
      --data-urlencode assertion="${unsigned}.${signature}")" || token_status=000
    access_token=''
    if [[ "$token_status" =~ ^2[0-9][0-9]$ ]]; then
      access_token="$(python3 - "$token_response" <<'PY' 2>/dev/null || true
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["access_token"])
PY
)"
    else
      echo "WARN: Play OAuth token request returned HTTP $token_status" >&2
    fi
    if [[ -n "$access_token" ]]; then
      api_root="https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${package_name}/edits"
      edit_status="$(curl -sS --retry 2 -X POST \
        -o "$api_response" -w '%{http_code}' \
        -H "Authorization: Bearer $access_token" -H 'Content-Type: application/json' \
        -d '{}' "$api_root")" || edit_status=000
      edit_id=''
      if [[ "$edit_status" =~ ^2[0-9][0-9]$ ]]; then
        edit_id="$(python3 - "$api_response" <<'PY' 2>/dev/null || true
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["id"])
PY
)"
      else
        echo "WARN: Play edits API returned HTTP $edit_status for $package_name; check Play Console app access for the service account" >&2
      fi
      if [[ -n "$edit_id" ]]; then
        tracks_status="$(curl -sS --retry 2 -H "Authorization: Bearer $access_token" \
          -o "$api_response" -w '%{http_code}' "$api_root/$edit_id/tracks")" || tracks_status=000
        tracks_json=''
        if [[ "$tracks_status" =~ ^2[0-9][0-9]$ ]]; then
          tracks_json="$(cat "$api_response")"
        else
          echo "WARN: Play tracks API returned HTTP $tracks_status for $package_name" >&2
        fi
        curl -fsS -X DELETE -H "Authorization: Bearer $access_token" "$api_root/$edit_id" >/dev/null 2>&1 || true
        if [[ -n "$tracks_json" ]]; then
          play_max="$(printf '%s' "$tracks_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); v=[int(x) for t in d.get("tracks",[]) for r in t.get("releases",[]) for x in r.get("versionCodes",[])]; print(max(v) if v else "")')"
          play_query_status=success
        fi
      fi
      # Resolve the real review lifecycle of the target track's latest release
      # via the read-only per-track releases endpoint. The legacy edits->tracks
      # listing only echoes the configured release_status: a submission made
      # with release_status=completed keeps reporting "completed" while it is
      # still in review (or waiting in a managed publishing queue), so it can
      # never gate anything. This endpoint exposes releaseLifecycleState
      # (IN_REVIEW / APPROVED_NOT_PUBLISHED / PUBLISHED / ...), which is the
      # source of truth for "has the previous release gone live yet?".
      # The endpoint occasionally returns a transient empty {} body; retry.
      releases_url="https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${package_name}/tracks/${track}/releases"
      releases_json=''
      for _attempt in 1 2 3; do
        releases_status="$(curl -sS --retry 2 -H "Authorization: Bearer $access_token" \
          -o "$api_response" -w '%{http_code}' "$releases_url")" || releases_status=000
        if [[ "$releases_status" =~ ^2[0-9][0-9]$ ]]; then
          releases_json="$(cat "$api_response")"
          if printf '%s' "$releases_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if isinstance(d,dict) and "releases" in d else 1)' 2>/dev/null; then
            break
          fi
          echo "WARN: Play releases API returned an incomplete body (attempt $_attempt/3) for $package_name track $track" >&2
          releases_json=''
          sleep 2
        else
          echo "WARN: Play releases API returned HTTP $releases_status for $package_name track $track" >&2
          releases_json=''
          break
        fi
      done
      if [[ -n "$releases_json" ]]; then
        track_status="$(printf '%s' "$releases_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
best_status = ""
best_vc = -1
for r in d.get("releases", []) or []:
    vcs = [a.get("versionCode") for a in (r.get("activeArtifacts") or []) if isinstance(a.get("versionCode"), int)]
    mx = max(vcs) if vcs else 0
    if mx > best_vc:
        best_vc = mx
        best_status = r.get("releaseLifecycleState", "")
print(best_status.removeprefix("RELEASE_LIFECYCLE_STATE_") if best_status else "")
')"
      fi
    fi
  fi
fi

if [[ "$play_query_status" == success ]]; then
  if [[ -n "$play_max" ]]; then
    version_code=$((play_max + 1))
  else
    version_code=$((initial_version_code + 1))
  fi
  if (( version_code < ${ci_number:-0} )); then version_code="$ci_number"; fi
  if (( version_code == 0 )); then version_code=1; fi
else
  version_code="$fallback_code"
  echo "WARN: Play version query unavailable for $package_name; using fallback versionCode=$version_code" >&2
fi

# Review gate, effective on every Play track (beta, production, alpha, ...).
# If the latest release on the target track has not gone live yet — it is
# still in review (IN_REVIEW) or approved but waiting for a managed publish
# (APPROVED_NOT_PUBLISHED) — flag the publish step to skip so we don't pile
# up submissions and pressure Play review. Rejected releases (NOT_APPROVED)
# and fully live releases (PUBLISHED) do not block. Override the matched
# states via MAGISK_PLAY_SKIP_STATUSES if needed.
skip_statuses="${MAGISK_PLAY_SKIP_STATUSES:-IN_REVIEW APPROVED_NOT_PUBLISHED}"
play_skip_release=0
if [[ -n "$track_status" && " $skip_statuses " == *" $track_status "* ]]; then
  play_skip_release=1
elif [[ "$play_query_status" != success ]]; then
  # Fail closed: an unresolved track status (Play API unreachable, service
  # account rejected, transient empty bodies exhausted) must never fall
  # through to a blind upload. A skipped publish is recoverable by re-running
  # the job; publishing during an API outage is not -- it can duplicate
  # submissions or resurrect a stale versionCode.
  track_status="PLAY_QUERY_FAILED"
  play_skip_release=1
  echo "ERROR: Play track status could not be resolved for $package_name track $track (query=${play_query_status}); refusing to publish (fail-closed)." >&2
fi

mkdir -p "$(dirname "$output_file")"
{
  printf 'MAGISK_PLAY_TRACK=%q\n' "$track"
  printf 'MAGISK_PLAY_VERSION_NAME=%q\n' "$version_name"
  printf 'MAGISK_PLAY_VERSION_CODE=%q\n' "$version_code"
  printf 'MAGISK_PLAY_QUERY_STATUS=%q\n' "$play_query_status"
  printf 'MAGISK_PLAY_TRACK_STATUS=%q\n' "$track_status"
  printf 'MAGISK_PLAY_SKIP_RELEASE=%q\n' "$play_skip_release"
} > "$output_file"
printf 'Resolved Play release: track=%s versionName=%s versionCode=%s query=%s trackStatus=%s skipRelease=%s\n' "$track" "$version_name" "$version_code" "$play_query_status" "$track_status" "$play_skip_release"
