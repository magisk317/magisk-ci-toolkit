#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
controller_script="$(cd "$script_dir/.." && pwd)/cancel_older_renovate_pipelines.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf -- "$tmp_root"' EXIT

mock_bin="$tmp_root/bin"
mkdir -p "$mock_bin"

# Keep the project added for the UI consumer covered by the same allowlist
# used by the production controller.
# shellcheck disable=SC1091
source "$(cd "$script_dir/.." && pwd)/trusted_projects.sh"
[[ "$(trusted_project_id "magisk3171/napgram-ecosystem/napgram-ui-dist")" == "84583731" ]] || exit 1
[[ "$(trusted_target_branch "magisk3171/napgram-ecosystem/napgram-ui-dist")" == "beta" ]] || exit 1
for trusted_path in \
  magisk3171/MiPushFramework \
  magisk3171/XposedSmsCode \
  magisk3171/xinyi-relay \
  magisk3171/napgram-ecosystem/NapGram \
  magisk3171/napgram-ecosystem/napgram-ui-dist \
  magisk3171/SerialBridge \
  magisk3171/MiPushZygisk \
  magisk3171/MiPushConfigurations \
  magisk3171/napgram-ecosystem/NapLink \
  magisk3171/android-host-tools-arm64; do
  [[ "$(trusted_target_branch "$trusted_path")" == "beta" ]] || exit 1
done

cat >"$mock_bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail

output_file=""
method="GET"
url=""
while (($# > 0)); do
  case "$1" in
    --output)
      output_file="$2"
      shift 2
      ;;
    --request)
      method="$2"
      shift 2
      ;;
    --data-urlencode | --header)
      shift 2
      ;;
    --get | --fail | --silent | --show-error | --location)
      shift
      ;;
    http://* | https://*)
      url="$1"
      shift
      ;;
    *)
      echo "mock curl: unsupported argument $1" >&2
      exit 64
      ;;
  esac
done

[[ -n "$output_file" ]] || {
  echo "mock curl: --output is required" >&2
  exit 64
}

if [[ "$method" == "GET" && "$url" == */pipelines/9000 ]]; then
  jq -n '{id:9000,iid:90,project_id:83955143,source:"schedule",ref:"beta",created_at:"2026-01-01T00:00:10Z"}' >"$output_file"
  exit 0
fi

if [[ "$method" == "GET" && "$url" =~ /pipelines/([0-9]+)/jobs$ ]]; then
  pipeline_id="${BASH_REMATCH[1]}"
  if [[ "$pipeline_id" == "8998" || "$pipeline_id" == "8999" || "$pipeline_id" == "9000" || "$pipeline_id" == "9001" ]]; then
    jq -n '[{name:"renovate:gitlab"}]' >"$output_file"
  else
    jq -n '[{name:"android:build"}]' >"$output_file"
  fi
  exit 0
fi

if [[ "$method" == "GET" && "$url" == */pipelines ]]; then
  jq --slurpfile canceled "$MOCK_CANCELED_FILE" '
    map(. as $pipeline | if ($canceled[0] | index($pipeline.id)) != null then .status = "canceled" else . end)
  ' "$MOCK_PIPELINES_FILE" >"$output_file"
  exit 0
fi

if [[ "$method" == "POST" && "$url" =~ /pipelines/([0-9]+)/cancel$ ]]; then
  pipeline_id="${BASH_REMATCH[1]}"
  jq --argjson id "$pipeline_id" '. + [$id] | unique' "$MOCK_CANCELED_FILE" >"$MOCK_CANCELED_FILE.tmp"
  mv "$MOCK_CANCELED_FILE.tmp" "$MOCK_CANCELED_FILE"
  jq -n --argjson id "$pipeline_id" '{id:$id,status:"canceled"}' >"$output_file"
  exit 0
fi

echo "mock curl: unsupported request ${method} ${url}" >&2
exit 64
MOCK_CURL
chmod +x "$mock_bin/curl"

