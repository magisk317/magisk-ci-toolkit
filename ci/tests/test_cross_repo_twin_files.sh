#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/ci/cross_repo_twin_files.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/a/app" "$TMP/b/app" "$TMP/a/build" "$TMP/b/build"

cat > "$TMP/a/app/Foo.kt" <<'EOF'
package com.example.a
class Foo
EOF
cp "$TMP/a/app/Foo.kt" "$TMP/b/app/Foo.kt"
cp "$TMP/a/app/Foo.kt" "$TMP/a/Root.kt"
cp "$TMP/a/app/Foo.kt" "$TMP/b/Root.kt"

cat > "$TMP/a/app/Bar.kt" <<'EOF'
package com.example.a
class Bar(val x: Int = 1)
EOF
cat > "$TMP/b/app/Bar.kt" <<'EOF'
package com.example.b
class Bar(val x: Int = 2)
EOF

cat > "$TMP/a/build/Skip.kt" <<'EOF'
package com.example.a
class Skip
EOF
cp "$TMP/a/build/Skip.kt" "$TMP/b/build/Skip.kt"

cat > "$TMP/a/app/FooTest.kt" <<'EOF'
package com.example.a
class FooTest
EOF
cp "$TMP/a/app/FooTest.kt" "$TMP/b/app/FooTest.kt"

printf '["Foo.kt", "Bar.kt"]\n' > "$TMP/baseline.json"
out=$(python3 "$SCRIPT" --repo-a "$TMP/a" --repo-b "$TMP/b" --baseline "$TMP/baseline.json")
grep -q "guard passed (2 reviewed twin names, no growth)" <<<"$out"
if grep -q "Skip.kt\|FooTest.kt" <<<"$out"; then
    echo "excluded files leaked into the guard output" >&2
    exit 1
fi

printf '["Foo.kt"]\n' > "$TMP/new.json"
if python3 "$SCRIPT" --repo-a "$TMP/a" --repo-b "$TMP/b" --baseline "$TMP/new.json" 2>"$TMP/new.err"; then
    echo "expected a new twin to fail the gate" >&2
    exit 1
fi
grep -q "NEW twin file.*Bar.kt" "$TMP/new.err"

printf '["Foo.kt", "Bar.kt", "Gone.kt"]\n' > "$TMP/stale.json"
if python3 "$SCRIPT" --repo-a "$TMP/a" --repo-b "$TMP/b" --baseline "$TMP/stale.json" 2>"$TMP/stale.err"; then
    echo "expected a stale baseline entry to fail the gate" >&2
    exit 1
fi
grep -q "stale baseline entry.*Gone.kt" "$TMP/stale.err"

python3 "$SCRIPT" --repo-a "$TMP/a" --repo-b "$TMP/b" --baseline "$TMP/baseline.json" --report --min-similarity 0.99 >"$TMP/report.txt"
grep -q "Bar.kt: similarity=.*divergent" "$TMP/report.txt"
grep -q "path drift" "$TMP/report.txt"
grep -q "package drift" "$TMP/report.txt"

python3 "$SCRIPT" --repo-a "$TMP/a" --repo-b "$TMP/b" --baseline "$TMP/baseline.json" --json --min-similarity 0.99 >"$TMP/report.json"
python3 - "$TMP/report.json" <<'EOF'
import json
import sys

rows = {row["name"]: row for row in json.load(open(sys.argv[1]))}
assert rows["Foo.kt"]["divergent"] is False
assert rows["Bar.kt"]["divergent"] is True
assert rows["Bar.kt"]["package_drift"] is True
EOF

python3 - "$SCRIPT" "$TMP" <<'EOF'
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("twins", sys.argv[1])
twins = importlib.util.module_from_spec(spec)
spec.loader.exec_module(twins)
assert twins.normalize("package io.github.magisk317.smscode.ui\nclass Screen") == twins.normalize(
    "package io.github.magisk317.relay.ui\nclass Screen"
)
assert twins.normalize("io.github.magisk317.relayconfig") == "io.github.magisk317.relayconfig"
assert twins.normalize("val enabled = true") != twins.normalize("val enabled = false")
source = Path(sys.argv[2]) / "Comment.kt"
source.write_text("/*\npackage misleading.comment\n*/\npackage actual.example\nclass Comment\n")
assert twins.package_of(source) == "actual.example"
EOF

if python3 "$SCRIPT" --repo-a "$TMP/missing" --repo-b "$TMP/b" --baseline "$TMP/baseline.json" >"$TMP/missing.out" 2>"$TMP/missing.err"; then
    echo "expected a missing checkout to fail" >&2
    exit 1
fi
grep -q "not a directory" "$TMP/missing.err"

if python3 "$SCRIPT" --repo-a "$TMP/a" --repo-b "$TMP/b" --baseline "$TMP/baseline.json" --min-similarity 1.1 >"$TMP/threshold.out" 2>"$TMP/threshold.err"; then
    echo "expected an invalid similarity threshold to fail" >&2
    exit 1
fi
grep -q "between 0 and 1" "$TMP/threshold.err"

echo "cross_repo_twin_files tests passed"
