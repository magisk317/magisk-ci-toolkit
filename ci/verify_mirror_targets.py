#!/usr/bin/env python3
"""Verify that explicitly supplied repositories have distinct static GitHub mirrors.

Each repository must declare one literal MAGISK_GITHUB_MIRROR_REPOSITORY in its
root .gitlab-ci.yml. Pass the repository directories to check; no workspace
layout or equality between GitLab and GitHub repository names is assumed.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from pathlib import Path
import re
import sys

KEY = re.compile(r"^\s*MAGISK_GITHUB_MIRROR_REPOSITORY\s*:", re.MULTILINE)
VALUE = re.compile(
    r"^\s*MAGISK_GITHUB_MIRROR_REPOSITORY\s*:\s*"
    r"(?P<quote>['\"]?)(?P<target>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?P=quote)"
    r"\s*(?:#.*)?$",
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repositories", nargs="+", type=Path)
    args = parser.parse_args()
    repositories = sorted({path.resolve() for path in args.repositories})
    owners: dict[str, list[Path]] = defaultdict(list)
    failures: list[str] = []
    for repo in repositories:
        config = repo / ".gitlab-ci.yml"
        try:
            lines = config.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError) as error:
            failures.append(f"{config}: cannot read configuration ({error})")
            continue
        declarations = [line for line in lines if KEY.match(line)]
        if len(declarations) != 1:
            failures.append(f"{config}: expected exactly one explicit mirror target")
            continue
        match = VALUE.fullmatch(declarations[0])
        if match is None:
            failures.append(f"{config}: mirror target must be a literal owner/repository")
            continue
        target = match.group("target")
        owners[target.casefold()].append(repo)
        print(f"{repo}: {target}")
    for target, sources in owners.items():
        if len(sources) > 1:
            failures.append(f"{target}: mirror target is shared by " + ", ".join(map(str, sources)))
    if failures:
        for failure in failures:
            print(f"FAIL {failure}", file=sys.stderr)
        return 1
    print(f"GitHub mirror targets are unique across {len(repositories)} repositories.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
