#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  validate_android_apk_signatures.sh [apk-root ...]

The expected certificate is read from MAGISK_ANDROID_RELEASE_CERT_SHA256.
When no roots are provided, MAGISK_ANDROID_RELEASE_APK_ROOTS is used.
EOF
}

normalize_sha256() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ':[:space:]'
}

resolve_apksigner() {
  if command -v apksigner >/dev/null 2>&1; then
    command -v apksigner
    return
  fi

  local sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  local -a candidates=()
  if [[ -n "$sdk_root" && -d "$sdk_root/build-tools" ]]; then
    mapfile -t candidates < <(find "$sdk_root/build-tools" -type f -name apksigner | sort -V)
  fi
  if [[ "${#candidates[@]}" -eq 0 ]]; then
    echo "ERROR: apksigner is required to validate release APKs" >&2
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

mapfile -t apk_files < <(
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    find "$root" -type f -path '*/release/*.apk'
  done | sort
)
if [[ "${#apk_files[@]}" -eq 0 ]]; then
  echo "ERROR: no release APK files found for signature validation" >&2
  exit 1
fi

apksigner_path="$(resolve_apksigner)"
validated=0
for apk in "${apk_files[@]}"; do
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
  validated=$((validated + 1))
done

echo "Validated ${validated} release APK signatures against the pinned certificate fingerprint."
