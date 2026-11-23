#!/usr/bin/env python3
"""PreToolUse gate: keep fragile payloads off remote-shell boundaries.

Every time a command crosses a remote shell boundary (ssh, docker run/exec
sh -c, adb shell su -c) while carrying nested quotes, escapes, expansions,
command substitution or a heredoc, some layer of the chain eats part of it.
Measured on this fleet:

  * heredoc bodies sent through ssh keep backslash escapes verbatim
    (`package\\x27s` landed in a commit message -- see canonical
    feedback-commit-message-approval-first);
  * nested quotes inside `adb shell su -c "..."` are stripped by the device
    shell, silently turning a grep pattern into separate arguments;
  * `$2`/`$(...)` inside double quotes is expanded by the LOCAL shell before
    ssh ever sees it;
  * command substitution of any quote style is the recurring class: commit
    messages and scripts smuggled through `$(cat ...)` inside an ssh payload
    work by luck and break on the next quoting shift, so the whole class is
    refused regardless of quoting.

The pattern that has worked every time: write the remote script to a local
file (Write tool), scp it, execute the file remotely. This gate refuses the
fragile shapes so that pattern becomes the default.

Scope: only statements that actually cross a remote boundary are checked;
plain `ssh host 'ls'` and `scp` (the prescribed fix) always pass.

Escape hatches:
  * `# gate:allow` anywhere in the command -- one-off override, stays visible.
  * QODER_REMOTE_PAYLOAD_GATE=off            -- global off switch.

Exit code: 2 = deny (stderr becomes the reason shown to the model), 0 = allow.
"""
import json
import os
import re
import sys

# Subcommands that make docker/adb a remote-shell boundary. Plain
# `docker ps` / `adb devices` / `adb install x.apk` are not.
DOCKER_REMOTE_SUB = {"run", "exec"}
ADB_SHELL_RE = re.compile(r"\badb\b[^|;&]*\bshell\b")

# Fragile payload shapes, each with the reason it cannot survive the trip.
HEREDOC_RE = re.compile(r"<<-?\s*['\"]?\w+")
HEX_ESCAPE_RE = re.compile(r"\\x[0-9a-fA-F]{2}")
# Command substitution of any quote style. The double-quoted variant is expanded
# by the LOCAL shell before ssh sees it; the single-quoted variant survives
# locally but then depends on remote file state and remote shell semantics.
# Both are the same class the fleet keeps re-learning (commit messages and
# scripts smuggled through `$(cat ...)` inside an ssh payload), so both are
# refused; the prescribed shape replaces all of them.
COMMAND_SUB_RE = re.compile(r"\$\(|`")
# su -c payload whose quoting nests another quote inside: `su -c "grep -E 'a|b' f"`.
# A simple single-family payload (`su -c 'ls -l /p'`) must stay allowed.
SU_C_NESTED_QUOTE_RE = re.compile(r"\bsu\s+-c\s+(['\"])(?:(?!\1).)*['\"](?:(?!\1).)*\1")
DOLLAR_IN_DOUBLE_RE = re.compile(r"\"[^\"\n]*\$[(\w]")

HEREDOC_START_RE = re.compile(r"<<-?\s*(['\"]?)(\w+)\1")


def statements(command: str) -> list[str]:
    """Split into statements on ; && || newline and pipe-subshell -- but only
    outside quotes. A quote-naive splitter cuts `ssh host 'a && b'` in half and
    the second fragment loses its remote context, which is exactly the shape
    that bit in practice."""
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
                # Escaped quote inside double quotes: keep both characters so
                # `python3 -c "print(\"hi\")"` stays one statement.
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
                # Keep the whole heredoc (header + body + delimiter line) inside
                # the current statement: the body lines are data, not commands,
                # and splitting them produced false local statements.
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
    return [part for part in (p.strip() for p in parts) if part]


WRAPPERS = {"timeout", "sudo", "env", "nohup", "nice", "ionice", "stdbuf", "setsid", "nix"}


