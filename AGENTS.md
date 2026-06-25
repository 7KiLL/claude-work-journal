# AGENTS.md

Canonical guidance for any coding agent working in this repository. Claude Code
loads `CLAUDE.md`, but that file intentionally points here; keep durable repo
instructions in this file so Claude, Codex, Kilo, and other agents do not drift.

## What this is

Pure-bash plugin with no build step, package manager, root test framework, or
compiled artifacts. It ships a per-project work journal for Claude Code and Codex:
recall injects prior project entries at session start, and capture distills the
finished session into one dated markdown entry under `~/.claude/work-journal/`.

## Layout

- `hooks/lib.sh` is the shared core. `recall.sh`, `capture.sh`, and `journal.sh`
  all source it, so slug resolution, entry counting, recall chain behavior,
  router rebuilds, and summarization must stay centralized there.
- `hooks/recall.sh` is the SessionStart hook. It injects the project's `INDEX.md`
  plus inherited journals into context and surfaces prior capture errors once.
- `hooks/capture.sh` is the SessionEnd/Stop hook. It parses the hook payload,
  detaches a worker, summarizes the transcript tail, and writes one entry.
- `journal.sh` is the management CLI: `doctor | ls | trim | mv | link | unlink | chain`.
- `commands/*.md` are thin slash-command wrappers around `journal.sh`, using
  `$PLUGIN_ROOT` / `$CLAUDE_PLUGIN_ROOT` from the host.
- `.claude-plugin/`, `.codex-plugin/`, and `.agents/plugins/` are packaging
  manifests and marketplace mirrors. Edit runtime scripts at the repo root.

## Verification

There are no automated tests. Verify changes by exercising the scripts directly:

```bash
bash journal.sh doctor
bash journal.sh ls
bash journal.sh chain [dir]
echo '{"cwd":"'$PWD'"}' | bash hooks/recall.sh
WORK_JOURNAL_DIR=/tmp/wj-test bash journal.sh doctor
```

- Run `bash journal.sh doctor` after any change. It checks deps, summarizer
  availability, project/entry counts, and recent `.errors.log` lines.
- Use `bash journal.sh chain [dir]` to debug exactly what recall would load:
  self, inherited ancestors, and one-hop `loads:` journals.
- For hook changes, smoke-test the JSON contract with `hooks/recall.sh`; it must
  emit valid `jq`-built JSON with `systemMessage` and/or
  `hookSpecificOutput.additionalContext`, or exit 0 silently.
- Use `bash hooks/capture.sh --worker <transcript.jsonl> <cwd> <session-id>` to
  exercise the slow capture path without a real hook session.
- If available, run `shellcheck hooks/*.sh journal.sh`. The scripts intentionally
  disable SC2086 where `loads:` lists are meant to split.

## Architecture

- `wj_repo_root` maps linked worktrees back to the main worktree from
  `git worktree list`, so throwaway agent worktrees share the same journal.
  Do not replace this with plain `rev-parse --show-toplevel`.
- `wj_source_id` is the stable identity: git remote URL, else absolute path.
- `wj_resolve_slug` chooses the journal directory. A `.source` file claims a
  folder for a repo id, collisions get `-2`/`-3` suffixes, and an explicit
  `slug:` in `.work-journal` wins outright.
- `wj_recall_chain` prints `<tag>\t<slug>` lines. It starts with `self`, includes
  one-hop `loads:`, then walks ancestor `.work-journal` markers nearest-first
  until a `root: true` marker or `/`. Lateral `loads:` are not transitive.
- `wj_rebuild_router` always rebuilds `ROUTER.md` from disk. Do not add
  incremental router edits.

## Invariants

- Never block and never crash loudly. Hooks must no-op or log on missing deps,
  then exit 0. `recall.sh` exits 0 without `jq`; `capture.sh` logs failures to
  `.errors.log` and exits 0.
- Capture is detached. The hook dispatcher must return immediately and `nohup`
  a `--worker` subshell for slow model work.
- Preserve the recursion guard. `WORK_JOURNAL_LOCK=1` is set on nested
  `claude`/`codex` summarizer calls, and both hooks must short-circuit on it.
- Serialize all index/router writes under `flock` on `$WORK_JOURNAL_DIR/.lock`.
- Keep the entry contract centralized in `wj_entry_lines`: a real entry line is
  `- [YYYY-MM-DD ...](file) — ...`. The `- [archive]` row is intentionally not an
  entry. `trim`, `mv`, `ls`, recall, and the router depend on this exact contract.
- Preserve idempotency. Each entry stamps `session: <id>` in frontmatter, and
  capture skips if that id already exists in the project directory.
- Keep the compaction guard. Claude Code may fire SessionEnd with
  `reason=compact`/`compaction`; capture must skip those mid-session events.
- Errors whisper. Capture appends to `.errors.log`; the next recall surfaces a
  one-line notice and rotates it to `.errors.log.shown`.
- The summarizer runs from `$TMPDIR` deliberately so it does not load the host
  project's `CLAUDE.md`.

## Dual-host packaging

- `.claude-plugin/` plus `hooks/hooks.json` wires Claude Code with
  `SessionStart`/`SessionEnd` and `${CLAUDE_PLUGIN_ROOT}`.
- `.codex-plugin/` plus `hooks/hooks.codex.json` wires Codex with
  `SessionStart` on `startup|resume`, `Stop` instead of SessionEnd, and
  `${PLUGIN_ROOT}`. Codex payloads have no `reason`/`source`, so the compaction
  guard is a harmless no-op there.
- `.agents/plugins/plugins/work-journal/` is the Codex marketplace mirror and is
  expected to point back to the root scripts. Keep source edits in one place.
- Version strings are duplicated and must stay in sync in
  `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json`.

## Config and env

- `WORK_JOURNAL_DIR` defaults to `~/.claude/work-journal`. Runtime journals live
  there, not in this repository.
- `WORK_JOURNAL_MODEL` defaults to `haiku`.
- `WORK_JOURNAL_MAX_BYTES` defaults to `200000` and caps transcript bytes sent to
  the summarizer.
- `WORK_JOURNAL_QUIET=1` hides the session-start banner.
- `WORK_JOURNAL_SUMMARIZER` overrides the summarizer with a stdin-reading command.
- `CLAUDE_BIN` overrides the Claude CLI path.
- `wj_summarize` tries `WORK_JOURNAL_SUMMARIZER`, then `claude -p --model`, then
  best-effort `codex exec --model`.

## Conventions

- `ponytail:` comments mark deliberate simplifications and the intended upgrade
  path. Respect them; do not “fix” a documented shortcut without a concrete reason.
- `.gitignore` excludes `.claude/` and `.kilo/`; these are local tooling dirs, not
  plugin source. Do not commit them.
- Journals themselves live under `$WORK_JOURNAL_DIR`, never inside this repo.
