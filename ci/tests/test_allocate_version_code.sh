#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/../.." && pwd)"
script="$root_dir/ci/allocate_version_code.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$script" ] || fail "$script is missing"
bash -n "$script" || fail "$script has a syntax error"

# The retry loop is the whole point: the same (project, scope) must return the
# same code forever, so retrying can never burn a number. Everything below
# exists to keep that property from being refactored away.
for needle in \
  'MAGISK_VERSION_ALLOCATOR_TOKEN' \
  '--retry 3' \
  '"code"[[:space:]]*:[[:space:]]*([0-9]+)' \
  '^[1-9][0-9]*$' \
  'version allocator returned no usable code'; do
  grep -Fq -- "$needle" "$script" || fail "lost required text: '$needle'"
done
# Fail closed: an unusable response must never fall through to a default code.
grep -Fq 'fail "version allocator returned no usable code' "$script" \
  || fail 'an unusable allocator response must fail the build, not fall back'
# No jq, in any form. The Android build image that calls this client from
# .gitlab/ci/android.yml has curl but not jq, so a jq call here is not a style
# preference, it is the build failing with "jq is required".
if grep -Eq 'command -v jq|\| *jq( |\$)|jq -' "$script"; then
  fail 'the allocator client must not shell out to jq: the Android build image has no jq'
fi

# --- live behaviour against a stub allocator ----------------------------------
python3 --version >/dev/null 2>&1 || { echo "SKIP: python3 not available for the stub"; exit 0; }

port=$((20000 + RANDOM % 20000))
state_file="$(mktemp)"
stub_py="$(mktemp --suffix=.py)"
stub_log="$(mktemp)"
trap 'rm -f "$state_file" "$stub_py" "$stub_log"' EXIT

cat > "$stub_py" <<'PY'
import http.server
import json
import os
import sys

state_path = sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length).decode() if length else ""
        with open(state_path) as fh:
            seen = int(fh.read().strip() or 0)
        with open(state_path, "w") as fh:
            fh.write(str(seen + 1))
        mode = os.environ.get("STUB_MODE", "ok")
        # "flaky" fails the first two attempts so the retry path is exercised.
        if mode == "flaky" and seen < 2:
            self.send_response(500)
            self.end_headers()
            return
        if mode == "reject":
            self.send_response(400)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":"unknown project: add a seed row first"}')
            return
        if mode == "refused_with_number":
            # A well-formed "not allocated" answer that still carries a number.
            # The client must read "ok" before "code", or it would push a code
            # the allocator explicitly refused.
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok": false, "reason": "quota", "code": 999}')
            return
        body = json.dumps({"ok": True, "project": "MiPushFramework", "code": 4242}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY

export MAGISK_VERSION_ALLOCATOR_URL="http://127.0.0.1:$port"
# The stub is on loopback, and this host (and every runner job) carries a corporate
# HTTP proxy in the environment. Without disabling it curl sends the loopback request
# through the proxy and gets a 502, which looks exactly like a dead stub.
export http_proxy="" https_proxy="" HTTP_PROXY="" HTTPS_PROXY="" no_proxy="*" NO_PROXY="*"

echo "0" > "$state_file"
STUB_MODE=ok python3 "$stub_py" "$port" "$state_file" >"$stub_log" 2>&1 &
stub_pid=$!
for _ in $(seq 1 20); do
  curl -s -o /dev/null -m 1 "http://127.0.0.1:$port/" 2>/dev/null && break
  sleep 0.2
done

# 1. Happy path returns exactly the code, and nothing else, on stdout.
out="$(MAGISK_VERSION_ALLOCATOR_TOKEN=t bash "$script" --project MiPushFramework --scope "gitlab:83955143:862")"
[ "$out" = "4242" ] || fail "expected 4242 on stdout, got '$out'"

# 1b. The same call with a PATH that carries only curl (plus bash and sleep):
#     that is the Android build image, which has no jq. .gitlab/ci/android.yml
#     calls this client from the build job, and the first time it did, every
#     android:build job died on "ERROR: jq is required" -- so the absence of jq
#     is tested here instead of assumed.
minbin="$(mktemp -d)"
for tool in bash curl sleep; do
  src="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$src" ] && ln -s "$src" "$minbin/$tool"
