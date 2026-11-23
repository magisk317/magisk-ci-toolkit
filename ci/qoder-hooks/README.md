# Qoder-side hooks (distributable)

These are PreToolUse hooks for the **Qoder desktop app** (any machine). They are
kept here so every machine installs the same version; they are NOT wired by
`install.sh` (that script wires git hooks via `core.hooksPath`).

## remote-payload-gate.py

Refuses Bash commands that cross a remote-shell boundary (ssh, docker run/exec,
adb shell) while carrying a fragile payload: heredocs, `\xNN` hex escapes,
quotes nested inside `su -c`, and `$` expansions inside double quotes. Those
shapes get eaten by one of the shell layers in the chain; the prescribed fix is
write-locally -> scp -> execute remotely.

Install on a machine:

```bash
mkdir -p ~/.qoder-cn/hooks
cp remote-payload-gate.py ~/.qoder-cn/hooks/
python3 ~/.qoder-cn/hooks/remote-payload-gate.py --selftest   # 20 fixtures, expect 0 failures
```

Then register it in `~/.qoder-cn/settings.json` next to `build-log-gate`, as a
second entry in `hooks.PreToolUse`:

```json
{
  "type": "command",
  "command": "python3 \"<abs-path>/.qoder-cn/hooks/remote-payload-gate.py\"",
  "name": "remote-payload-gate",
  "timeout": 20,
  "statusMessage": "检查远端执行语句有没有携带易碎载荷"
}
```

Escape hatches: `# gate:allow` in the command, or `QODER_REMOTE_PAYLOAD_GATE=off`
in the environment. The hook is Qoder-specific (it reads Qoder's hook payload),
which is why it lives here instead of in `ci/git_hooks`.

Deployed: hp (2026-11-23), mbp (2026-11-23).
