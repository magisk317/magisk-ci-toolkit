#!/usr/bin/env python3
"""Fleet build-warning gate: parse build logs, diff findings against the whitelist.

Two warning shapes are understood (both measured in this fleet's builds):

1. Gradle problems-report blocks, emitted because the repos set
   org.gradle.warning.mode=all:

       Problem found: Kotlin compiler: RETURN_VALUE_NOT_USED (id: RETURN_VALUE_NOT_USED, in kotlin > compiler:warning)
         Kotlin compiler warning
           Unused return value of 'runCatching'.
           Location: /repo/xposed/src/main/java/Foo.kt:226

2. Gradle configuration-phase deprecation notices:

       The Configuration.setVisible(boolean) method has been deprecated. ...
           at dev.detekt.gradle.plugin.DetektBasePlugin$apply$2.invoke(DetektBasePlugin.kt:60)
           at Build_gradle$3.execute$configureDetekt$lambda$1(build.gradle.kts:178)

Note on incremental builds: FROM-CACHE and up-to-date compile tasks do not replay
warnings, so a clean scan needs a full recompile (--rerun-tasks --no-build-cache).
This gate scans whatever logs it is given; producing fresh logs is the caller's job.

Usage:
  check_build_warnings.py --repo REPO --log FILE [--log FILE ...]
  check_build_warnings.py --repo REPO --scan-dir DIR [--since-epoch E | --since-commit REV]
                          --whitelist FILE [--quiet]

Exit codes: 0 = no findings or all findings whitelisted; 1 = at least one
non-whitelisted finding; 2 = usage error.
"""
import fnmatch
import os
import re
import subprocess
import sys

PROBLEM_RE = re.compile(r"^Problem found:\s*(?P<source>[^:(]+?):\s*(?P<id>\S+)\s*\(id:\s*(?P<id2>\S+?),\s*(?P<category>.*?)\)\s*$")
LOCATION_RE = re.compile(r"^\s*Location:\s*(?P<path>.+?):(?P<line>\d+)\s*$")
DEPRECATED_RE = re.compile(r"^(?:The\s+)?(?P<api>\S+(?:\([^)]*\))?)\s+(?:method\s+)?has been deprecated\.")
FRAME_RE = re.compile(r"^\s*at\s+[^(]+\((?P<file>[^():]+):(?P<line>\d+)\)\s*$")


def warn(message):
    print("build-warning gate: %s" % message, file=sys.stderr)


def normalize_path(raw, repo):
    """Map an absolute build-machine path onto a repo-relative path."""
    repo = os.path.abspath(repo)
    base = os.path.basename(repo)
    if raw.startswith(repo + os.sep):
        return os.path.relpath(raw, repo)
    # CI layout: /builds/<group>/<project>/<path>
    marker = os.sep + base + os.sep
    idx = raw.find(marker)
    if idx != -1:
        return raw[idx + len(marker):]
    return raw


def parse_problem_blocks(lines):
    """Yield (key, [paths]) for Gradle problems-report blocks."""
    findings = []
    current = None
    for line in lines:
        if line.startswith("Problem found:"):
            if current:
                findings.append(current)
            match = PROBLEM_RE.match(line)
            if match:
                source = match.group("source").strip()
                ident = match.group("id2") or match.group("id")
                key = "kotlin:%s" % ident if source == "Kotlin compiler" else "%s:%s" % (source, ident)
                current = {"key": key, "paths": []}
            else:
                current = {"key": "unparsed:%s" % line.strip()[:80], "paths": []}
            continue
        if current is not None:
            location = LOCATION_RE.match(line)
            if location:
                current["paths"].append(location.group("path"))
                findings.append(current)
                current = None
            elif line and not line[0].isspace():
                # Block ended without a Location line.
                findings.append(current)
                current = None
    if current:
        findings.append(current)
    return [(f["key"], f["paths"]) for f in findings if f["paths"]]


def parse_deprecations(lines):
    """Yield (key, [paths]) for configuration-phase deprecation notices.

    Every stack frame in the notice is kept as a candidate path: the innermost
    frames are usually Gradle-internal, while the frame that matters for
    whitelisting is the consumer's own build script further out.
    """
    findings = []
    pending = None
    for line in lines:
        if pending is None:
            match = DEPRECATED_RE.match(line.strip())
            if match:
                pending = {"key": "gradle-deprecation:%s" % match.group("api"), "paths": []}
            continue
        frame = FRAME_RE.match(line)
        if frame:
            pending["paths"].append(frame.group("file"))
        elif line.strip().startswith("(Run with --stacktrace"):
            findings.append(pending)
            pending = None
        elif line and not line[0].isspace():
            # Notice ended without the closing marker.
            findings.append(pending)
            pending = None
    if pending:
        findings.append(pending)
    return [(f["key"], f["paths"]) for f in findings if f["paths"]]


