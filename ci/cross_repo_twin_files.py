#!/usr/bin/env python3
"""Cross-repo twin-file guard for the XSC/xinyi twin product layers.

XposedSmsCode and xinyi-relay carry parallel product layers (hook, screens,
app entry, storage) that evolved from one codebase. Shared logic must go into
the shared submodules, not into new same-name copies. This script fails when a
production file name appears in both repos and is not in the reviewed baseline.

The default gate is deliberately name-only: it is a low-noise reminder, not a
proof that two files are equivalent. Use --report to inspect the actual paths,
packages and content similarity behind every baseline entry.

Usage:
  cross_repo_twin_files.py --repo-a DIR --repo-b DIR --baseline FILE
  cross_repo_twin_files.py --repo-a DIR --repo-b DIR --baseline FILE --report
  cross_repo_twin_files.py --repo-a DIR --repo-b DIR --baseline FILE --json
"""
import argparse
import json
import os
import re
import sys
from difflib import SequenceMatcher

TOP_EXCLUDED = {
    "smscode", "magisk-ui-kit", "magisk-xposed-kit", "build-logic",
    "vendor", "pinned", "frontend", "backend", "desktop", "benchmark",
    "distribution", "fastlane", "docs", "scripts", "config", "art", "gradle",
}
ANYWHERE_EXCLUDED = {".git", ".gradle", "build"}
PACKAGE_RE = re.compile(r"^\s*package\s+([A-Za-z_][\w.]*)", re.MULTILINE)
APP_PACKAGE_RE = re.compile(r"\bio\.github\.magisk317\.(?:smscode|relay)(?=\.|\b)")


def scan(root):
    """Return {file name: [repo-relative paths]} for production sources."""
    files = {}
    for dirpath, dirnames, filenames in os.walk(root):
        rel = os.path.relpath(dirpath, root)
        if rel == ".":
            dirnames[:] = [d for d in dirnames if d not in TOP_EXCLUDED]
            continue
        else:
            parts = rel.split(os.sep)
            if parts[0] in TOP_EXCLUDED or any(p in ANYWHERE_EXCLUDED for p in parts):
                dirnames[:] = []
                continue
        for name in filenames:
            if name.endswith((".kt", ".java")) and "Test" not in name:
                path = os.path.join(dirpath, name)
                files.setdefault(name, []).append(os.path.relpath(path, root))
    return files


def read_text(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def normalize(text):
    # App root namespaces differ intentionally. This is a text comparison only;
    # package metadata remains unchanged and no score proves behavior equivalence.
    return " ".join(APP_PACKAGE_RE.sub("io.github.magisk317.app", text).split())


def package_of(path):
    text = re.sub(r"/\*.*?\*/|//[^\n]*", "", read_text(path), flags=re.DOTALL)
    match = PACKAGE_RE.search(text)
    return match.group(1) if match else ""


def similarity(path_a, path_b):
    a = normalize(read_text(path_a))
    b = normalize(read_text(path_b))
    return SequenceMatcher(None, a, b).ratio()


def build_report(repo_a, scan_a, repo_b, scan_b, names, min_similarity):
    rows = []
    for name in sorted(names):
        a_paths = sorted(scan_a[name])
        b_paths = sorted(scan_b[name])
        a_packages = sorted({package_of(os.path.join(repo_a, p)) for p in a_paths})
        b_packages = sorted({package_of(os.path.join(repo_b, p)) for p in b_paths})
        best = max(
            similarity(os.path.join(repo_a, a), os.path.join(repo_b, b))
            for a in a_paths
            for b in b_paths
        )
        rows.append(
            {
                "name": name,
                "a_paths": a_paths,
                "b_paths": b_paths,
                "a_packages": a_packages,
                "b_packages": b_packages,
                "similarity": round(best, 4),
                "path_drift": a_paths != b_paths,
                "package_drift": a_packages != b_packages,
                "divergent": best < min_similarity,
            }
        )
    return rows


def print_report(rows):
    for row in rows:
        flags = []
        if row["path_drift"]:
            flags.append("path-drift")
        if row["package_drift"]:
            flags.append("package-drift")
        if row["divergent"]:
            flags.append("divergent")
        print(
            "{name}: similarity={similarity:.2f} {flags}\n"
            "  A: {a_paths} [{a_packages}]\n"
            "  B: {b_paths} [{b_packages}]".format(
                flags=",".join(flags) or "aligned",
                **row
            )
        )
    identical = sum(1 for row in rows if not row["divergent"])
    print(
        "twin report: {total} names, {identical} at/above threshold, {divergent} below, "
        "{path_drift} path drift, {package_drift} package drift".format(
            total=len(rows),
            identical=identical,
            divergent=len(rows) - identical,
            path_drift=sum(1 for row in rows if row["path_drift"]),
            package_drift=sum(1 for row in rows if row["package_drift"]),
        )
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-a", required=True)
    parser.add_argument("--repo-b", required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--update", action="store_true")
    parser.add_argument("--report", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--min-similarity", type=float, default=0.95)
    args = parser.parse_args()

    for root in (args.repo_a, args.repo_b):
        if not os.path.isdir(root):
            parser.error("repository is not a directory: {}".format(root))
    if not 0 <= args.min_similarity <= 1:
        parser.error("--min-similarity must be between 0 and 1")

    scan_a = scan(args.repo_a)
    scan_b = scan(args.repo_b)
    twins = set(scan_a) & set(scan_b)
    baseline = set()
    if os.path.exists(args.baseline):
        with open(args.baseline) as handle:
            baseline = set(json.load(handle))

    if args.update:
        with open(args.baseline, "w") as handle:
            json.dump(sorted(twins), handle, indent=1)
        print("baseline updated: {} reviewed twin names".format(len(twins)))
        return 0

    new = sorted(twins - baseline)
    stale = sorted(baseline - twins)

    if args.report or args.json:
        rows = build_report(
            args.repo_a, scan_a, args.repo_b, scan_b, sorted(twins), args.min_similarity
        )
        if args.json:
            print(json.dumps(rows, indent=1))
        else:
            print_report(rows)

    for name in new:
        print(
            "NEW twin file (requires kit extraction review or baseline entry): {}".format(name),
            file=sys.stderr,
        )
    for name in stale:
        print(
            "stale baseline entry (twin no longer exists): {}".format(name),
            file=sys.stderr,
        )
    if new or stale:
        return 1
    if not args.json:
        print("twin-file guard passed ({} reviewed twin names, no growth)".format(len(baseline)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
