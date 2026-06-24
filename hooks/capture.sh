#!/usr/bin/env bash
# SessionEnd: distill the finished session into ONE work-journal entry.
# Fail-safe by design: the hook returns instantly (work is detached), so it can
# never block or hang the session. The detached worker's output goes to
# .errors.log — if it's non-empty, something broke, and recall.sh surfaces it.
set -uo pipefail

# Guard: the worker runs `claude -p`, itself a session that re-fires the hooks.
# The lock env var makes both hooks no-op inside that nested call → no recursion.
[ -n "${WORK_JOURNAL_LOCK:-}" ] && exit 0

MEM="${WORK_JOURNAL_DIR:-$HOME/.claude/work-journal}"
MODEL="${WORK_JOURNAL_MODEL:-haiku}"
CLI="${CLAUDE_BIN:-claude}"
CAP="${WORK_JOURNAL_MAX_BYTES:-200000}"   # cap transcript fed to the model (cost guard)
mkdir -p "$MEM" 2>/dev/null || true
self="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/$(basename "${BASH_SOURCE[0]}")"
source "$(dirname "$self")/lib.sh"

# ============ worker (detached): does the slow work; output → .errors.log ============
if [ "${1:-}" = "--worker" ]; then
  set -e
  transcript="${2:-}"; cwd="${3:-}"; sid="${4:-}"
  [ -f "$transcript" ] || exit 0

  # Map any linked worktree back to the main repo so the entry lands in the same
  # journal recall reads from — not a per-worktree slug that vanishes with it.
  root="$(wj_repo_root "${cwd:-$PWD}")"
  slug="$(wj_resolve_slug "$root" "$MEM")"
  dir="$MEM/$slug"
  day="$(date +%F)"

  # Idempotency: one entry per session id, searchable in the entry frontmatter.
  if [ -n "$sid" ] && [ -d "$dir" ] && grep -rsqF "session: $sid" "$dir"; then
    exit 0
  fi

  PROMPT=$(cat <<'EOF'
You are distilling a finished AI coding session into ONE work-journal entry.
The session transcript (JSONL, noisy with tool calls) follows the marker below.

If nothing durable was accomplished — only chat/questions, or an abandoned or
trivial change — reply with exactly:
SKIP

Otherwise reply with this and NOTHING before it:
  Line 1:  <kebab-task-slug> :: <one-line index summary, max ~90 chars>
  Then a markdown entry starting with frontmatter:
    ---
    task: <short human title>
    status: done | partial | wip
    files: <key files touched, comma-separated, or ->
    ---
  followed by a tight body: what was accomplished, key decisions, gotchas.
  No preamble, no code fences around the whole reply.
EOF
)

  # Run from a neutral dir so the summarizer doesn't load the project's CLAUDE.md.
  # Feed only the last $CAP bytes — a journal cares about how the session ended.
  out="$( cd "${TMPDIR:-/tmp}"
          { printf '%s\n\n=== TRANSCRIPT (tail) ===\n' "$PROMPT"; tail -c "$CAP" "$transcript"; } \
            | wj_summarize 2>/dev/null )" || true
  [ -n "$out" ] || { echo "[$(date -Is)] work-journal: summarizer failed/empty for $slug"; exit 0; }

  first="${out%%$'\n'*}"
  [ "$first" = "SKIP" ] && exit 0
  case "$first" in *" :: "*) ;; *) echo "[$(date -Is)] work-journal: unexpected output: $first"; exit 0 ;; esac

  taskslug="${first%% :: *}"; hook="${first#* :: }"
  taskslug="$(printf '%s' "$taskslug" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//')"
  taskslug="${taskslug:0:50}"; [ -n "$taskslug" ] || taskslug="session"

  body="${out#*$'\n'}"                              # everything after line 1
  body="${body#"${body%%[![:space:]]*}"}"          # strip leading blank lines
  if [ -n "$sid" ]; then                            # stamp session id into frontmatter
    body="$(printf '%s\n' "$body" | awk -v s="$sid" 'NR==1 && $0=="---"{print; print "session: " s; next} {print}')"
  fi

  mkdir -p "$dir"
  [ -f "$dir/.source" ] || wj_source_id "$root" > "$dir/.source"   # claim this folder for this repo

  # Serialize entry-file creation + index/router writes so parallel sessions
  # can't clobber each other or race on a filename collision.
  {
    flock 9 2>/dev/null || true
    file="$day-$taskslug.md"
    # Filename collision guard (B5): an existing same-named file is either this
    # same session (idempotent no-op — already caught dir-wide above, but guard
    # anyway) or a *different* session that minted the same day+slug. In the
    # latter case pick a free -2/-3 … suffix on the filename instead of
    # clobbering the prior entry.
    if [ -e "$dir/$file" ]; then
      ext_sid="$(awk -F': ' '/^session:/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$dir/$file" 2>/dev/null || true)"
      if [ -n "$sid" ] && [ "$ext_sid" = "$sid" ]; then
        exit 0
      fi
      base="${file%.md}"; n=2
      while [ -e "$dir/$base-$n.md" ]; do n=$((n+1)); done
      file="$base-$n.md"
    fi
    printf '%s\n' "$body" > "$dir/$file"
    idx="$dir/INDEX.md"
    [ -f "$idx" ] || printf '# %s — work journal\n\n' "$slug" > "$idx"
    tmp="$(mktemp)"
    { head -n 2 "$idx"; printf -- '- [%s %s](%s) — %s\n' "$day" "$taskslug" "$file" "$hook"; tail -n +3 "$idx"; } > "$tmp"
    mv "$tmp" "$idx"
    wj_rebuild_router "$MEM"
  } 9>"$MEM/.lock"
  exit 0
fi

# ============ dispatcher (fast): parse payload, spawn worker, return now ============
command -v jq    >/dev/null 2>&1 || { echo "[$(date -Is)] work-journal: jq not installed — disabled" >> "$MEM/.errors.log"; exit 0; }
# Need *a* summarizer: a custom one, claude, or codex (wj_summarize tries them
# in that order). Only bail if none exist.
if [ -z "${WORK_JOURNAL_SUMMARIZER:-}" ] && ! command -v "$CLI" >/dev/null 2>&1 && ! command -v codex >/dev/null 2>&1; then
  echo "[$(date -Is)] work-journal: no summarizer found — install claude/codex or set WORK_JOURNAL_SUMMARIZER" >> "$MEM/.errors.log"; exit 0
fi

input="$(cat)"   # hook payload on stdin
transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
sid="$(printf '%s' "$input" | jq -r '.session_id // empty')"
why="$(printf '%s' "$input" | jq -r '.reason // .source // empty')"
[ -f "$transcript" ] || exit 0
# Don't journal a mid-session compaction — wait for the real end. Claude-specific:
# CC fires SessionEnd with reason=compact; Codex's Stop hook has no compaction
# (its schema lacks reason/source — the guard below is a harmless no-op there).
case "$why" in compact|compaction) exit 0 ;; esac

# nohup (POSIX, works on macOS too) detaches the worker; the hook exits immediately.
nohup bash "$self" --worker "$transcript" "$cwd" "$sid" >> "$MEM/.errors.log" 2>&1 < /dev/null &
exit 0
