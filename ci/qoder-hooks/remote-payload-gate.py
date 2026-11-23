#!/usr/bin/env python3
"""PreToolUse gate: keep fragile payloads off remote-shell boundaries.

Every time a command crosses a remote shell boundary (ssh, docker run/exec
sh -c, adb shell su -c) while carrying nested quotes, escapes, expansions or
a heredoc, some layer of the chain eats part of it. Measured on this fleet:

  * heredoc bodies sent through ssh keep backslash escapes verbatim
    (`package\\x27s` landed in a commit message -- see canonical
    feedback-commit-message-approval-first);
  * nested quotes inside `adb shell su -c "..."` are stripped by the device
    shell, silently turning a grep pattern into separate arguments;
  * `$2`/`$(...)` inside double quotes is expanded by the LOCAL shell before
    ssh ever sees it.

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
# su -c payload whose quoting nests another quote inside: `su -c "grep -E 'a|b' f"`.
# A simple single-family payload (`su -c 'ls -l /p'`) must stay allowed.
SU_C_NESTED_QUOTE_RE = re.compile(r"\bsu\s+-c\s+(['\"])(?:(?!\1).)*['\"](?:(?!\1).)*\1")
DOLLAR_IN_DOUBLE_RE = re.compile(r"\"[^\"\n]*\$[(\w]")

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
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            buf.append(ch)
            i += 1
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


def is_remote(statement: str) -> bool:
    words = statement.split()
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
    if SU_C_NESTED_QUOTE_RE.search(statement):
        hits.append("nested quotes inside su -c (stripped by the device shell)")
    if DOLLAR_IN_DOUBLE_RE.search(statement):
        hits.append("$ expansion inside double quotes (expanded locally first)")
    return hits


def evaluate(command: str):
    if os.environ.get("QODER_REMOTE_PAYLOAD_GATE", "") == "off":
        return False, ""
    if "# gate:allow" in command:
        return False, ""
    for statement in statements(command):
        if not is_remote(statement):
            continue
        hits = fragile_hits(statement)
        if not hits:
            continue
        return True, (
            "远端执行语句不许携带易碎载荷（命中：" + ", ".join(hits) + "）。\n"
            f"问题语句：{' '.join(statement.split())[:160]}\n"
            "这类载荷穿过 ssh / docker / adb 边界时会被某一层 shell 吃掉或原样带过去"
            "（本舰队实测：\\x27 原样进过 commit message、su -c 内嵌引号被剥、"
            "$2 被本地 shell 展开）。改成历来每次都能救场的形状："
            "① 用 Write 把远端脚本写到本地文件；② scp 到目标机；③ 远端 bash 执行该文件。"
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
        ("adb -s bc569ae8 shell pm list packages", False),
        ("adb -s bc569ae8 shell su -c 'ls -l /data/user/0/com.xiaomi.xmsf/files/log/'", False),
        ("ssh debian 'ls' # gate:allow", False),
        ("ssh debian 'cat <<EOF' # gate:allow", False),
        ("cat > /tmp/local.txt <<EOF\nlocal heredoc is fine\nEOF", False),
        ("docker ps", False),
        ("adb devices", False),
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
    if payload.get("tool_name") not in ("Bash", "mcp__node-repl__node_repl"):
        return 0
    command = ((payload.get("tool_input") or {}).get("command")) or ""
    if not isinstance(command, str) or not command.strip():
        return 0
    deny, reason = evaluate(command)
    if not deny:
        return 0
    sys.stderr.write(reason + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
