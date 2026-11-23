#!/usr/bin/env python3
"""PreToolUse gate: stop git detached-HEAD checkouts and reads of paths that
do not exist.

Both rules come from repeatedly measured assistant mistakes in this fleet's
own session history:

  * `git checkout <raw-sha>` during a reproduction run leaves the repo on a
    detached HEAD; the next commit lands on no branch. A token that resolves
    to a commit but is not a local branch is refused; explicit `--detach` and
    real branch names pass.
  * Reading a path that does not exist (Read tool, or `cat`/`less` on a
    guessed path) was one of the largest tool-failure classes (91 "No such
    file or directory" in a single IDE's history). The path is checked before
    the tool runs and the fix is prescribed: Glob first.

Escape hatches:
  * `# gate:allow` anywhere in the command -- one-off override.
  * QODER_PRE_EXEC_GATE=off                 -- global off switch.

Exit code: 2 = deny (stderr becomes the reason shown to the model), 0 = allow.
"""
import json
import os
import re
import subprocess
import sys

GIT_VERB_RE = re.compile(r"\bgit\s+(?:checkout|co|switch)\s+(?P<args>[^|;&]+)")
SHA_RE = re.compile(r"^[0-9a-f]{7,40}$")
HEAD_RELATIVE_RE = re.compile(r"^HEAD([~^].*)?$")
READER_RE = re.compile(r"^(?:cat|less|more|stat|source|\.)\s+(?P<path>/[^\s;|&]+|\.[^\s;|&]+|[A-Za-z0-9_][\w./-]*)\s*$")
REMOTE_HEAD_RE = re.compile(r"^(?:ssh|docker|adb)\b")
HEREDOC_START_RE = re.compile(r"<<-?\s*(['\"]?)(\w+)\1")
WRAPPERS = {"timeout", "sudo", "env", "nohup", "nice", "ionice", "stdbuf", "setsid", "nix"}


def is_remote_statement(statement: str) -> bool:
    """Paths inside a remote payload do not exist locally; only check local ones."""
    words = statement.split()
    while words and (words[0] in WRAPPERS or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0])):
        words = words[1:]
    if not words:
        return False
    head = os.path.basename(words[0])
    if head in ("ssh", "docker", "adb"):
        return True
    return REMOTE_HEAD_RE.match(statement.strip()) is not None


