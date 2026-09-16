#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
validator="$root_dir/release/validate_android_apk_signatures.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

apk_dir="$tmp_dir/app/build/outputs/apk/release"
mkdir -p "$apk_dir"
touch "$apk_dir/demo.apk"

cat > "$tmp_dir/apksigner" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Signer #1 certificate SHA-256 digest: 02:7B:93:6E:1D:82:A6:06:D8:35:99:54:8B:8B:11:E4:9A:2C:8A:E2:58:8C:4A:9F:BE:83:11:E2:C5:4F:10:3A'
EOF
chmod +x "$tmp_dir/apksigner"

expected="027b936e1d82a606d83599548b8b11e49a2c8ae2588c4a9fbe8311e2c54f103a"
PATH="$tmp_dir:$PATH" MAGISK_ANDROID_RELEASE_CERT_SHA256="$expected" \
  bash "$validator" "$tmp_dir/app/build/outputs/apk" >/dev/null

if PATH="$tmp_dir:$PATH" MAGISK_ANDROID_RELEASE_CERT_SHA256="$(printf '0%.0s' {1..64})" \
  bash "$validator" "$tmp_dir/app/build/outputs/apk" >/dev/null 2>&1; then
  echo "FAIL: mismatched signer was accepted" >&2
  exit 1
fi

echo "Android APK signature validation tests passed"
