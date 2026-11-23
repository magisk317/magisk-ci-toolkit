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
in the environment. The checker reads the Claude-style hook payload
(`tool_input.command`); a missing `tool_name` is treated as Bash so hosts that
send only the command still get gated.

## CodeBuddy

CodeBuddy Code (v1.16.0+) uses the same PreToolUse protocol with user-level
config at `~/.codebuddy/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/python3 \"<abs-path>/.codebuddy/hooks/remote-payload-gate.py\""
          }
        ]
      }
    ]
  }
}
```

CodeBuddy requires external settings edits to be approved in its `/hooks` panel
before they take effect. Use an absolute python3 path: the hook environment is
not a login shell.

## Coverage matrix (2026-11-23)

| IDE | Pre-exec interception | Deployed |
|---|---|---|
| Qoder (hp, mbp) | PreToolUse hook | yes |
| CodeBuddy (mbp) | PreToolUse hook (`~/.codebuddy/settings.json`) | yes |
| Trae CN | none - Trae has no PreToolUse support; AGENTS.md rules are its always-on layer | rules only |
| ZCode | none found - per-session generated shell startups, no editable policy | rules only |
| WorkBuddy | none found - `~/.workbuddy/settings.json` has no hooks key | rules only |

For the "rules only" IDEs the enforcement that still applies everywhere is the
git-layer fleet gate (warning whitelist, pointer gates) plus the canonical
rules in `~/.ai-memory/canonical/tooling/agent-working-rules.md`, which every
AGENTS.md chain reaches.

