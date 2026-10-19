#!/usr/bin/env python3
"""Select project-specific Gradle tasks from the shared changed-path format."""

import argparse
import fnmatch
import json
import os
import subprocess
import sys
import tempfile


def load(path):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    for key in ("full_tasks", "full_paths", "ignore_paths", "rules"):
        if key not in data:
            raise ValueError("selector config missing %s" % key)
    return data


def matches(path, patterns):
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)


def full_branch():
    return bool(
        os.environ.get("CI_COMMIT_TAG")
        or os.environ.get("GITHUB_REF_TYPE") == "tag"
        or os.environ.get("CI_COMMIT_BRANCH") in {"beta", "master"}
        or os.environ.get("GITHUB_REF_NAME") in {"beta", "master"}
    )


def changed_paths(root, toolkit, supplied):
    if supplied:
        with open(supplied, encoding="utf-8") as handle:
            return [line.rstrip("\n") for line in handle]
    fd, path = tempfile.mkstemp()
    os.close(fd)
    try:
        subprocess.run(["bash", os.path.join(toolkit, "ci", "changed_paths.sh"), path], cwd=root, check=True)
        with open(path, encoding="utf-8") as handle:
            return [line.rstrip("\n") for line in handle]
    finally:
        os.unlink(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    parser.add_argument("--toolkit", default=None)
    parser.add_argument("--config", required=True)
    parser.add_argument("--paths-file")
    args = parser.parse_args()
    root = os.path.abspath(args.root)
    toolkit = os.path.abspath(args.toolkit or os.environ.get("MAGISK_CI_TOOLKIT_DIR", ".magisk-ci-toolkit"))
    config = load(args.config)
    if full_branch():
        print("\n".join(config["full_tasks"]))
        return 0
    paths = changed_paths(root, toolkit, args.paths_file)
    if not paths or paths[0] == "full":
        print("\n".join(config["full_tasks"]))
        return 0
    selected = set()
    for path in paths[1:]:
        if not path:
            continue
        if matches(path, config["full_paths"]):
            print("\n".join(config["full_tasks"]))
            return 0
        if matches(path, config["ignore_paths"]):
            continue
        matched = False
        for rule in config["rules"]:
            if matches(path, rule["paths"]):
                matched = True
                if rule.get("full", False):
                    print("\n".join(config["full_tasks"]))
                    return 0
                selected.update(rule.get("tasks", []))
        if not matched and config.get("unknown", "full") == "full":
            print("\n".join(config["full_tasks"]))
            return 0
    print("\n".join(sorted(selected)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print("selector error: %s" % exc, file=sys.stderr)
        sys.exit(2)
