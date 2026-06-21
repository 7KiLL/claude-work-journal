# work-journal

A Claude Code plugin that keeps a **per-project work journal** in plain markdown.

- **Session start** → injects the current project's past task summaries into context, so Claude knows what you've already done here.
- **Session end** → distills the finished session into one dated `.md` entry (or skips it if nothing durable happened).

No database. Just `.md` files under `~/.claude/work-journal/`, grep-able and git-able.

## Install

```
/plugin marketplace add 7KiLL/claude-work-journal
/plugin install work-journal@claude-work-journal
```

Restart the session so the hooks load.

### Codex

The same repo installs natively in Codex, which shares Claude Code's plugin and
hook schema:

```
codex plugin marketplace add 7KiLL/claude-work-journal
```

Then open `/plugins` in Codex and install **Work Journal**. It wires
`SessionStart` → recall and `Stop` → capture (Codex's session-end event) and
shares the same `~/.claude/work-journal/` store and `.work-journal` markers as
Claude Code, so journals carry across both tools. Capture summarizes with
`claude` when present, otherwise Codex; set `WORK_JOURNAL_SUMMARIZER` to use a
specific command.

## How it works

The current working directory selects the project (git root, else the folder name) — that's the whole "router". Layout:

```
~/.claude/work-journal/
  ROUTER.md                       # auto-rebuilt map of all projects
  <project>/
    INDEX.md                      # one line per entry, newest first  ← injected at session start
    2026-06-21-fix-auth-race.md   # one session = one entry
```

- `SessionStart` (`recall.sh`) reads `<project>/INDEX.md` and feeds it to Claude as `additionalContext`. New project → silent.
- `SessionEnd` (`capture.sh`) returns instantly and runs the work **detached**, so it never blocks or hangs your exit. The detached worker pipes the transcript to a cheap headless `claude -p`, which replies `SKIP` or a single entry; the script writes the file, prepends the index line, and rebuilds `ROUTER.md`.

## Linking projects (`.work-journal`)

By default each git repo is its own journal. To connect several — a directory of
microservices, a backend that reads a frontend's journal — drop a `.work-journal`
marker file. It turns a plain directory into a journal node and recall **inherits
upward**.

```
# ~/RiderProjects/.work-journal  — a folder-of-repos, not itself a repo
slug: rider           # optional: name the journal (default: the dir name)
root: true            # optional: stop the upward walk here (don't ascend past it)
loads: fe, projectC   # optional: also load these journals (by slug, one hop)
```

What recall loads at session start:

- **self** — the project you're in (git root, as before). Writes always go here.
- **ancestors** — every `.work-journal` dir above you, walking up until `root: true`
  or `/`. So opening Claude in `~/RiderProjects/projectA` loads `projectA` **+**
  the `rider` parent. Opening in `~/RiderProjects` loads only `rider` — a parent
  never loads its children.
- **`loads:`** — any other journals by slug, one hop (no transitive). Storage is
  flat by slug, so a load reaches **any** project regardless of where its repo
  lives on disk — `~/RiderProjects` can `loads: fe` from `~/PhpstormProjects`.

Empty marker (`touch .work-journal`) is valid — just names a node after its dir.
Markers are plain `key: value`; an empty/missing field falls back to the default.
Manage them with `/journal link` / `unlink`, or ask Claude — there's no schema to learn:

```
/journal link ~/RiderProjects slug=rider root=true loads=fe
/journal chain ~/RiderProjects/projectA      # preview what recall will pull in
```

## Failure handling

Hooks are fail-safe — they never block or crash a session. If the detached capture fails (model error, missing `jq`/`claude`, etc.) it appends a line to `~/.claude/work-journal/.errors.log` instead of erroring loudly. At the **next** session start, recall surfaces a one-line "work-journal logged N issue(s)" notice and rotates the log, so you find out without ever being interrupted mid-work.

Capture is **idempotent per session**: each entry's frontmatter carries its `session:` id, and a session that's already been captured is skipped — so a hook firing twice (e.g. compact then exit) won't duplicate. recall also warns once an index grows past ~150 entries.

## Commands

`/journal <subcommand>` (or run `bash journal.sh` from the plugin directly):

| Command | Does |
|---------|------|
| `doctor` | dependency check, project count, recent errors |
| `ls` | list projects and entry counts |
| `trim <project> [N]` | keep the newest N entries (default 30); summarize the rest into `archive.md` |
| `mv <from> <to>` | rename a project's journal, or merge it into an existing one |
| `link <dir> [k=v…]` | create/update a `.work-journal` marker — `slug=`, `root=`, `loads=` (loads union in) |
| `unlink <dir> [slug]` | remove the marker, or just one slug from its `loads` |
| `chain [dir]` | preview what recall would load from `<dir>` (self + ancestors + loads) |

## Requirements

`jq`, `git`, and a summarizer CLI — `claude` by default, or anything you point
`WORK_JOURNAL_SUMMARIZER` at (e.g. `codex exec`).

## Config (env vars)

| Var | Default | Purpose |
|-----|---------|---------|
| `WORK_JOURNAL_DIR` | `~/.claude/work-journal` | where journals live |
| `WORK_JOURNAL_MODEL` | `haiku` | model used to summarize sessions |
| `WORK_JOURNAL_MAX_BYTES` | `200000` | max transcript bytes fed to the model (cost guard) |
| `WORK_JOURNAL_QUIET` | unset | set to `1` to hide the session-start banner line |
| `WORK_JOURNAL_SUMMARIZER` | unset | stdin-reading command to summarize with (e.g. `codex exec`); overrides the `claude` default |
| `CLAUDE_BIN` | `claude` | path to the Claude CLI (set if not on `PATH`) |

## Notes

- At session start you get a visible `📓 work journal · <project> · N entries` line (via the hook's `systemMessage`); a `(+K linked)` suffix shows when ancestor/`loads:` journals were pulled in. The built-in welcome banner itself can't be modified — it renders before any hook runs. Silence the line with `WORK_JOURNAL_QUIET=1`.
- Capture is detached (`nohup`), so session exit is instant; the summary lands a few seconds later.
- Entries are append-only, one per session — a journal is a log. Renaming a project orphans its old folder; use `/journal mv <old> <new>` to rename or merge.
- Index/router writes are guarded with `flock` so parallel sessions don't clobber each other.
- Two repos with the same folder name get distinct journals (`api`, then `api-2`). Identity is the git remote (else the repo path), recorded in each folder's `.source`; the suffix only appears on a real collision.
- A SessionEnd fired by compaction is skipped, so a long session isn't journaled mid-task — only its real end is.
- Recursion is prevented by a `WORK_JOURNAL_LOCK` env guard, since the capture step spawns its own `claude` session.
- Only the last `WORK_JOURNAL_MAX_BYTES` of the transcript is summarized — bounds cost/latency on very long sessions.
- Requires `jq` and a summarizer (`claude`, `codex`, or `WORK_JOURNAL_SUMMARIZER`); if `jq` or every summarizer is missing, the hooks no-op and log it instead of erroring.

## Uninstall

```
/plugin uninstall work-journal@claude-work-journal
```

Your journals under `~/.claude/work-journal/` are left untouched.

MIT