start_case() {
  local name="$1"
  local case_dir="$tmp_root/$name"
  mkdir -p "$case_dir"
  printf '[]\n' >"$case_dir/canceled.json"
  case "$name" in
    older)
      jq -n '[
        {id:9000,source:"schedule",ref:"beta",status:"running",created_at:"2026-01-01T00:00:10Z"},
        {id:8999,source:"schedule",ref:"beta",status:"running",created_at:"2026-01-01T00:00:09Z"},
        {id:8998,source:"schedule",ref:"beta",status:"running",created_at:"2026-01-01T00:00:08Z"},
        {id:8996,source:"schedule",ref:"beta",status:"running",created_at:"2026-01-01T00:00:06Z"},
        {id:8997,source:"push",ref:"beta",status:"running",created_at:"2026-01-01T00:00:07Z"}
      ]' >"$case_dir/pipelines.json"
      ;;
    newer)
      jq -n '[
        {id:9001,source:"schedule",ref:"beta",status:"running",created_at:"2026-01-01T00:00:11Z"},
        {id:9000,source:"schedule",ref:"beta",status:"running",created_at:"2026-01-01T00:00:10Z"}
      ]' >"$case_dir/pipelines.json"
      ;;
  esac

  set +e
  env \
    PATH="$mock_bin:$PATH" \
    MOCK_PIPELINES_FILE="$case_dir/pipelines.json" \
    MOCK_CANCELED_FILE="$case_dir/canceled.json" \
    CI_API_V4_URL="https://gitlab.example/api/v4" \
    CI_PROJECT_ID="83955109" \
    CI_PROJECT_PATH="magisk3171/shared/magisk-ci-toolkit" \
    CI_PIPELINE_ID="9000" \
    CI_PIPELINE_IID="42" \
    CI_PIPELINE_SOURCE="pipeline" \
    CI_COMMIT_REF_NAME="main" \
    CI_DEFAULT_BRANCH="main" \
    CI_COMMIT_REF_PROTECTED="true" \
    MAGISK_CI_PIPELINE_CONTROL_TOKEN="test-token" \
    MAGISK_UPSTREAM_PROJECT_ID="83955143" \
    MAGISK_UPSTREAM_PROJECT_PATH="magisk3171/MiPushFramework" \
    MAGISK_UPSTREAM_PIPELINE_ID="9000" \
    MAGISK_UPSTREAM_PIPELINE_IID="90" \
    MAGISK_UPSTREAM_PIPELINE_SOURCE="schedule" \
    MAGISK_UPSTREAM_REF="beta" \
    MAGISK_CI_PIPELINE_PAGE_SIZE="100" \
    MAGISK_CI_PIPELINE_MAX_PAGES="2" \
    MAGISK_CI_PIPELINE_RECONCILE_PASSES="2" \
    MAGISK_CI_PIPELINE_RECONCILE_DELAY_SECONDS="0" \
    bash "$controller_script" >"$case_dir/output.log" 2>&1
  run_status=$?
  set -e
  printf '%s\n' "$run_status" >"$case_dir/status"
}

start_case older
[[ "$(cat "$tmp_root/older/status")" == "0" ]] || {
  cat "$tmp_root/older/output.log" >&2
  exit 1
}
jq -e '. == [8998,8999]' "$tmp_root/older/canceled.json" >/dev/null || {
  cat "$tmp_root/older/output.log" >&2
  cat "$tmp_root/older/canceled.json" >&2
  exit 1
}
grep -F "older Renovate pipeline 8999" "$tmp_root/older/output.log" >/dev/null
if grep -F "android:build" "$tmp_root/older/output.log" >/dev/null; then
  echo "ordinary pipelines must not be inspected as Renovate pipelines" >&2
  exit 1
fi

start_case newer
[[ "$(cat "$tmp_root/newer/status")" == "0" ]] || {
  cat "$tmp_root/newer/output.log" >&2
  exit 1
}
jq -e '. == []' "$tmp_root/newer/canceled.json" >/dev/null
grep -F "newer Renovate pipeline 9001 wins" "$tmp_root/newer/output.log" >/dev/null

echo "Renovate pipeline cancellation tests passed"
