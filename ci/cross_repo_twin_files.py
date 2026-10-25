#!/usr/bin/env python3
"""Cross-repo twin-file guard for the XSC/xinyi twin product layers.

XposedSmsCode and xinyi-relay carry parallel product layers (hook, screens,
app entry, storage) that evolved from one codebase. Shared logic must go into
the shared submodules, not into new same-name copies. This script fails when a
production file name appears in both repos and is not in the reviewed baseline.

Usage:
  cross_repo_twin_files.py --repo-a DIR --repo-b DIR --baseline FILE [--update]
"""
import argparse, json, os, sys

TOP_EXCLUDED = {
    "smscode", "magisk-ui-kit", "magisk-xposed-kit", "build-logic",
    "vendor", "pinned", "frontend", "backend", "desktop", "benchmark",
    "distribution", "fastlane", "docs", "scripts", "config", "art", "gradle",
}
ANYWHERE_EXCLUDED = {".git", ".gradle", "build"}

def scan(root):
    names = set()
    for dp, dn, fn in os.walk(root):
        rel = os.path.relpath(dp, root)
        parts = rel.split(os.sep)
        if rel == ".":
            dn[:] = [d for d in dn if d not in TOP_EXCLUDED]
            continue
        if parts[0] in TOP_EXCLUDED or any(p in ANYWHERE_EXCLUDED for p in parts):
            dn[:] = []
            continue
        for f in fn:
            if f.endswith((".kt", ".java")) and "Test" not in f:
                names.add(f)
    return names

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-a", required=True)
    ap.add_argument("--repo-b", required=True)
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--update", action="store_true")
    args = ap.parse_args()
    twins = scan(args.repo_a) & scan(args.repo_b)
    baseline = set()
    if os.path.exists(args.baseline):
        baseline = set(json.load(open(args.baseline)))
    if args.update:
        json.dump(sorted(twins), open(args.baseline, "w"), indent=1)
        print(f"baseline updated: {len(twins)} reviewed twin names")
        return 0
    new = sorted(twins - baseline)
    stale = sorted(baseline - twins)
    for name in new:
        print(f"NEW twin file (requires kit extraction review or baseline entry): {name}", file=sys.stderr)
    for name in stale:
        print(f"stale baseline entry (twin no longer exists): {name}", file=sys.stderr)
    if new or stale:
        return 1
    print(f"twin-file guard passed ({len(baseline)} reviewed twin names, no growth)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
