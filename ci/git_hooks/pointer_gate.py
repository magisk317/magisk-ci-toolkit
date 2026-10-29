#!/usr/bin/env python3
"""Submodule-pointer alignment gate, meant to be wired into git hooks at two moments.

  post-commit  report only - every commit prints the alignment table for this repo
  pre-push     blocks the push when a pointer would break a clone or a CI checkout

For every submodule of the repo the hook runs in it compares four values:

  local    the gitlink recorded in HEAD                 (git ls-tree HEAD)
  remote   the gitlink recorded on the remote branch    (git ls-tree origin/<branch>)
  tree     what the submodule checkout actually holds   (git -C <path> rev-parse HEAD)
  upstream the shared repo's branch tip on its remote   (git -C <path> ls-remote origin)

and one reachability fact that the four values cannot express: whether the recorded gitlink
exists on the shared repo's remote at all. A parent pushed with a gitlink that only exists on
one machine is the failure mode this gate exists for - it does not error, it breaks the next
clone and the next CI job.

The toolkit `include: ref:` pins are a second pin mechanism (they are not in .gitmodules) and
get the same reachability test, with "behind the toolkit tip" reported as drift rather than a
failure, because pinning an older toolkit is a legitimate state.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

PLAY_ROOT = Path(os.environ.get("MAGISK_PLAY_ROOT", "/root/play"))
FLEET_CHECKER = PLAY_ROOT / "tools" / "check_shared_submodules.py"
TOOLKIT_SOURCE = PLAY_ROOT / "magisk-ci-toolkit"
INCLUDE_REF = re.compile(r"ref:\s*['\"]?([0-9a-f]{40})['\"]?")


def git(repo: Path, *args: str) -> tuple[str, int]:
    try:
        done = subprocess.run(
            ["git", "-C", str(repo), *args],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:  # git missing
        return "", 127
    return (done.stdout or "").strip(), done.returncode


def short(sha: str) -> str:
    return sha[:9] if sha and len(sha) >= 9 else (sha or "-")


def current_branch(repo: Path) -> str | None:
    name, rc = git(repo, "rev-parse", "--abbrev-ref", "HEAD")
    if rc != 0 or name in ("HEAD", ""):
        return None
    return name


def submodule_paths(repo: Path) -> list[tuple[str, str, str]]:
    """[(name, path, branch)] from .gitmodules; branch defaults to main."""
    out, rc = git(repo, "config", "-f", ".gitmodules", "--get-regexp", r"^submodule\..*\.(path|branch)$")
    if rc != 0:
        return []
    meta: dict[str, dict[str, str]] = {}
    for line in out.splitlines():
        key, _, value = line.partition(" ")
        parts = key.split(".")
        name = ".".join(parts[1:-1])
        meta.setdefault(name, {})[parts[-1]] = value.strip()
    rows = []
    for name, fields in sorted(meta.items()):
        path = fields.get("path")
        if not path:
            continue
        rows.append((name, path, fields.get("branch", "main")))
    return rows


def gitlink(repo: Path, ref: str, path: str) -> str:
    out, rc = git(repo, "ls-tree", ref, "--", path)
    if rc != 0:
        return ""
    parts = out.split()
    return parts[2] if len(parts) >= 3 and parts[0] == "160000" else ""


def checkout_head(sub: Path) -> str:
    head, rc = git(sub, "rev-parse", "HEAD")
    if rc != 0:
        return ""
    top, rc = git(sub, "rev-parse", "--show-toplevel")
    if rc != 0 or Path(top).resolve() != sub.resolve():
        return ""
    return head


def remote_tip(sub: Path, branch: str, live: bool) -> tuple[str, str]:
    """(sha, provenance). live asks the remote, cached reads the fetched ref."""
    if live:
        out, rc = git(sub, "ls-remote", "origin", "refs/heads/%s" % branch)
        if rc == 0 and out:
            return out.split()[0], "remote"
    out, rc = git(sub, "rev-parse", "refs/remotes/origin/%s" % branch)
    return (out if rc == 0 else ""), "cached"


def reachable(sub: Path, sha: str, live: bool) -> bool | None:
    """True/False once the remote refs are known; None when it cannot be judged.

    The submodule copy must be fetched first. It usually only holds the refs that were current
    when the pin was last moved, so testing reachability against stale refs reports a published
    commit as missing - which is exactly what this gate would then refuse a push for.
    """
    if live:
        git(sub, "fetch", "--quiet", "origin")
    out, rc = git(sub, "branch", "-r", "--contains", sha)
    if rc != 0:
        return None
    return bool(out.strip())


def evaluate(repo: Path, live: bool) -> tuple[list[str], list[str], list[str]]:
    rows, drift, failures = [], [], []
    branch = current_branch(repo)
    if branch is None:
        return rows, drift, ["detached HEAD - cannot map the recorded branch"]
    upstream_ref = "refs/remotes/origin/%s" % branch
    git(repo, "fetch", "--quiet", "origin", branch)
    remote_branch = "origin/%s" % branch
    has_remote_branch = git(repo, "rev-parse", "--verify", remote_branch)[1] == 0

    for name, path, sub_branch in submodule_paths(repo):
        sub = repo / path
        local = gitlink(repo, "HEAD", path)
        remote = gitlink(repo, remote_branch, path) if has_remote_branch else ""
        tree = checkout_head(sub) if sub.is_dir() else ""
        tip, provenance = remote_tip(sub, sub_branch, live) if sub.is_dir() else ("", "-")
        rows.append(
            "  %-18s local=%s remote=%s tree=%s %s=%s"
            % (name, short(local), short(remote) if has_remote_branch else "(none)",
               short(tree), provenance, short(tip))
        )
        if not local:
            failures.append("%s: no gitlink recorded at %s" % (name, path))
            continue
        if tree and tree != local:
            failures.append("%s: checkout %s != recorded %s (uncommitted submodule move)"
                            % (name, short(tree), short(local)))
        if has_remote_branch and remote and remote != local:
            drift.append("%s: HEAD records %s, %s on origin/%s records %s"
                         % (name, short(local), "beta" if branch == "beta" else branch,
                            branch, short(remote)))
        if tip and local != tip:
            behind_raw, rc1 = git(sub, "rev-list", "--count", "%s..origin/%s" % (local, sub_branch))
            ahead_raw, rc2 = git(sub, "rev-list", "--count", "origin/%s..%s" % (sub_branch, local))
            if rc1 == rc2 == 0 and behind_raw.isdigit() and ahead_raw.isdigit():
                relation = "behind=%s" % behind_raw if int(behind_raw) >= int(ahead_raw) else "ahead=%s (not pushed yet)" % ahead_raw
            else:
                relation = "different lineage"
            drift.append("%s: pin %s is not the shared-repo tip %s (%s)"
                         % (name, short(local), short(tip), relation))
        if sub.is_dir() and reachable(sub, local, live) is False:
            failures.append(
                "%s: pin %s is on no remote branch of %s - push the shared repo first, "
                "otherwise clone/CI cannot resolve it" % (name, short(local), path)
            )

    for ci in (repo / ".gitlab-ci.yml",):
        if not ci.is_file():
            continue
        for pin in sorted(set(INCLUDE_REF.findall(ci.read_text(encoding="utf-8", errors="replace")))):
            if not TOOLKIT_SOURCE.is_dir():
                break
            tip, provenance = remote_tip(TOOLKIT_SOURCE, "main", live)
            sub = repo / ".magisk-ci-toolkit"
            probe = TOOLKIT_SOURCE
            rows.append("  %-18s toolkit include ref=%s %s=%s"
                        % ("ci-toolkit", short(pin), provenance, short(tip)))
            if tip and pin != tip:
                drift.append("ci-toolkit: .gitlab-ci.yml pins %s, toolkit tip is %s"
                             % (short(pin), short(tip)))
            if reachable(probe, pin, live) is False:
                failures.append("ci-toolkit: pinned ref %s is not reachable on the toolkit remote"
                                % short(pin))
            break
    return rows, drift, failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("post-commit", "pre-push"), required=True)
    parser.add_argument("--repo", default=os.getcwd())
    parser.add_argument("--quiet-clean", action="store_true", help="print only when something is wrong")
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    live = args.mode == "pre-push"
    title = "submodule pointer gate (%s) - %s" % (args.mode, repo.name)
    rows, drift, failures = evaluate(repo, live)

    if args.mode == "pre-push" and FLEET_CHECKER.is_file():
        done = subprocess.run(
            [sys.executable, str(FLEET_CHECKER)],
            capture_output=True,
            text=True,
            check=False,
        )
        if done.returncode != 0:
            failures.append("fleet checker (%s) exited %d:\n%s"
                            % (FLEET_CHECKER.name, done.returncode, (done.stdout + done.stderr).strip()))

    if not rows and not failures:
        if not args.quiet_clean:
            print("%s: no submodules to check" % title)
        return 0

    if not args.quiet_clean or drift or failures:
        print(title)
        for row in rows:
            print(row)

    blocking = args.mode == "pre-push"
    for message in failures:
        print("FAIL %s" % message, file=sys.stderr)
    for message in drift:
        print("%s %s" % ("DRIFT" if blocking else "note ", message), file=sys.stderr)

    if blocking and failures:
        print("push refused: fix the pointers above (shared repos first, then the parents)",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
