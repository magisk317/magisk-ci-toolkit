#!/usr/bin/env python3
"""PostToolUse / PostToolUseFailure gate: make silent failures visible.

Three rules, each from repeatedly measured assistant mistakes in this fleet's
own session history (40,601 replayed Bash calls):

  H3 build-fail: 528 historical commands exited 0 (status=completed) while
     their output contained BUILD FAILED / FAILURE:. The agent then reported
     success. This gate rewrites the tool output the agent sees (via
     updatedToolOutput) and adds feedback, so a false green cannot pass.
  H4 repeat-failure: the same normalized command shape failing twice within
     10 minutes means "change approach", not "retry". A state file tracks
     shapes; the second identical failure injects that instruction.
  H6 empty-output: a command that succeeded but printed nothing, and is not
     in the known-silent or empty-is-meaningful sets, gets a "verify it
     actually ran" note.

PostToolUse is not a blockable event; the gate always exits 0 and communicates
through stdout JSON (hookSpecificOutput.feedback / updatedToolOutput).

Escape hatch: QODER_POST_EXEC_GATE=off disables the whole gate.

Exit code: 0 always (non-blockable event).
"""
import json
import os
import re
import sys
import time

STATE_FILE = os.path.join(os.path.expanduser("~/.qoder-cn/hooks"), ".post-gate-state.json")
REPEAT_WINDOW_SECONDS = 600
REPEAT_THRESHOLD = 2

BUILD_FAIL_RE = re.compile(r"BUILD FAILED|FAILURE:\s*Build failed|> Task .+ FAILED")
FAILURE_SIGS = [
    "BUILD FAILED", "FAILURE:", "command not found", "No such file or directory",
    "SyntaxError", "unmatched", "Permission denied", "timed out", "ETIMEDOUT",
    "Connection refused", "connection closed", "fatal:", "Traceback",
    "exit code 1", "exit code 2", "exit status 1", "non-zero",
]
# Commands whose empty output after success is expected or meaningful.
SILENT_HEADS = {
    "true", "false", ":", "cd", "exit", "export", "unset", "set", "alias", "umask",
    "kill", "wait", "sleep", "nohup", "setsid", "disown", "touch", "mkdir", "rmdir",
    "rm", "mv", "cp", "ln", "chmod", "chown", "install", "sync", "make", "cmake",
    "ninja", "gradle", "gw", "./gradlew", "mvn",
}
SILENT_PREFIXES = {
    "git add", "git commit", "git checkout", "git switch", "git branch", "git tag",
    "git reset", "git stash", "git config", "git clean", "git restore",
    "adb install", "adb uninstall", "adb push", "adb pull", "adb reboot",
    "adb wait-for-device", "adb root", "adb connect", "adb disconnect",
    "docker build", "docker stop", "docker start", "docker rm", "docker rmi",
    "docker pull", "docker compose",
    "pip install", "pip3 install", "npm install", "pnpm install", "yarn install",
    "apt install", "apt-get install", "dpkg -i", "systemctl start", "systemctl stop",
    "systemctl restart", "systemctl enable", "systemctl disable", "mount", "umount",
    "brew install", "chmod", "chown",
}
# Empty-is-meaningful: no matches / identical / empty listing is the real answer.
EMPTY_MEANINGFUL_HEADS = {
    "grep", "egrep", "fgrep", "rg", "find", "locate", "which", "command", "type",
    "diff", "cmp", "test", "[", "ls", "wc", "file", "stat",
}
# Commands whose whole purpose is to print something for the agent to read:
# empty output after success is suspicious and worth one verification note.
FLAG_EMPTY_RE = re.compile(
    r"^(?:systemctl\s+status|journalctl|dumpsys|logcat|ip\s+a(?:ddr)?|ss\b|netstat|"
    r"pm\s+(?:list|path)|curl|wget|sqlite3|git\s+(?:log|diff|show|remote|branch)|cat)\b"
)


def command_prefix(statement: str) -> str:
    tokens = statement.strip().split()
    while tokens and (tokens[0].startswith("-") or "=" in tokens[0].split("/")[-1]):
        tokens = tokens[1:]
    if not tokens:
        return ""
    head = os.path.basename(tokens[0])
    if len(tokens) > 1 and not tokens[1].startswith("-"):
        return head + " " + os.path.basename(tokens[1])
    return head