def is_remote(statement: str) -> bool:
    words = statement.split()
    while words and (words[0] in WRAPPERS or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0])):
        words = words[1:]
    if not words:
        return False
    head = os.path.basename(words[0])
    if head == "ssh":
        return True
    if head == "docker":
        return any(w in DOCKER_REMOTE_SUB for w in words[1:4])
    if head == "adb":
        return ADB_SHELL_RE.search(statement) is not None
    return False


def fragile_hits(statement: str):
    hits = []
    if HEREDOC_RE.search(statement):
        hits.append("heredoc")
    if HEX_ESCAPE_RE.search(statement):
        hits.append("hex escape (\\xNN is never interpreted by bash)")
    if COMMAND_SUB_RE.search(statement):
        hits.append("command substitution (write the payload to a local file and scp it)")
    if SU_C_NESTED_QUOTE_RE.search(statement):
        hits.append("nested quotes inside su -c (stripped by the device shell)")
    if DOLLAR_IN_DOUBLE_RE.search(statement):
        hits.append("$ expansion inside double quotes (expanded locally first)")
    return hits


# Local statements have their own quoting traps (the remote rules do not cover
# them): `python3 -c "..."` with escaped inner quotes is the fleet's single
# biggest tool-failure class (102 SyntaxErrors in one IDE's history), and a
# positional `$1`/`$2` inside double quotes is eaten by zsh before the command
# ever runs. A local heredoc is the PRESCRIBED fix shape, so it stays allowed.
C_PAYLOAD_RE = re.compile(r"-c\s+\"((?:[^\"\\]|\\.)*)\"")
ESCAPED_QUOTE_RE = re.compile(r"\\\"")
DOLLAR_DIGIT_IN_DOUBLE_RE = re.compile(r"\"[^\"\n]*\$[0-9]")
BACKTICK_IN_DOUBLE_RE = re.compile(r"\"[^\"\n]*`")


PROGRAM_WORDS = ("awk", "gawk", "sed", "perl", "ruby")
QUOTED_ARG_RE = re.compile(r"\"((?:[^\"\\]|\\.)*)\"")


def _program_arg_dollar_hit(statement: str) -> bool:
    """True when a $N sits inside a double-quoted argument OF an awk/sed/perl
    command itself (not merely somewhere in a long compound command)."""
    for stage in re.split(r"[|;]", statement):
        tokens = stage.strip().split()
        idx = 0
        while idx < len(tokens) and (tokens[idx].startswith("-") or "=" in tokens[idx].split("/")[-1]):
            idx += 1
        if idx >= len(tokens):
            continue
        if os.path.basename(tokens[idx]) not in PROGRAM_WORDS:
            continue
        for arg in QUOTED_ARG_RE.findall(stage):
            if re.search(r"\$[0-9]", arg):
                return True
    return False


