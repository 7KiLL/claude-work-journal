# AGENTS.md

Canonical guidance for any coding agent working in this repository. Claude Code
loads `CLAUDE.md`, but that file intentionally points here; keep durable repo
instructions in this file so Claude, Codex, Kilo, and other agents do not drift.

## What this is

Pure-bash core with a small optional Kilo/OpenCode JS adapter. It ships a
per-project work journal for Claude Code, Codex, and Kilo/OpenCode-compatible harnesses:
recall injects prior project entries into context, and capture distills completed
work into dated markdown entries under `~/.claude/work-journal/`.

## Layout

- `hooks/lib.sh` is the shared core. `recall.sh`, `capture.sh`, and `journal.sh`
  all source it, so slug resolution, entry counting, recall chain behavior,
  router rebuilds, and summarization must stay centralized there.
- `hooks/recall.sh` is the SessionStart hook. It injects the project's `INDEX.md`
  plus inherited journals into context and surfaces prior capture errors once.
- `hooks/capture.sh` is the SessionEnd/Stop hook. It parses the hook payload,
  snapshots the transcript tail, detaches a worker, summarizes the snapshot, and
  creates or replaces the session's journal entry.
- `journal.sh` is the management CLI: `doctor | ls | trim | mv | link | unlink | chain`.
- `commands/*.md` are thin slash-command wrappers around `journal.sh`, using
  `$PLUGIN_ROOT` / `$CLAUDE_PLUGIN_ROOT` from the host.
- `kilo-plugin/work-journal.js` is the Kilo/OpenCode-compatible JS adapter. It
  must stay thin and reuse `hooks/recall.sh` plus `hooks/capture.sh --worker`.
- `scripts/install.sh` is a local helper only. It prints Claude/Codex marketplace
  commands, creates missing Kilo config files, and creates OpenCode plugin
  wrappers. It must not run npm, Bun, or other package managers.
- `.claude-plugin/`, `.codex-plugin/`, and `.agents/plugins/` are packaging
  manifests and marketplace mirrors. Edit runtime scripts at the repo root.

## Verification

There is a lightweight script-only validation suite. Verify changes by exercising
the scripts directly:

```bash
bash journal.sh doctor
bash journal.sh doctor --strict
bash journal.sh ls
bash journal.sh chain [dir]
echo '{"cwd":"'$PWD'"}' | bash hooks/recall.sh
WORK_JOURNAL_DIR=/tmp/wj-test bash journal.sh doctor --strict
bash scripts/validate.sh
```

- Run `bash journal.sh doctor` after any change. Use `--strict` for release gates.
  It checks deps, PATH, summarizer availability, journal permissions, lock health,
  harness files, project/entry counts, and recent `.errors.log` lines.
- Use `bash journal.sh chain [dir]` to debug exactly what recall would load:
  self, inherited ancestors, and one-hop `loads:` journals.
- For hook changes, smoke-test the JSON contract with `hooks/recall.sh`; it must
  emit valid `jq`-built JSON with `systemMessage` and/or
  `hookSpecificOutput.additionalContext`, or exit 0 silently.
- Use `bash hooks/capture.sh --worker <transcript.jsonl> <cwd> <session-id> [capture-id]`
  to exercise the slow capture path without a real hook session. Reusing a
  session id with a new capture id must replace the existing entry.
- If available, run `shellcheck hooks/*.sh journal.sh`. The scripts intentionally
  disable SC2086 where `loads:` lists are meant to split.
- For Kilo/OpenCode adapter changes, run `node --check kilo-plugin/work-journal.js`
  when Node is available. Do not start Kilo or OpenCode from validation scripts.

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
- `session:` metadata groups captures that should replace the same entry.
  `capture:` metadata and the `.captures` ledger are the exact duplicate guard.
  `.sessions` maps a session id to its current entry file so resumed sessions can
  update in place even after older duplicate keys have been recorded.
- `wj_rebuild_router` always rebuilds `ROUTER.md` from disk. Do not add
  incremental router edits.

## Invariants

- Never block and never crash loudly. Hooks must no-op or log on missing deps,
  then exit 0. `recall.sh` exits 0 without `jq`; `capture.sh` logs failures to
  `.errors.log` and exits 0.
- Capture is detached. The hook dispatcher must snapshot the transcript tail,
  return immediately, and `nohup` a `--worker` subshell for slow model work.
- Preserve the recursion guard. `WORK_JOURNAL_LOCK=1` is set on nested
  `claude`/`codex`/`kilo`/`opencode` summarizer calls, and both hooks must
  short-circuit on it.
