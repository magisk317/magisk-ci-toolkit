#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  validate_android_apk_signatures.sh [apk-root ...]

The expected certificate is read from MAGISK_ANDROID_RELEASE_CERT_SHA256.
MAGISK_ANDROID_RELEASE_APK_BUILD_TYPES selects output directories (default:
"release"). When both release and debug are selected, every package/versionCode
pair must exist in both sets. Debug APKs must be debuggable unless
MAGISK_ANDROID_RELEASE_ALLOW_NON_DEBUGGABLE_DEBUG=true is set for a deliberately
minified debug artifact.
EOF
}

normalize_sha256() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ':[:space:]'
}

resolve_sdk_tool() {
  local tool="$1"
  if command -v "$tool" >/dev/null 2>&1; then
    command -v "$tool"
    return
  fi

  local sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  local -a candidates=()
  if [[ -n "$sdk_root" && -d "$sdk_root/build-tools" ]]; then
    mapfile -t candidates < <(find "$sdk_root/build-tools" -type f -name "$tool" | sort -V)
  fi
  if [[ "${#candidates[@]}" -eq 0 ]]; then
    echo "ERROR: $tool is required to validate release APKs" >&2
    return 1
  fi
  printf '%s\n' "${candidates[-1]}"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

expected_sha256="$(normalize_sha256 "${MAGISK_ANDROID_RELEASE_CERT_SHA256:-}")"
if [[ ! "$expected_sha256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ERROR: MAGISK_ANDROID_RELEASE_CERT_SHA256 must contain one SHA-256 certificate fingerprint" >&2
  exit 2
fi

if [[ "$#" -gt 0 ]]; then
  roots=("$@")
else
  roots=()
  for root in ${MAGISK_ANDROID_RELEASE_APK_ROOTS:-app/build/outputs/apk}; do
    roots+=("$root")
  done
fi

read -r -a build_types <<< "${MAGISK_ANDROID_RELEASE_APK_BUILD_TYPES:-release}"
if [[ "${#build_types[@]}" -eq 0 ]]; then
  echo "ERROR: MAGISK_ANDROID_RELEASE_APK_BUILD_TYPES must name at least one build type" >&2
  exit 2
fi

allow_nondebuggable_debug="${MAGISK_ANDROID_RELEASE_ALLOW_NON_DEBUGGABLE_DEBUG:-false}"
case "$allow_nondebuggable_debug" in
  true|false) ;;
  *)
    echo "ERROR: MAGISK_ANDROID_RELEASE_ALLOW_NON_DEBUGGABLE_DEBUG must be true or false" >&2
    exit 2
    ;;
esac

mapfile -t apk_files < <(
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    for build_type in "${build_types[@]}"; do
      find "$root" -type f -path "*/${build_type}/*.apk"
    done
  done | sort -u
)
if [[ "${#apk_files[@]}" -eq 0 ]]; then
  echo "ERROR: no APK files found for build types: ${build_types[*]}" >&2
  exit 1
fi
if [[ -n "${MAGISK_ANDROID_RELEASE_EXPECTED_APK_COUNT:-}" \
  && "${#apk_files[@]}" -ne "$MAGISK_ANDROID_RELEASE_EXPECTED_APK_COUNT" ]]; then
  echo "ERROR: expected $MAGISK_ANDROID_RELEASE_EXPECTED_APK_COUNT APKs, found ${#apk_files[@]}" >&2
  exit 1
fi

apksigner_path="$(resolve_sdk_tool apksigner)"
aapt2_path="$(resolve_sdk_tool aapt2)"
max_apk_bytes="${MAGISK_ANDROID_RELEASE_MAX_APK_BYTES:-0}"
declare -A release_coordinates=()
declare -A debug_coordinates=()
validated=0

for apk in "${apk_files[@]}"; do
  size="$(stat -c%s "$apk")"
  if [[ "$size" -le 0 || ( "$max_apk_bytes" -gt 0 && "$size" -gt "$max_apk_bytes" ) ]]; then
    echo "ERROR: APK size is outside the Telegram release contract: $apk ($size bytes)" >&2
    exit 1
  fi

  if ! signer_output="$("$apksigner_path" verify --print-certs "$apk" 2>&1)"; then
    echo "ERROR: APK signature verification failed: $apk" >&2
    printf '%s\n' "$signer_output" >&2
    exit 1
  fi

  declare -A signer_sha256_set=()
  while IFS= read -r signer_sha256; do
    signer_sha256="$(normalize_sha256 "$signer_sha256")"
    [[ "$signer_sha256" =~ ^[0-9a-f]{64}$ ]] && signer_sha256_set["$signer_sha256"]=1
  done < <(
    printf '%s\n' "$signer_output" \
      | sed -nE 's/.*certificate SHA-256 digest:[[:space:]]*([0-9A-Fa-f:]+).*/\1/p'
  )

  if [[ "${#signer_sha256_set[@]}" -ne 1 || -z "${signer_sha256_set[$expected_sha256]:-}" ]]; then
    actual_sha256="$(printf '%s\n' "${!signer_sha256_set[@]}" | sort | paste -sd, -)"
    echo "ERROR: unexpected APK signer set for $apk (got ${actual_sha256:-missing})" >&2
    exit 1
  fi

  if ! badging_output="$("$aapt2_path" dump badging "$apk" 2>&1)"; then
    echo "ERROR: aapt2 could not inspect $apk" >&2
    printf '%s\n' "$badging_output" >&2
    exit 1
  fi
  package_line="$(printf '%s\n' "$badging_output" | sed -n 's/^package: //p' | head -n 1)"
  package_name="$(printf '%s\n' "$package_line" | sed -nE "s/.*name='([^']+)'.*/\1/p")"
  version_code="$(printf '%s\n' "$package_line" | sed -nE "s/.*versionCode='([^']+)'.*/\1/p")"
  version_name="$(printf '%s\n' "$package_line" | sed -nE "s/.*versionName='([^']*)'.*/\1/p")"
  if [[ -z "$package_name" || -z "$version_code" ]]; then
    echo "ERROR: APK package metadata is incomplete: $apk" >&2
    exit 1
  fi
  coordinate="${package_name}|${version_code}|${version_name}"

  build_type=""
  for candidate_type in "${build_types[@]}"; do
    if [[ "$apk" == */"$candidate_type"/*.apk ]]; then
      build_type="$candidate_type"
      break
    fi
  done
  case "$build_type" in
    release)
      if grep -q '^application-debuggable' <<< "$badging_output"; then
        echo "ERROR: release APK is debuggable: $apk" >&2
        exit 1
      fi
      release_coordinates["$coordinate"]=1
      ;;
    debug)
      if ! grep -q '^application-debuggable' <<< "$badging_output"; then
        if [[ "$allow_nondebuggable_debug" != true ]]; then
          echo "ERROR: debug APK is not debuggable: $apk" >&2
          exit 1
        fi
        echo "INFO: allowing non-debuggable debug APK as a minified debug artifact: $apk"
      fi
      debug_coordinates["$coordinate"]=1
      ;;
  esac
  validated=$((validated + 1))
done

if [[ " ${build_types[*]} " == *" release "* && " ${build_types[*]} " == *" debug "* ]]; then
  for coordinate in "${!release_coordinates[@]}"; do
    [[ -n "${debug_coordinates[$coordinate]:-}" ]] || {
      echo "ERROR: release APK has no same-package/version debug companion: $coordinate" >&2
      exit 1
    }
  done
  for coordinate in "${!debug_coordinates[@]}"; do
    [[ -n "${release_coordinates[$coordinate]:-}" ]] || {
      echo "ERROR: debug APK cannot replace a release APK at the same version: $coordinate" >&2
      exit 1
    }
  done
fi

echo "Validated ${validated} APK signatures, metadata and release/debug compatibility."
