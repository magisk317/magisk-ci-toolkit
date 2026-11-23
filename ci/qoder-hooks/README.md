# Qoder-side and CodeBuddy-side hooks (distributable)

These are PreToolUse/PostToolUse hooks for the **Qoder desktop app** and
**CodeBuddy Code** (any machine). They are kept here so every machine installs
the same version; they are NOT wired by `install.sh` (that script wires git
hooks via `core.hooksPath`).

All three gates were derived from a forensic replay of 40,601 real Bash tool
calls mined from this fleet's own IDE session databases; the replay numbers
below are the acceptance evidence. Run `<script> --selftest` after copying.

## remote-payload-gate.py (PreToolUse, Bash)

Refuses commands that cross a remote-shell boundary (ssh, docker run/exec,
adb shell, wrapper-prefixed) while carrying a fragile payload: heredocs,
`\xNN` hex escapes, command substitution of any quote style (`$(...)` and
backticks -- the recurring class, which is how commit messages and scripts
kept getting smuggled into remote command lines), quotes nested inside
`su -c`, and `$` expansions inside double quotes. It also refuses the LOCAL
trap of a positional `$N` inside a double-quoted awk/sed/perl argument
(silently expanded by the local shell: exit 0, wrong result). The prescribed
fix is write-locally -> scp -> execute remotely (commits use
`git commit -F <scp'd file>`).

Escape hatches: `# gate:allow` in the command, or `QODER_REMOTE_PAYLOAD_GATE=off`.
The checker reads the Claude-style hook payload (`tool_input.command`); a
missing `tool_name` is treated as Bash so hosts that send only the command
still get gated.

## pre-exec-gate.py (PreToolUse, Bash + Read)

Two rules:
* **Detached-HEAD guard (H2)**: `git checkout|co|switch <raw-sha or HEAD~N>`
  is refused when the token resolves to a commit but is not a local branch
  (outside a repo the shape heuristic applies). Prescribes
  `git switch -c <branch> <sha>` or `git worktree add`. Explicit `--detach`
  and real branch names pass.
* **Path existence (H5)**: the Read tool on a path that does not exist is
  refused (prescribes Glob first); the same check applies to standalone
  `cat`/`less`/`stat` Bash commands -- but not inside compounds, where an
  earlier stage may create the file.

Escape hatches: `# gate:allow`, or `QODER_PRE_EXEC_GATE=off`.

## post-exec-gate.py (PostToolUse + PostToolUseFailure, Bash)

PostToolUse is not blockable, so this gate communicates through
`hookSpecificOutput.feedback` and, for the false-green case,
`updatedToolOutput` (it rewrites the tool output the agent sees):
* **H3 false-green**: the command exited 0 but its output contains
  `BUILD FAILED` / `FAILURE:` / `> Task ... FAILED` -> the output is rewritten
  with a warning and the agent is told not to declare success.
* **H4 repeat-failure brake**: the same normalized command shape failing twice
  within 10 minutes (state file `~/.qoder-cn/hooks/.post-gate-state.json`)
  injects "change approach, stop retrying the same shape".
* **H6 empty-output flag**: success with empty output from a command whose
  purpose is to print (systemctl status, journalctl, git log, curl, ...) gets
  a "verify it actually ran" note. Known-silent and empty-is-meaningful
  commands (grep no-match, clean git status, make) stay silent.

Escape hatch: `QODER_POST_EXEC_GATE=off`.

## Replay acceptance (40,601 real Bash calls, 2026-11-23)

| Rule | Replay hits | Notes |
|---|---|---|
| H1 local quoting | 143 | 119 on exit-0 commands: the silent-wrongness class by design |
| H2 detached HEAD | 17 | 14 on exit-0 commands: checkout succeeding IS the trap |
| H5 missing path | 29 | remaining hits are historical files since deleted (replay artifacts) |
| H3 false-green | 649 | exit 0 with BUILD FAILED in output |
| H4 repeat-failure | 1907 | same shape >=2 failures within 10 min |
| H6 empty output | 0 | replay corpus has no empty-success responses; fixture-covered only |

The replay also drove four precision fixes: local `-c` escaped quotes allowed
(zsh handles them; ~1300 false positives), heredoc bodies excluded from local
checks (script content is data), wrapper-prefixed remotes recognized
(`timeout 20 ssh ...`), and the Bash reader check limited to standalone
commands (compounds may create the file first).

## Install on a machine

```bash
mkdir -p ~/.qoder-cn/hooks
cp remote-payload-gate.py pre-exec-gate.py post-exec-gate.py ~/.qoder-cn/hooks/
for s in remote-payload-gate pre-exec-gate post-exec-gate; do
  python3 ~/.qoder-cn/hooks/$s.py --selftest || exit 1
done
```

Then register in `~/.qoder-cn/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "python3 \"<abs>/.qoder-cn/hooks/build-log-gate.py\" },
          { "type": "command", "command": "python3 \"<abs>/.qoder-cn/hooks/remote-payload-gate.py\" },
          { "type": "command", "command": "python3 \"<abs>/.qoder-cn/hooks/pre-exec-gate.py\" }
        ] },
      { "matcher": "Read",
        "hooks": [
          { "type": "command", "command": "python3 \"<abs>/.qoder-cn/hooks/pre-exec-gate.py\" }
        ] }
    ],
    "PostToolUse": [
      { "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "python3 \"<abs>/.qoder-cn/hooks/post-exec-gate.py\" }
        ] }
    ],
    "PostToolUseFailure": [
      { "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "python3 \"<abs>/.qoder-cn/hooks/post-exec-gate.py\" }
        ] }
    ]
  }
}
```

## CodeBuddy

CodeBuddy Code (v1.16.0+) uses the same PreToolUse protocol with user-level
config at `~/.codebuddy/settings.json` (register the two PreToolUse gates
there; PostToolUse support is unverified, so skip the post gate on CodeBuddy):

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
          },
          {
            "type": "command",
            "command": "/usr/bin/python3 \"<abs-path>/.codebuddy/hooks/pre-exec-gate.py\""
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
| Qoder (hp, mbp) | PreToolUse hooks (3 gates) + PostToolUse | yes |
| CodeBuddy (mbp) | PreToolUse hooks (`~/.codebuddy/settings.json`) | yes |
| Trae CN | none - Trae has no PreToolUse support; AGENTS.md rules are its always-on layer | rules only |
| ZCode | none found - per-session generated shell startups, no editable policy | rules only |
| WorkBuddy | none found - `~/.workbuddy/settings.json` has no hooks key | rules only |

For the "rules only" IDEs the enforcement that still applies everywhere is the
git-layer fleet gate (warning whitelist, pointer gates) plus the canonical
rules in `~/.ai-memory/canonical/tooling/agent-working-rules.md`, which every
AGENTS.md chain reaches.

