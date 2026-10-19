#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
toolkit_dir="$root_dir"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

selector="$toolkit_dir/ci/select_gradle_tasks.py"
checker="$toolkit_dir/checks/dual_track_check.py"
[[ -f "$selector" && -f "$checker" ]] || { echo "toolkit interfaces missing" >&2; exit 1; }

consumer="$tmp_dir/consumer"
mkdir -p "$consumer/scripts/config"
cat > "$consumer/scripts/config/android-test-tasks.json" <<'EOF'
{
  "full_tasks": [":app:check", ":desktop:jvmTest"],
  "full_paths": ["build.gradle*", "scripts/*"],
  "ignore_paths": ["docs/*"],
  "unknown": "full",
  "rules": [
    {"paths": ["modules/desktop/*"], "tasks": [":desktop:jvmTest"]}
  ]
}
EOF
cat > "$tmp_dir/paths" <<'EOF'
impact
modules/desktop/Example.kt
EOF
python3 "$selector" --root "$consumer" --toolkit "$toolkit_dir" \
  --config "$consumer/scripts/config/android-test-tasks.json" \
  --paths-file "$tmp_dir/paths" > "$tmp_dir/tasks"
grep -Fx ':desktop:jvmTest' "$tmp_dir/tasks" >/dev/null

action_root="$tmp_dir/project"
mkdir -p "$action_root/desktop"
cat > "$action_root/desktop/Example.kt" <<'EOF'
package fixture
import androidx.compose.material3.Text
fun fixture() = Text("ok")
EOF
cat > "$tmp_dir/dual.json" <<'EOF'
{"exempt_prefixes":["desktop/"]}
EOF
python3 "$checker" --root "$action_root" --config "$tmp_dir/dual.json" --quiet

echo 'toolkit configuration contract tests passed'
