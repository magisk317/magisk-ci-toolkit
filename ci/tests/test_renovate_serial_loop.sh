#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
loop_script="$(cd "$script_dir/.." && pwd)/renovate_serial_loop.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf -- "$tmp_root"' EXIT

mock_bin="$tmp_root/bin"
mkdir -p "$mock_bin"

cat >"$mock_bin/renovate" <<'MOCK_RENOVATE'
#!/usr/bin/env bash
set -euo pipefail
count="$(cat "$MOCK_RENOVATE_COUNT_FILE")"
count=$((count + 1))
printf '%s\n' "$count" >"$MOCK_RENOVATE_COUNT_FILE"
case "$MOCK_SCENARIO:$count" in
  two-rounds:1)
    printf '%s\n' "open" >"$MOCK_STATE_FILE"
    ;;
  two-rounds:2)
    printf '%s\n' "done" >"$MOCK_STATE_FILE"
    ;;
  already-merged:1)
    printf '%s\n' "done" >"$MOCK_STATE_FILE"
    ;;
  *)
    :
    ;;
esac
MOCK_RENOVATE
chmod +x "$mock_bin/renovate"

cat >"$mock_bin/git" <<'MOCK_GIT'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  fetch | checkout) exit 0 ;;
  rev-parse)
    if [[ "$(cat "$MOCK_STATE_FILE")" == "done" || "$(cat "$MOCK_STATE_FILE")" == "merged" ]]; then
      printf '%s\n' "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    else
      printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    fi
    ;;
  *) echo "mock git: unsupported argument $1" >&2; exit 64 ;;
esac
MOCK_GIT
chmod +x "$mock_bin/git"

cat >"$mock_bin/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"$MOCK_SLEEP_LOG"
MOCK_SLEEP
chmod +x "$mock_bin/sleep"

cat >"$mock_bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail

output_file=""
method="GET"
url=""
requested_state=""
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
    --data-urlencode)
      case "$2" in
        state=*) requested_state="${2#state=}" ;;
      esac
      shift 2
      ;;
    --header | --write-out)
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

[[ "$method" == "GET" && -n "$output_file" ]] || {
  echo "mock curl: expected GET with output file" >&2
  exit 64
}

state="$(cat "$MOCK_STATE_FILE")"
if [[ "$url" == */repository/branches/* ]]; then
  if [[ "$state" == "done" || "$state" == "merged" ]]; then
    sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  else
    sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  fi
  jq -n --arg sha "$sha" '{commit:{id:$sha}}' >"$output_file"
  exit 0
fi

if [[ "$url" == */repository/commits ]]; then
  jq -n '[{id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]' >"$output_file"
  exit 0
fi

if [[ "$url" == */repository/compare ]]; then
  jq -n '{compare_timeout:false,commits:[{id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}' >"$output_file"
  exit 0
fi

if [[ "$url" == */merge_requests && "$requested_state" == "opened" && "$state" == "open" ]]; then
    jq -n '[{iid:101,state:"opened",source_project_id:123,source_branch:"renovate/agp",target_branch:"beta"}]' >"$output_file"
  exit 0
fi

if [[ "$url" == */merge_requests && "$requested_state" == "opened" ]]; then
  jq -n '[]' >"$output_file"
  exit 0
fi

if [[ "$url" == */merge_requests && "$requested_state" == "merged" && ("$state" == "done" || "$state" == "merged") ]]; then
  jq -n '[{iid:101,state:"merged",source_project_id:123,source_branch:"renovate/agp",target_branch:"beta",merge_commit_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]' >"$output_file"
  exit 0
fi

if [[ "$url" == */merge_requests ]]; then
  jq -n '[]' >"$output_file"
  exit 0
fi

if [[ "$url" == */merge_requests/101 ]]; then
  if [[ "$state" == "open" ]]; then
    printf '%s\n' "merged" >"$MOCK_STATE_FILE"
  fi
  jq -n '{iid:101,state:"merged",source_project_id:123,source_branch:"renovate/agp",target_branch:"beta",merge_commit_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' >"$output_file"
  exit 0
fi

echo "mock curl: unsupported URL $url" >&2
exit 64
MOCK_CURL
chmod +x "$mock_bin/curl"

run_case() {
  local scenario="$1"
  local case_dir="$tmp_root/$scenario"
  mkdir -p "$case_dir/project"
  printf '%s\n' "${2:-none}" >"$case_dir/state"
  printf '0\n' >"$case_dir/renovate-count"
  : >"$case_dir/sleep.log"

  set +e
  env \
    PATH="$mock_bin:$PATH" \
    MOCK_SCENARIO="$scenario" \
    MOCK_STATE_FILE="$case_dir/state" \
    MOCK_RENOVATE_COUNT_FILE="$case_dir/renovate-count" \
    MOCK_SLEEP_LOG="$case_dir/sleep.log" \
    CI_API_V4_URL="https://gitlab.example/api/v4" \
    CI_PROJECT_ID="123" \
    CI_PROJECT_DIR="$case_dir/project" \
    CI_COMMIT_REF_NAME="beta" \
    CI_DEFAULT_BRANCH="beta" \
    CI_PIPELINE_SOURCE="schedule" \
    RENOVATE_TOKEN="test-token" \
    MAGISK_CANCEL_OLDER_MR_PIPELINES="true" \
    MAGISK_RENOVATE_MR_POLL_INTERVAL_SECONDS="0" \
    MAGISK_RENOVATE_MR_MAX_POLLS="4" \
    MAGISK_RENOVATE_NO_MR_GRACE_POLLS="2" \
    MAGISK_RENOVATE_MAX_ROUNDS="2" \
    bash "$loop_script" >"$case_dir/output.log" 2>&1
  run_status=$?
  set -e
  printf '%s\n' "$run_status" >"$case_dir/status"
}

run_case two-rounds none
[[ "$(cat "$tmp_root/two-rounds/status")" == "0" ]] || {
  cat "$tmp_root/two-rounds/output.log" >&2
  exit 1
}
[[ "$(cat "$tmp_root/two-rounds/renovate-count")" == "2" ]] || exit 1
grep -F "Starting Renovate serial round 1/2" "$tmp_root/two-rounds/output.log" >/dev/null
grep -F "Starting Renovate serial round 2/2" "$tmp_root/two-rounds/output.log" >/dev/null

run_case already-merged none
[[ "$(cat "$tmp_root/already-merged/status")" == "0" ]] || {
  cat "$tmp_root/already-merged/output.log" >&2
  exit 1
}
[[ "$(cat "$tmp_root/already-merged/renovate-count")" == "2" ]] || exit 1
grep -F "Detected already-merged Renovate merge request !101" "$tmp_root/already-merged/output.log" >/dev/null

run_case existing open
[[ "$(cat "$tmp_root/existing/renovate-count")" == "1" ]] || exit 1

echo "serial Renovate loop tests passed"
