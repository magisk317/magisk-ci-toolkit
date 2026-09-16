#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
ensure="$root_dir/ci/ensure_bun.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
bin_dir="$tmp_dir/bin"
mkdir -p "$bin_dir"
marker="$tmp_dir/npm-called"
state="$tmp_dir/bun-version"

cat > "$bin_dir/bun" <<STUB
#!/usr/bin/env bash
[[ "\${1:-}" == "--version" ]] && { cat "$state"; exit 0; }
exit 0
STUB
cat > "$bin_dir/npm" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$marker"
for arg in "\$@"; do
  [[ "\$arg" == bun@* ]] && printf '%s\n' "\${arg#bun@}" > "$state"
done
STUB
chmod +x "$bin_dir/bun" "$bin_dir/npm"
seed() { printf '%s\n' "$1" > "$state"; }
run_ensure() { PATH="$bin_dir:$PATH" bash "$ensure" "$@"; }

printf '{"packageManager":"bun@1.4.0"}\n' > "$tmp_dir/package.json"
seed 1.4.0; rm -f "$marker"
(cd "$tmp_dir" && run_ensure)
[[ ! -e "$marker" ]] || fail "matching Bun invoked npm"

seed 1.0.0; rm -f "$marker"
(cd "$tmp_dir" && run_ensure)
grep -Fq 'bun@1.4.0' "$marker" || fail "mismatched Bun was not installed"

echo "ensure_bun tests passed"