- Serialize all index/router writes under `flock` on `$WORK_JOURNAL_DIR/.lock`.
- Keep the entry contract centralized in `wj_entry_lines`: a real entry line is
  `- [YYYY-MM-DD ...](file) — ...`. The `- [archive]` row is intentionally not an
  entry. `trim`, `mv`, `ls`, recall, and the router depend on this exact contract.
- Preserve resumable idempotency. Each entry stamps `session: <id>` and
  `capture: <key>` in frontmatter. Capture skips only when the exact capture key
  already exists; a new capture for an existing session replaces that session's
  entry and updates the index line.
- Keep the compaction guard. Claude Code may fire SessionEnd with
  `reason=compact`/`compaction`; capture must skip those mid-session events.
- Errors whisper. Capture appends to `.errors.log`; the next recall surfaces a
  one-line notice and rotates it to `.errors.log.shown`.
- The summarizer runs from `$TMPDIR` deliberately so it does not load the host
  project's `CLAUDE.md`.
- The Kilo/OpenCode adapter has no final SessionEnd hook. It injects recall via
  Kilo's `experimental.chat.system.transform` when available. For standalone
  OpenCode, it uses documented no-reply session prompts as a best-effort recall
  path. It captures debounced idle turns, passes the real `sessionID` as
  `session:`, and passes `sessionID:lastMessageID` as the `capture:` key. Keep
  that separation so resumed/continued sessions update one entry instead of
  creating overlapping entries.

## Host packaging

- `.claude-plugin/` plus `hooks/hooks.json` wires Claude Code with
  `SessionStart`/`SessionEnd` and `${CLAUDE_PLUGIN_ROOT}`.
- `.codex-plugin/` plus `hooks/hooks.codex.json` wires Codex with
  `SessionStart` on `startup|resume`, `Stop` instead of SessionEnd, and
  `${PLUGIN_ROOT}`. Codex payloads have no `reason`/`source`, so the compaction
  guard is a harmless no-op there.
- `.agents/plugins/plugins/work-journal/` is the Codex marketplace mirror and is
  expected to point back to the root scripts. Keep source edits in one place.
- `kilo-plugin/work-journal.js` is loaded by Kilo via a `plugin` config entry,
  usually a `file:///.../kilo-plugin/work-journal.js` path. Do not put source in
  `.kilo/`; that directory is local tooling and ignored.
- OpenCode loads local plugins from `.opencode/plugins/` or
  `~/.config/opencode/plugins/`. `scripts/install.sh opencode` writes a wrapper
  there that imports the shared adapter from this checkout; source still lives in
  `kilo-plugin/`.
- Version strings are duplicated and must stay in sync in
  `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json`.

## Config and env

- `WORK_JOURNAL_DIR` defaults to `~/.claude/work-journal`. Runtime journals live
  there, not in this repository.
- `WORK_JOURNAL_MODEL` defaults to `haiku`; it is for Claude, and for
  Kilo/OpenCode only when already in `provider/model` form.
- `WORK_JOURNAL_MAX_BYTES` defaults to `200000` and caps transcript bytes sent to
  the summarizer.
- `WORK_JOURNAL_QUIET=1` hides the session-start banner.
- `WORK_JOURNAL_SUMMARIZER` overrides the summarizer with a stdin-reading command.
- `CLAUDE_BIN` overrides the Claude CLI path.
- `WORK_JOURNAL_CODEX_MODEL` optionally selects the model for the `codex exec`
  summarizer fallback; otherwise Codex's configured default model is used.
- `WORK_JOURNAL_KILO_CAPTURE_DELAY_MS` controls the Kilo adapter's idle debounce.
- `WORK_JOURNAL_KILO_MODEL` optionally selects the model for the `kilo run --pure`
  summarizer fallback; otherwise Kilo's configured default model is used.
- `WORK_JOURNAL_OPENCODE_MODEL` optionally selects the model for the
  `opencode run --pure` summarizer fallback; otherwise OpenCode's configured
  default model is used.
- `wj_summarize` tries `WORK_JOURNAL_SUMMARIZER`, then `claude -p --model`, then
  the active Kilo/OpenCode host fallback when set, then best-effort `codex exec`,
  then `kilo run --pure`, then `opencode run --pure`.

## Conventions

- `ponytail:` comments mark deliberate simplifications and the intended upgrade
  path. Respect them; do not “fix” a documented shortcut without a concrete reason.
- `.gitignore` excludes `.claude/` and `.kilo/`; these are local tooling dirs, not
  plugin source. Do not commit them.
- Journals themselves live under `$WORK_JOURNAL_DIR`, never inside this repo.
