#!/usr/bin/env bash
set -euo pipefail

sdk_root="${ANDROID_HOME:-/opt/android-sdk}"
build_tools="${ANDROID_BUILD_TOOLS_VERSION:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sdk-root) sdk_root="$2"; shift 2 ;;
    --build-tools) build_tools="$2"; shift 2 ;;
    -h|--help) echo "usage: $0 [--sdk-root DIR] [--build-tools VERSION]"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$build_tools" ]]; then
  build_tools="$(find "$sdk_root/build-tools" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -n 1)"
fi
[[ -n "$build_tools" ]] || { echo "no Android build-tools directory under $sdk_root" >&2; exit 1; }
tool_dir="$sdk_root/build-tools/$build_tools"
[[ -d "$tool_dir" ]] || { echo "missing build-tools: $tool_dir" >&2; exit 1; }

case "$(uname -m)" in
  x86_64) expected_machine="x86-64" ;;
  aarch64|arm64) expected_machine="aarch64" ;;
  *) echo "unsupported host architecture: $(uname -m)" >&2; exit 1 ;;
esac

elf_machine() {
  python3 - "$1" <<'PY'
import struct
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_bytes()[:20]
if len(raw) < 20 or raw[:4] != b"\x7fELF":
    print("non-ELF")
    raise SystemExit
endian = "<" if raw[5] == 1 else ">"
machine = struct.unpack_from(endian + "H", raw, 18)[0]
print({62: "x86-64", 183: "aarch64"}.get(machine, f"machine-{machine}"))
PY
}

fail=0
for name in aapt2 aidl; do
  path="$tool_dir/$name"
  if [[ ! -x "$path" ]]; then
    echo "FAIL: missing or non-executable runtime tool $path" >&2
    fail=1
    continue
  fi
  machine="$(elf_machine "$path")"
  if [[ "$machine" != "$expected_machine" ]]; then
    echo "FAIL: $path has architecture $machine, expected $expected_machine" >&2
    fail=1
  fi
  if ! "$path" --version >/dev/null 2>&1; then
    echo "FAIL: $path cannot execute on this host" >&2
    fail=1
  fi
done

for name in aapt zipalign dexdump; do
  path="$tool_dir/$name"
  [[ -x "$path" ]] || {
    echo "FAIL: required SDK file is missing or non-executable: $path" >&2
    fail=1
    continue
  }
  echo "INFO: presence-only SDK tool $name verified"
done

(( fail == 0 )) || exit 1
printf 'Android host tools verified: %s (runtime=%s)\n' "$tool_dir" "$expected_machine"