def statements(command: str):
    """Quote-aware split on ; && || newline (mirrors remote-payload-gate)."""
    parts = []
    buf = []
    quote = None
    i = 0
    n = len(command)
    while i < n:
        ch = command[i]
        if quote is not None:
            buf.append(ch)
            if ch == "\\" and quote == "\"" and i + 1 < n:
                buf.append(command[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            buf.append(ch)
            i += 1
            continue
        if ch == "<" and command.startswith("<<", i):
            heredoc = HEREDOC_START_RE.match(command, i)
            if heredoc:
                # Keep the whole heredoc inside the current statement: its body
                # lines are data, not commands (splitting them produced false
                # local statements and wrong path checks).
                delim = heredoc.group(2)
                newline = command.find("\n", heredoc.end())
                if newline == -1:
                    i = n
                    continue
                end = n
                pos = newline + 1
                while pos < n:
                    line_end = command.find("\n", pos)
                    if line_end == -1:
                        line_end = n
                    if command[pos:line_end].strip() == delim:
                        end = line_end
                        break
                    pos = line_end + 1
                buf.append(command[i:end])
                i = end
                continue
        if ch == "\n" or ch == ";":
            parts.append("".join(buf))
            buf = []
            i += 1
            continue
        if command.startswith("&&", i) or command.startswith("||", i):
            parts.append("".join(buf))
            buf = []
            i += 2
            continue
        subshell = re.match(r"\|\s*\(", command[i:])
        if subshell:
            parts.append("".join(buf))
            buf = []
            i += subshell.end()
            continue
        buf.append(ch)
        i += 1
    parts.append("".join(buf))
    return [p.strip() for p in parts if p.strip()]


def is_local_branch(token: str) -> bool:
    try:
        proc = subprocess.run(
            ["git", "show-ref", "--verify", "refs/heads/%s" % token],
            capture_output=True, text=True, timeout=5,
        )
        return proc.returncode == 0
    except Exception:
        return False


def is_commit(token: str) -> bool:
    try:
        proc = subprocess.run(
            ["git", "cat-file", "-e", "%s^{commit}" % token],
            capture_output=True, text=True, timeout=5,
        )
        return proc.returncode == 0
    except Exception:
        return False


def in_git_repo() -> bool:
    try:
        proc = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        return proc.returncode == 0
    except Exception:
        return False


def detached_head_hit(statement: str):
    match = GIT_VERB_RE.search(statement)
    if not match:
        return None
    args = match.group("args").split()
    if any(a in ("--detach", "-d") for a in args):
        return None  # explicit intent
    if any(a in ("-b", "-B", "-c", "-C", "--track", "--orphan") for a in args):
        return None  # creating or reconfiguring a branch
    token = next((a for a in args if not a.startswith("-")), None)
    if not token:
        return None
    if HEAD_RELATIVE_RE.match(token):
        return token
    if not SHA_RE.match(token):
        return None
    if not in_git_repo():
        return token  # no repo context: trust the shape heuristic
    if is_local_branch(token):
        return None
    if not is_commit(token):
        return None  # in a repo but unresolvable: git's own error is clear enough
    return token


def missing_path_hit(statement: str, cwd: str):
    if is_remote_statement(statement):
        return None
    match = READER_RE.match(statement.strip())
    if not match:
        return None
    path = match.group("path")
    if path.startswith(("/dev/", "/proc/", "/sys/")):
        return None
    resolved = path if os.path.isabs(path) else os.path.join(cwd or ".", path)
    if os.path.exists(resolved):
        return None
    return path


def evaluate(command: str, cwd: str = ""):
    if os.environ.get("QODER_PRE_EXEC_GATE", "") == "off":
        return False, ""
    if "# gate:allow" in command:
        return False, ""
    stmts = statements(command)
    for index, statement in enumerate(stmts):
        token = detached_head_hit(statement)
        if token:
            return True, (
                "git checkout/switch 打到游离 HEAD 上会被拒（命中：%s 是提交对象但不是本地分支）。\n"
                f"问题语句：{' '.join(statement.split())[:160]}\n"
                "本舰队实测踩过：复现/比对时 `git checkout <sha>`，之后的提交全部落在游离 HEAD 上，"
                "分支看不到。正确形状：① `git switch -c <new-branch> <sha>` 建分支；"
                "② 或 `git worktree add <dir> <sha>` 开独立工作树；确要游离就显式 `--detach`。"
                "一次性放行：命令里加 `# gate:allow`；全局关闭：QODER_PRE_EXEC_GATE=off。"
                % token
            )
        # The Bash reader check runs only for a standalone reader command: in a
        # compound like `gen.sh && cat out.txt` an earlier stage may create the
        # file, and blocking that read would be a false positive.
        if index == 0 and len(stmts) == 1:
            path = missing_path_hit(statement, cwd)
            if path:
                return True, (
                    "读取不存在的本地路径会被拒（命中：%s 不存在）。\n"
                    f"问题语句：{' '.join(statement.split())[:160]}\n"
                    "「猜路径」是本舰队实测的高频失败类（单个 IDE 历史 91 次 No such file）。"
                    "正确形状：先用 Glob/Grep 确认真实路径再读；确认要创建的文件用 Write 而不是 cat。"
                    "一次性放行：命令里加 `# gate:allow`；全局关闭：QODER_PRE_EXEC_GATE=off。"
                    % path
                )
    return False, ""


def selftest() -> int:
    failures = 0

    def check(command, expect, cwd="", note=""):
        nonlocal failures
        got, _ = evaluate(command, cwd)
        mark = "ok  " if got == expect else "FAIL"
        if got != expect:
            failures += 1
        print("  %s deny=%-5s expect=%-5s %s %s" % (mark, got, expect, command.splitlines()[0][:64], note))

    print("H2 detached-HEAD cases (no git repo: heuristic path):")
    check("git checkout -q 06da13b", True)
    check("git checkout 905ddd98ba29b1dd38a9a9d81243656869c226e5", True)
    check("git checkout HEAD~1", True)
    check("git switch 1a2b3c4", True)
    check("git checkout beta", False)
    check("git checkout -b fix/x 905ddd98b", False)
    check("git checkout --detach 905ddd98b", False)
    check("git checkout -- .", False)
    check("git status --short", False)
    check("git switch -c newbranch", False)

    print("H5 missing-path cases:")
    tmp = os.path.exists("/tmp") and "/tmp" or "."
    check("cat %s/definitely-not-here-12345.txt" % tmp, True)
    check("less %s/definitely-not-here-12345.txt" % tmp, True)
    check("stat %s/definitely-not-here-12345.txt" % tmp, True)
    check("cat /etc/hosts", False)
    check("cat /dev/null", False)
    check("grep -c foo /var/log/syslog", False)
    check("cat /etc/hostname /etc/hosts", False)
    check("cat < /etc/hostname", False)

    print("escape valves:")
    check("git checkout 06da13b # gate:allow", False)

    import subprocess
    proc = subprocess.run(
        [sys.executable, os.path.abspath(__file__)],
        input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "git checkout 06da13b"}, "cwd": "/tmp"}),
        capture_output=True, text=True,
        env=dict(os.environ, QODER_PRE_EXEC_GATE="off"),
    )
    if proc.returncode != 0:
        failures += 1
        print("  FAIL kill switch did not disable the gate")
    else:
        print("  ok   kill switch disables the gate")

    # Real-repo precision: inside a git repo a raw sha that is not a branch is
    # still refused, while a real branch name passes.
    repo = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if repo.returncode == 0:
        top = repo.stdout.strip()
        sha = subprocess.run(["git", "-C", top, "rev-parse", "--short=7", "HEAD"], capture_output=True, text=True).stdout.strip()
        branch = subprocess.run(["git", "-C", top, "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True).stdout.strip()
        if sha:
            check("git checkout %s" % sha, True, cwd=top, note="(real repo, raw sha)")
        if branch and branch != "HEAD":
            check("git checkout %s" % branch, False, cwd=top, note="(real repo, real branch)")

    print("selftest: %d failure(s)" % failures)
    return 1 if failures else 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    tool_name = payload.get("tool_name")
    cwd = payload.get("cwd") or ""
    if tool_name == "Read":
        path = (payload.get("tool_input") or {}).get("file_path") or ""
        if not path or path.startswith(("http://", "https://")):
            return 0
        resolved = path if os.path.isabs(path) else os.path.join(cwd or ".", path)
        if os.path.exists(resolved):
            return 0
        sys.stderr.write(
            "读取不存在的本地路径会被拒（命中：%s 不存在）。\n"
            "「猜路径」是本舰队实测的高频失败类（单个 IDE 历史 91 次 No such file）。\n"
            "正确形状：先用 Glob/Grep 确认真实路径再 Read；要创建的文件用 Write。\n"
            "一次性放行：命令里加 `# gate:allow`（对 Read 无效时用 Glob 代替）；"
            "全局关闭：QODER_PRE_EXEC_GATE=off。\n" % path
        )
        return 2
    command = ((payload.get("tool_input") or {}).get("command")) or ""
    if not isinstance(command, str) or not command.strip():
        return 0
    if tool_name is not None and tool_name not in ("Bash", "run_in_terminal", "mcp__node-repl__node_repl"):
        return 0
    deny, reason = evaluate(command, cwd)
    if not deny:
        return 0
    sys.stderr.write(reason + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