done
if [ -x "$minbin/curl" ]; then
  out_nojq="$(env -i PATH="$minbin" \
    MAGISK_VERSION_ALLOCATOR_TOKEN=t \
    MAGISK_VERSION_ALLOCATOR_URL="$MAGISK_VERSION_ALLOCATOR_URL" \
    bash "$script" --project MiPushFramework --scope "gitlab:83955143:1862")"
  [ "$out_nojq" = "4242" ] \
    || fail "a jq-free PATH returned '$out_nojq'; the client must parse the response without jq"
else
  echo "NOTE: curl not found for the jq-free PATH case; skipped"
fi
rm -rf -- "$minbin"

# 2. The same scope replays the same code (idempotency is the allocator's, but the
#    caller must keep asking with the same scope for it to matter).
out2="$(MAGISK_VERSION_ALLOCATOR_TOKEN=t bash "$script" --project MiPushFramework --scope "gitlab:83955143:862")"
[ "$out2" = "4242" ] || fail "replay returned '$out2'"

# 3. No token: fail closed rather than inventing a code.
if MAGISK_VERSION_ALLOCATOR_TOKEN="" bash "$script" --project MiPushFramework --scope s 2>/dev/null; then
  fail "missing token must fail the build"
fi

# 4. A rejected allocation fails even with retries; transient 500s are retried, and the retry still lands on a code.
kill "$stub_pid" 2>/dev/null || true
wait "$stub_pid" 2>/dev/null || true
echo "0" > "$state_file"
STUB_MODE=reject python3 "$stub_py" "$port" "$state_file" >"$stub_log" 2>&1 &
stub_pid=$!
for _ in $(seq 1 20); do
  curl -s -o /dev/null -m 1 "http://127.0.0.1:$port/" 2>/dev/null && break
  sleep 0.2
done
if MAGISK_VERSION_ALLOCATOR_TOKEN=t MAGISK_VERSION_ALLOCATOR_ATTEMPTS=2 \
    bash "$script" --project NapGram --scope s 2>/dev/null; then
  fail "a persistent rejection must fail even with retries"
fi
kill "$stub_pid" 2>/dev/null || true
wait "$stub_pid" 2>/dev/null || true

# 5. A refused answer that still carries a number must not be read as a code.
#    This is the case the bash regex replaced jq for: parsing "ok" is not
#    optional, and a body-shaped coincidence is not an allocation.
echo "0" > "$state_file"
STUB_MODE=refused_with_number python3 "$stub_py" "$port" "$state_file" >"$stub_log" 2>&1 &
stub_pid=$!
for _ in $(seq 1 20); do
  curl -s -o /dev/null -m 1 "http://127.0.0.1:$port/" 2>/dev/null && break
  sleep 0.2
done
if out5="$(MAGISK_VERSION_ALLOCATOR_TOKEN=t MAGISK_VERSION_ALLOCATOR_ATTEMPTS=1 \
    bash "$script" --project MiPushFramework --scope s 2>/dev/null)"; then
  fail "ok:false with a code must fail closed, got '$out5'"
fi
kill "$stub_pid" 2>/dev/null || true
wait "$stub_pid" 2>/dev/null || true

echo "0" > "$state_file"
STUB_MODE=flaky python3 "$stub_py" "$port" "$state_file" >"$stub_log" 2>&1 &
stub_pid=$!
for _ in $(seq 1 20); do
  curl -s -o /dev/null -m 1 "http://127.0.0.1:$port/" 2>/dev/null && break
  sleep 0.2
done
out3="$(MAGISK_VERSION_ALLOCATOR_TOKEN=t MAGISK_VERSION_ALLOCATOR_SLEEP_SECONDS=0 \
  bash "$script" --project MiPushFramework --scope "gitlab:83955143:863")"
[ "$out3" = "4242" ] || fail "retry after transient 500s returned '$out3'"
kill "$stub_pid" 2>/dev/null || true
wait "$stub_pid" 2>/dev/null || true

echo "PASS: version allocator client contract holds."