def strip_heredoc_bodies(command: str) -> str:
    """Blank out heredoc bodies: they are data (script text being written),
    not shell to execute, so their quotes and backticks must not be judged.
    Quote-aware, so `echo "a << b"` is not mistaken for a heredoc."""
    out = []
    i = 0
    n = len(command)
    quote = None
    while i < n:
        ch = command[i]
        if quote is not None:
            out.append(ch)
            if ch == "\\" and quote == "\"" and i + 1 < n:
                out.append(command[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            out.append(ch)
            i += 1
            continue
        if ch == "<" and command.startswith("<<", i):
            heredoc = HEREDOC_START_RE.match(command, i)
            if heredoc:
                delim = heredoc.group(2)
                newline = command.find("\n", heredoc.end())
                if newline == -1:
                    out.append(command[i:])
                    break
                out.append(command[i:newline])
                pos = newline + 1
                end = n
                while pos < n:
                    line_end = command.find("\n", pos)
                    if line_end == -1:
                        line_end = n
                    if command[pos:line_end].strip() == delim:
                        end = line_end
                        break
                    pos = line_end + 1
                out.append("\n")
                i = end
                continue
        out.append(ch)
        i += 1
    return "".join(out)


def local_fragile_hits(statement: str):
    hits = []
    statement = strip_heredoc_bodies(statement)
    # A positional $N inside double quotes wrapping another language's program
    # text (awk/sed/perl) is silently expanded by the local shell: the command
    # exits 0 with a wrong result, which is worse than an error. Plain shell
    # positional params are legitimate and stay allowed. (An escaped-quote rule
    # for local `-c` payloads was removed after the replay corpus showed ~1300
    # false positives: zsh handles \" correctly locally; the real bite is the
    # remote layer, which the remote rules already cover.)
    if _program_arg_dollar_hit(statement):
        hits.append("positional $N inside an awk/sed/perl quoted argument (silently expanded by the local shell)")
    if BACKTICK_IN_DOUBLE_RE.search(statement):
        hits.append("backticks inside double quotes (expanded by the local shell first)")
    return hits


def evaluate(command: str):
    if os.environ.get("QODER_REMOTE_PAYLOAD_GATE", "") == "off":
        return False, ""
    if "# gate:allow" in command:
        return False, ""
    for statement in statements(command):
        if is_remote(statement):
            hits = fragile_hits(statement)
            if not hits:
                continue
            return True, (
                "远端执行语句不许携带易碎载荷（命中：" + ", ".join(hits) + "）。\n"
                f"问题语句：{' '.join(statement.split())[:160]}\n"
                "这类载荷穿过 ssh / docker / adb 边界时会被某一层 shell 吃掉或原样带过去"
                "（本舰队实测：\\x27 原样进过 commit message、su -c 内嵌引号被剥、"
                "$(cat ...) 把 commit message/脚本偷渡进远端命令行）。改成历来每次都能救场的形状："
                "① 用 Write 把远端脚本或提交信息写到本地文件；② scp 到目标机；③ 远端 bash 执行该文件"
                "（提交用 git commit -F <scp 过去的文件>）。"
                "一次性放行：命令里加 `# gate:allow`；全局关闭：QODER_REMOTE_PAYLOAD_GATE=off。"
            )
        hits = local_fragile_hits(statement)
        if not hits:
            continue
        return True, (
            "本地语句不许携带会被本地 shell 吃掉的载荷（命中：" + ", ".join(hits) + "）。\n"
            f"问题语句：{' '.join(statement.split())[:160]}\n"
            "这是本舰队实测最高频的工具失败类（单个 IDE 历史里 102 次 SyntaxError + awk 位置参数被 zsh 展开）。"
            "正确形状：① 用 Write 把脚本落到本地 .py/.sh 文件；② 直接执行该文件"
            "（python3 /tmp/x.py，不要 python3 -c \"...\"）。"
            "一次性放行：命令里加 `# gate:allow`；全局关闭：QODER_REMOTE_PAYLOAD_GATE=off。"
        )
    return False, ""


def selftest() -> int:
    cases = [
        # (command, expect_deny)
        ("ssh debian 'cat > /tmp/x.txt <<EOF\nhello\nEOF'", True),
        ("ssh debian 'python3 - <<PYEOF\nprint(1)\nPYEOF'", True),
        ("ssh debian 'bash -s <<EOF && package\\x27s'", True),
        ("adb -s bc569ae8 shell su -c \"grep -E 'a|b' /data/x\"", True),
        ("adb -s bc569ae8 shell su -c 'grep -c -e \"a\" -e \"b\" /data/x'", True),
        ("ssh debian 'cd /r && awk -F'\"'\"' \"{s+=\\$2}\"'", True),
        ("ssh debian 'grep -c foo /var/log | awk \"{s+=\\$2}\"'", True),
        ("docker run --rm -v /a:/b img sh -c \"echo $HOME\"", True),
        ("ssh -o BatchMode=yes debian 'ls -la /tmp'", False),
        ("ssh debian 'cd /root/play/push/MiPushFramework && git status --short'", False),
        ("scp -q /tmp/warnfix/x.py debian:/tmp/x.py", False),
        ("ssh debian 'cat /tmp/msg.txt'", False),
        ("adb -s bc569ae8 shell pm list packages", False),
        ("adb -s bc569ae8 shell su -c 'ls -l /data/user/0/com.xiaomi.xmsf/files/log/'", False),
        ("ssh debian 'ls' # gate:allow", False),
        ("ssh debian 'cat <<EOF' # gate:allow", False),
        ("cat > /tmp/local.txt <<EOF\nlocal heredoc is fine\nEOF", False),
        ("docker ps", False),
        ("adb devices", False),
        # Command substitution is refused regardless of quote style: the
        # single-quoted variant used to slip through and is exactly the shape
        # that kept smuggling commit messages into remote command lines.
        ("ssh debian 'git commit -m \"$(cat /tmp/msg.txt)\"'", True),
        ("ssh debian 'git commit -m $(cat /tmp/msg.txt)'", True),
        ("ssh debian 'echo `date`'", True),
        ("ssh debian 'bash /tmp/run.sh && cat /tmp/out.txt'", False),
        # Local quoting traps (H1): the fleet's biggest tool-failure class.
        # Note: a local `python3 -c "...\"x\"..."` is ALLOWED -- zsh handles the
        # escape correctly locally (replay evidence: ~1300 such commands
        # succeeded); the real bite is the remote layer, covered above.
        ("python3 -c \"import json; print(json.dumps({\\\"a\\\": 1}))\"", False),
        ("python3 -c \"print(\\\"hi\\\")\"", False),
        ("bash -c \"echo \\\"x\\\"\"", False),
        ("awk \"{s+=\\$2} END {print s}\" /var/log/x", True),
        ("grep -c foo /var/log | awk \"{print \\$1}\"", True),
        ("sed \"s/x/\\$1/\" /var/log/x", True),
        ("sed -e \"s/a/\\1/\" /var/log/x", False),
        ("awk -F'\\\"' '{print $2}' /var/log/x", False),
        ("cat > /tmp/x.sh <<'EOF'\necho \"`date`\"\nEOF", False),
        ("python3 - <<'PY'\nprint(\"a $1 b\")\nPY", False),
        ("python3 /tmp/extract.py --repo /a --out /b", False),
        ("python3 -c 'print(1)'", False),
        ("VAR=hello; echo \"$VAR\"", False),
        ("echo \"done\"", False),
        ("grep -rn \"foo\" /var/log", False),
    ]
    failures = 0
    for command, expect in cases:
        got, _ = evaluate(command)
        mark = "ok  " if got == expect else "FAIL"
        if got != expect:
            failures += 1
        print("  %s deny=%-5s expect=%-5s %s" % (mark, got, expect, command.splitlines()[0][:70]))
    # Kill switch must be honored by a fresh process (env is read per call).
    import subprocess
    proc = subprocess.run(
        [sys.executable, os.path.abspath(__file__)],
        input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "ssh debian 'cat <<EOF'"}}),
        capture_output=True, text=True,
        env=dict(os.environ, QODER_REMOTE_PAYLOAD_GATE="off"),
    )
    if proc.returncode != 0:
        failures += 1
        print("  FAIL kill switch did not disable the gate (rc=%d)" % proc.returncode)
    else:
        print("  ok   kill switch disables the gate")
    # A fresh process without the env must actually deny (proves main() wiring).
    proc = subprocess.run(
        [sys.executable, os.path.abspath(__file__)],
        input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "ssh debian 'cat <<EOF'"}}),
        capture_output=True, text=True,
    )
    if proc.returncode != 2 or "易碎载荷" not in proc.stderr:
        failures += 1
        print("  FAIL main() did not deny a fragile payload (rc=%d)" % proc.returncode)
    else:
        print("  ok   main() denies a fragile payload with a reason")
    print("selftest: %d case(s), %d failure(s)" % (len(cases) + 2, failures))
    return 1 if failures else 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    tool_name = payload.get("tool_name")
    command = ((payload.get("tool_input") or {}).get("command")) or ""
    if not isinstance(command, str) or not command.strip():
        return 0
    # Qoder/Claude-style payloads carry tool_name; CodeBuddy's documented shape
    # shows only tool_input.command, so a missing name must not silently allow.
    if tool_name is not None and tool_name not in ("Bash", "mcp__node-repl__node_repl"):
        return 0
    deny, reason = evaluate(command)
    if not deny:
        return 0
    sys.stderr.write(reason + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
