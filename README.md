# 📓 work-journal

> **Your AI forgets every session. This remembers.**

A plugin for **Claude Code** (and **Codex**) that keeps a **per-project work
journal** in plain markdown. It quietly answers the question you hit at the start
of every session — *"wait, what was I doing here last time?"*

- 🟢 **Session start** → injects this project's past task summaries into context, so your agent already knows the history.
- 🔴 **Session end** → distills the finished session into one dated `.md` entry (or skips it if nothing durable happened).

No database. No cloud. Just `.md` files under `~/.claude/work-journal/` — grep-able, git-able, yours.

---

## 🎬 See it in action

Open a session in a project you've worked on before, and the first thing you see:

```
📓 work journal · this-is-fine-bot · 12 entries
```

Behind that line, your agent silently receives the project's index:

```markdown
# this-is-fine-bot — work journal

- [2026-06-21 fix-auth-token-refresh-race](2026-06-21-fix-auth-token-refresh-race.md) — single-flight lock for token refresh
- [2026-06-19 add-webhook-rate-limit](2026-06-19-add-webhook-rate-limit.md) — sliding-window limiter on /webhook
```

When you wrap up, a session becomes one tidy entry — written for you, automatically:

```markdown
---
task: Fix auth token refresh race
status: done
files: auth/refresh.ts, auth/middleware.ts
---
Concurrent 401s were firing N parallel token refreshes. Added a single-flight
lock so only one refresh runs and the rest await it. 🪤 Gotcha: the old code
cached the promise but not the abort signal — fixed. Covered in refresh.test.ts.
```

That's the whole loop. You never write a line of it.

---

## 📦 Install

### Claude Code

```
/plugin marketplace add 7KiLL/claude-work-journal
/plugin install work-journal@claude-work-journal
```

Restart the session so the hooks load. ✅

### Codex

Same repo, installs natively — Codex shares Claude Code's plugin & hook schema:

```
codex plugin marketplace add 7KiLL/claude-work-journal
```

Then open `/plugins` in Codex and install **Work Journal**. Journals are shared
across both tools (same store, same markers), so a project journaled in Claude
Code shows up in Codex and vice-versa. 🤝

---

## 🧠 How it works

Your **current directory picks the project** (git root, else the folder name) —
that's the entire router. No config, no registration.

```
~/.claude/work-journal/
├── ROUTER.md                        # 🗺️  auto-rebuilt map of every project
└── this-is-fine-bot/
    ├── INDEX.md                     # 📑  one line per entry, newest first → injected at start
    ├── 2026-06-21-fix-auth-race.md  # 📝  one session = one entry
    └── 2026-06-19-add-rate-limit.md
```

- **Recall** reads `<project>/INDEX.md` and hands it to your agent as context. New project? Stays silent.
- **Capture** returns instantly and runs **detached** — it never blocks or hangs your exit. The background worker pipes the transcript to a cheap headless model, which replies `SKIP` or a single entry, then writes the file and updates the index.

---

## 🔗 Linking projects

By default each repo is its own journal. But real work is rarely one repo — a
folder of microservices, a backend that leans on a frontend. Drop a
`.work-journal` marker and recall **inherits upward**. 🌳

```
# ~/RiderProjects/.work-journal   (a folder-of-repos, not itself a repo)
slug: rider           # 🏷️  name the journal      (default: the dir name)
root: true            # ⛔  stop walking up here   (don't ascend to ~)
loads: fe             # 🔌  also pull these journals by slug (one hop)
```

Now identity follows the **tree**, not the disk:

```
~/RiderProjects/                 .work-journal → rider (root, loads: fe)
├── 📁 gateway/  (git repo)  ──▶  recalls  gateway + rider + fe
└── 📁 billing/  (git repo)  ──▶  recalls  billing + rider + fe

~/PhpstormProjects/
└── 📁 storefront/ (git repo)     .work-journal → slug: fe
```

The rules, in one breath:

| | Loads at session start | Writes to |
|---|---|---|
| 🧒 **child** (`gateway/`) | itself **+ every ancestor** marker **+ their `loads:`** | itself |
| 👨‍👦 **parent** (`RiderProjects/`) | itself only — *never* its children | itself |
| 🔌 **`loads:`** | any journal by slug, **one hop**, any tree (storage is flat) | — |

So orchestrating a cross-service feature from `~/RiderProjects` lands in the
`rider` journal; later, working inside `gateway/`, you see `gateway` **and** that
`rider` context **and** the `fe` frontend's. 🎯

Manage markers with the CLI (or just ask your agent — there's no schema):

```bash
/journal link  ~/RiderProjects slug=rider root=true loads=fe
/journal chain ~/RiderProjects/gateway      # 🔍 preview exactly what recall will pull in
```

---

## 🛠️ Commands

`/journal <subcommand>`, or the dedicated `/journal-*` commands, or `bash journal.sh …`:

| Command | Does |
|---------|------|
| 🩺 `doctor` | dependency check, project count, recent errors |
| 📂 `ls` | list projects and entry counts |
| ✂️ `trim <project> [N]` | keep the newest N entries (default 30); summarize the rest into `archive.md` |
| 🔀 `mv <from> <to>` | rename a project's journal, or merge it into another |
| 🔗 `link <dir> [k=v…]` | create/update a `.work-journal` marker — `slug=`, `root=`, `loads=` (loads union in) |
| ✖️ `unlink <dir> [slug]` | remove the marker, or just one slug from its `loads` |
| 🔍 `chain [dir]` | preview what recall would load (self + ancestors + loads) |

---

## 🛟 Fail-safe by design

The whole point is to help quietly — so it's built to **never get in your way**:

- 🧯 **Never blocks, never crashes.** Capture is detached; your session exits instantly and the summary lands a few seconds later.
- 🔁 **Idempotent per session.** Each entry carries its `session:` id, so a hook firing twice (compact, then exit) won't duplicate.
- 🤫 **Errors whisper, they don't shout.** A failed capture logs one line to `.errors.log`; the **next** session start surfaces a single "logged N issue(s)" notice and rotates it. You find out without ever being interrupted mid-work.
- 🔒 **Parallel-safe.** Index/router writes are `flock`-guarded so concurrent sessions can't clobber each other.
- 🪶 **Bounded cost.** Only the transcript tail (`WORK_JOURNAL_MAX_BYTES`) is summarized, by a cheap model.

---

## ⚙️ Config

All optional — sensible defaults out of the box.

| Var | Default | Purpose |
|-----|---------|---------|
| `WORK_JOURNAL_DIR` | `~/.claude/work-journal` | where journals live |
| `WORK_JOURNAL_MODEL` | `haiku` | model used to summarize sessions |
| `WORK_JOURNAL_MAX_BYTES` | `200000` | max transcript bytes fed to the model (cost guard) |
| `WORK_JOURNAL_QUIET` | unset | set to `1` to hide the session-start banner |
| `WORK_JOURNAL_SUMMARIZER` | unset | a stdin-reading command to summarize with (e.g. `codex exec`); overrides the default |
| `CLAUDE_BIN` | `claude` | path to the Claude CLI if it's not on `PATH` |

**Requirements:** `jq`, `git`, and a summarizer — `claude` by default, falling
back to `codex`, or anything you point `WORK_JOURNAL_SUMMARIZER` at. If `jq` or
every summarizer is missing, the hooks simply no-op and log it. 🪶

---

## 🧹 Uninstall

```
/plugin uninstall work-journal@claude-work-journal
```

Your journals under `~/.claude/work-journal/` are left untouched. 📦

---

<sub>MIT · made for people who close the laptop mid-thought.</sub>
