# work-journal

A Claude Code plugin that keeps a **per-project work journal** in plain markdown.

- **Session start** → injects the current project's past task summaries into context, so Claude knows what you've already done here.
- **Session end** → distills the finished session into one dated `.md` entry (or skips it if nothing durable happened).

No database. Just `.md` files under `~/.claude/memory/`, grep-able and git-able.

## Install

```
/plugin marketplace add 7KiLL/claude-work-journal
/plugin install work-journal@claude-work-journal
```

Restart the session so the hooks load.

## How it works

The current working directory selects the project (git root, else the folder name) — that's the whole "router". Layout:

```
~/.claude/memory/
  ROUTER.md                       # auto-rebuilt map of all projects
  <project>/
    INDEX.md                      # one line per entry, newest first  ← injected at session start
    2026-06-21-fix-auth-race.md   # one session = one entry
```

- `SessionStart` (`recall.sh`) reads `<project>/INDEX.md` and feeds it to Claude as `additionalContext`. New project → silent.
- `SessionEnd` (`capture.sh`) pipes the transcript to a cheap headless `claude -p`, which replies `SKIP` or a single entry. The script writes the file, prepends the index line, and rebuilds `ROUTER.md`.

## Requirements

`jq`, `git`, and the `claude` CLI on PATH (all standard on a dev machine).

## Config (env vars)

| Var | Default | Purpose |
|-----|---------|---------|
| `CLAUDE_MEMORY_DIR` | `~/.claude/memory` | where journals live |
| `CLAUDE_MEMORY_MODEL` | `haiku` | model used to summarize sessions |
| `CLAUDE_BIN` | `claude` | path to the Claude CLI (set if not on `PATH`) |

## Notes

- Capture runs synchronously at session end (a few seconds). If that delay bothers you, wrap the `claude -p` block in `capture.sh` with `nohup … &`.
- Entries are append-only, one per session. Merging/dedup across sessions is deliberately not done — a journal is a log.
- Recursion is prevented by a `CLAUDE_WORKJOURNAL_LOCK` env guard, since the capture step spawns its own `claude` session.

## Uninstall

```
/plugin uninstall work-journal@claude-work-journal
```

Your journals under `~/.claude/memory/` are left untouched.

MIT