def load_whitelist(path):
    entries = []
    with open(path, encoding="utf-8") as handle:
        for lineno, raw in enumerate(handle, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = [part.strip() for part in line.split("|")]
            if len(parts) != 5:
                warn("whitelist line %d malformed (expected 5 fields): %s" % (lineno, line))
                continue
            entries.append({
                "repo_glob": parts[0],
                "file_glob": parts[1],
                "key": parts[2],
                "reason": parts[3],
                "confirmed": parts[4],
            })
    return entries


def is_whitelisted(key, relpaths, repo_name, entries):
    for entry in entries:
        if entry["key"] != key:
            continue
        if not fnmatch.fnmatchcase(repo_name, entry["repo_glob"]):
            continue
        if any(relpath and fnmatch.fnmatchcase(relpath, entry["file_glob"]) for relpath in relpaths):
            return entry
    return None


def commit_epoch(repo, rev):
    try:
        out = subprocess.run(
            ["git", "-C", repo, "show", "-s", "--format=%ct", rev],
            capture_output=True, text=True, check=True,
        )
        return int(out.stdout.strip())
    except Exception:
        return None


def collect_logs(scan_dir, since_epoch):
    logs = []
    for name in sorted(os.listdir(scan_dir)):
        if not name.endswith(".log"):
            continue
        path = os.path.join(scan_dir, name)
        if since_epoch is not None and os.path.getmtime(path) < since_epoch:
            continue
        logs.append(path)
    return logs


def main(argv):
    args = {"log": [], "scan_dir": None, "repo": None, "whitelist": None,
            "since_epoch": None, "since_commit": None, "quiet": False}
    index = 1
    while index < len(argv):
        token = argv[index]
        if token == "--log":
            args["log"].append(argv[index + 1]); index += 2
        elif token == "--scan-dir":
            args["scan_dir"] = argv[index + 1]; index += 2
        elif token == "--repo":
            args["repo"] = argv[index + 1]; index += 2
        elif token == "--whitelist":
            args["whitelist"] = argv[index + 1]; index += 2
        elif token == "--since-epoch":
            args["since_epoch"] = int(argv[index + 1]); index += 2
        elif token == "--since-commit":
            args["since_commit"] = argv[index + 1]; index += 2
        elif token == "--quiet":
            args["quiet"] = True; index += 1
        else:
            warn("unknown argument: %s" % token)
            return 2
    if not args["repo"] or not args["whitelist"]:
        warn("--repo and --whitelist are required")
        return 2
    if not args["log"] and not args["scan_dir"]:
        warn("one of --log or --scan-dir is required")
        return 2

    since_epoch = args["since_epoch"]
    if args["since_commit"]:
        resolved = commit_epoch(args["repo"], args["since_commit"])
        if resolved is None:
            warn("cannot resolve --since-commit %s; scanning all logs" % args["since_commit"])
        else:
            since_epoch = resolved

    logs = list(args["log"])
    if args["scan_dir"]:
        if os.path.isdir(args["scan_dir"]):
            logs.extend(collect_logs(args["scan_dir"], since_epoch))
        else:
            if not args["quiet"]:
                print("build-warning gate: no %s; nothing to scan (CI remains the backstop)" % args["scan_dir"])
            return 0
    if not logs:
        if not args["quiet"]:
            print("build-warning gate: no fresh build logs; nothing to scan (CI remains the backstop)")
        return 0

    repo_name = os.path.basename(os.path.abspath(args["repo"]))
    entries = load_whitelist(args["whitelist"])

    seen = {}
    for path in logs:
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                lines = handle.read().splitlines()
        except OSError as error:
            warn("cannot read %s: %s" % (path, error))
            continue
        for key, raws in parse_problem_blocks(lines) + parse_deprecations(lines):
            relpaths = tuple(normalize_path(raw, args["repo"]) if raw else "" for raw in raws)
            if relpaths not in seen:
                seen[relpaths] = (key, path)

    blocked = []
    whitelisted = []
    for relpaths, (key, origin) in sorted(seen.items()):
        entry = is_whitelisted(key, relpaths, repo_name, entries)
        if entry:
            whitelisted.append((key, relpaths, entry))
        else:
            blocked.append((key, relpaths, origin))

    def describe(relpaths):
        primary = relpaths[0] or "<no location>"
        if len(relpaths) > 1:
            return "%s (+%d more frame(s))" % (primary, len(relpaths) - 1)
        return primary

    print("build-warning gate: repo=%s logs=%d findings=%d whitelisted=%d blocked=%d"
          % (repo_name, len(logs), len(seen), len(whitelisted), len(blocked)))
    for key, relpaths, entry in whitelisted:
        if not args["quiet"]:
            print("  ok      %s %s [%s]" % (key, describe(relpaths), entry["reason"]))
    for key, relpaths, origin in blocked:
        print("  BLOCKED %s %s (from %s)" % (key, describe(relpaths), os.path.basename(origin)))
    if blocked:
        print("build-warning gate: %d finding(s) not on the whitelist." % len(blocked))
        print("  Fix them in code, or add a confirmed entry to the whitelist with a reason.")
        print("  Escape valve for this push: SKIP_WARNING_CHECK=1")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