def skeleton(command: str) -> str:
    text = re.sub(r"'[^']*'|\"[^\"]*\"", "''", command)
    tokens = text.split()[:6]
    return re.sub(r"\d+", "N", " ".join(tokens))


def load_state():
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(state):
    now = time.time()
    state = {k: [t for t in v if now - t < REPEAT_WINDOW_SECONDS] for k, v in state.items()}
    state = {k: v for k, v in state.items() if v}
    if len(state) > 500:
        state = dict(sorted(state.items(), key=lambda kv: max(kv[1]))[-500:])
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(state, f)
        os.replace(tmp, STATE_FILE)
    except OSError:
        pass


def has_failure(text: str) -> bool:
    return any(sig in text for sig in FAILURE_SIGS)


def emit(feedback=None, updated_output=None):
    payload = {"hookSpecificOutput": {"hookEventName": "PostToolUse"}}
    if feedback:
        payload["hookSpecificOutput"]["feedback"] = feedback
    if updated_output is not None:
        payload["updatedToolOutput"] = updated_output
    if len(payload["hookSpecificOutput"]) > 1 or updated_output is not None:
        print(json.dumps(payload, ensure_ascii=False))
    return 0


def process(payload):
    if os.environ.get("QODER_POST_EXEC_GATE", "") == "off":
        return 0
    event = payload.get("hook_event_name") or "PostToolUse"
    tool_input = payload.get("tool_input") or {}
    command = tool_input.get("command") or ""
    if not isinstance(command, str) or not command.strip():
        return 0
    tool_name = payload.get("tool_name")
    if tool_name is not None and tool_name not in ("Bash", "run_in_terminal"):
        return 0

    if event == "PostToolUseFailure":
        if payload.get("is_interrupt"):
            return 0
        response = payload.get("error") or ""
    else:
        response = payload.get("tool_response")
        if not isinstance(response, str):
            response = json.dumps(response, ensure_ascii=False) if response else ""

    failed = event == "PostToolUseFailure" or has_failure(response)
    shape = skeleton(command)
    state = load_state()
    now = time.time()

    if failed:
        hits = state.setdefault(shape, [])
        hits.append(now)
        save_state(state)
    else:
        if shape in state:
            del state[shape]
            save_state(state)

    # H3: a build that failed while the command "succeeded".
    if BUILD_FAIL_RE.search(response):
        warning = (
            "\n\n[post-exec gate] 退出码为 0 但输出里有构建失败标记（BUILD FAILED/FAILURE:）。"
            "这是本舰队实测 528 次假绿事件的同一种形状：不许对外宣称成功，先读上面的失败任务并修复，"
            "重跑到真正的 BUILD SUCCESSFUL。"
        )
        return emit(feedback="构建实际失败（输出含 BUILD FAILED/FAILURE:），勿宣称成功。",
                    updated_output=response + warning)

    # H4: same shape failed again within the window.
    if failed and len(state.get(shape, [])) >= REPEAT_THRESHOLD:
        return emit(feedback=(
            "同一命令形状 %d 分钟内已失败 %d 次（形状：%s）。停止原样重试——换方法："
            "改路径/改工具/先探针确认前置条件，或把脚本落文件分步跑。"
            % (REPEAT_WINDOW_SECONDS // 60, len(state[shape]), shape)
        ))

    # H6: succeeded but printed nothing, and silence is not expected here.
    if event == "PostToolUse" and not response.strip():
        statement = command.strip().splitlines()[0]
        prefix = command_prefix(statement)
        head = prefix.split()[0] if prefix else ""
        if head in EMPTY_MEANINGFUL_HEADS or prefix in SILENT_PREFIXES:
            return 0
        if FLAG_EMPTY_RE.match(statement):
            return emit(feedback=(
                "命令成功但零输出（%s）。确认它真的执行了且输出没有被丢："
                "必要时重跑并显式落盘（| tee <file>）再核对。" % prefix
            ))
    return 0


def selftest() -> int:
    failures = 0

    def run(payload, expect_feedback, expect_output_rewrite, note):
        nonlocal failures
        import io
        import contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = process(payload)
        out = buf.getvalue().strip()
        ok = rc == 0
        has_feedback = "feedback" in out
        has_rewrite = "updatedToolOutput" in out
        if has_feedback != expect_feedback or has_rewrite != expect_output_rewrite:
            ok = False
        if not ok:
            failures += 1
        print("  %s %s (feedback=%s rewrite=%s)" % ("ok  " if ok else "FAIL", note, has_feedback, has_rewrite))

    import tempfile
    global STATE_FILE
    original = STATE_FILE
    STATE_FILE = os.path.join(tempfile.mkdtemp(), "state.json")

    run({"hook_event_name": "PostToolUse", "tool_name": "Bash",
         "tool_input": {"command": "gw :app:assembleDebug"},
         "tool_response": "> Task :app:assembleDebug\nBUILD FAILED in 10s\n1 actionable task: 1 executed"},
        True, True, "H3 build failed behind exit 0")
    run({"hook_event_name": "PostToolUse", "tool_name": "Bash",
         "tool_input": {"command": "gw :app:assembleDebug"},
         "tool_response": "BUILD SUCCESSFUL in 2m"},
        False, False, "clean build stays silent")
    run({"hook_event_name": "PostToolUse", "tool_name": "Bash",
         "tool_input": {"command": "adb -s X shell su -c 'ls /data/x'"},
         "tool_response": "total 0"},
        False, False, "normal output stays silent")
    run({"hook_event_name": "PostToolUse", "tool_name": "Bash",
         "tool_input": {"command": "make -j8"},
         "tool_response": ""},
        False, False, "make stays silent")
    run({"hook_event_name": "PostToolUse", "tool_name": "Bash",
         "tool_input": {"command": "systemctl status nginx"},
         "tool_response": ""},
        True, False, "H6 empty output from systemctl status")
    run({"hook_event_name": "PostToolUse", "tool_name": "Bash",
         "tool_input": {"command": "git log --oneline -3"},
         "tool_response": ""},
        True, False, "H6 empty output from git log")
    run({"hook_event_name": "PostToolUse", "tool_name": "Bash",
         "tool_input": {"command": "git status --short"},
         "tool_response": ""},
        False, False, "git status clean-tree empty stays silent")
    run({"hook_event_name": "PostToolUse", "tool_name": "Bash",
         "tool_input": {"command": "git add -A"},
         "tool_response": ""},
        False, False, "git add stays silent")
    run({"hook_event_name": "PostToolUse", "tool_name": "Bash",
         "tool_input": {"command": "true"},
         "tool_response": ""},
        False, False, "silent-by-design stays silent")
    run({"hook_event_name": "PostToolUse", "tool_name": "Bash",
         "tool_input": {"command": "grep -c foo /var/log/syslog"},
         "tool_response": ""},
        False, False, "grep no-match stays silent")

    # H4: two failures of the same shape within the window trigger the brake.
    state_path = STATE_FILE
    shape = skeleton("ssh debian 'cd /root/play/x && git log --oneline -3'")
    for round_no in (1, 2):
        with open(state_path, "w", encoding="utf-8") as f:
            json.dump({}, f)
        if round_no == 2:
            with open(state_path, "w", encoding="utf-8") as f:
                json.dump({shape: [time.time()]}, f)
        run({"hook_event_name": "PostToolUseFailure", "tool_name": "Bash",
             "tool_input": {"command": "ssh debian 'cd /root/play/x && git log --oneline -3'"},
             "error": "Command exited with code 255", "is_interrupt": False},
            round_no == 2, False, "H4 repeat-failure round %d" % round_no)

    run({"hook_event_name": "PostToolUseFailure", "tool_name": "Bash",
         "tool_input": {"command": "sleep 30"},
         "error": "interrupted", "is_interrupt": True},
        False, False, "interrupt is not a failure")

    STATE_FILE = original
    print("selftest: %d failure(s)" % failures)
    return 1 if failures else 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    return process(payload)


if __name__ == "__main__":
    sys.exit(main())
