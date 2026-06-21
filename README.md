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
- `SessionEnd` (`capture.sh`) returns instantly and runs the work **detached**, so it never blocks or hangs your exit. The detached worker pipes the transcript to a cheap headless `claude -p`, which replies `SKIP` or a single entry; the script writes the file, prepends the index line, and rebuilds `ROUTER.md`.

## Failure handling

Hooks are fail-safe — they never block or crash a session. If the detached capture fails (model error, missing `jq`/`claude`, etc.) it appends a line to `~/.claude/memory/.errors.log` instead of erroring loudly. At the **next** session start, recall surfaces a one-line "work-journal logged N issue(s)" notice and rotates the log, so you find out without ever being interrupted mid-work.

Capture is **idempotent per session**: each entry's frontmatter carries its `session:` id, and a session that's already been captured is skipped — so a hook firing twice (e.g. compact then exit) won't duplicate. recall also warns once an index grows past ~150 entries.

## Commands

`/journal <subcommand>` (or run `bash plugins/work-journal/journal.sh` directly):

| Command | Does |
|---------|------|
| `doctor` | dependency check, project count, recent errors |
| `ls` | list projects and entry counts |
| `trim <project> [N]` | keep the newest N entries (default 30); summarize the rest into `archive.md` |
| `mv <from> <to>` | rename a project's journal, or merge it into an existing one |

## Requirements

`jq`, `git`, and the `claude` CLI on PATH (all standard on a dev machine).

## Config (env vars)

| Var | Default | Purpose |
|-----|---------|---------|
| `CLAUDE_MEMORY_DIR` | `~/.claude/memory` | where journals live |
| `CLAUDE_MEMORY_MODEL` | `haiku` | model used to summarize sessions |
| `CLAUDE_BIN` | `claude` | path to the Claude CLI (set if not on `PATH`) |

## Notes

- Capture is detached (`nohup`), so session exit is instant; the summary lands a few seconds later.
- Entries are append-only, one per session — a journal is a log. Renaming a project orphans its old folder; use `/journal mv <old> <new>` to rename or merge.
- Index/router writes are guarded with `flock` so parallel sessions don't clobber each other.
- Recursion is prevented by a `CLAUDE_WORKJOURNAL_LOCK` env guard, since the capture step spawns its own `claude` session.
- Requires `jq`, `git`, and the `claude` CLI; if `jq` or `claude` is missing the hooks no-op and log it instead of erroring.

## Uninstall

```
/plugin uninstall work-journal@claude-work-journal
```

Your journals under `~/.claude/memory/` are left untouched.

MIT
