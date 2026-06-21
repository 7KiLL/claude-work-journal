#!/usr/bin/env bash
# SessionEnd: distill the finished session into ONE work-journal entry.
# Fail-safe by design: the hook returns instantly (work is detached), so it can
# never block or hang the session. The detached worker's output goes to
# .errors.log — if it's non-empty, something broke, and recall.sh surfaces it.
set -uo pipefail

# Guard: the worker runs `claude -p`, itself a session that re-fires the hooks.
# The lock env var makes both hooks no-op inside that nested call → no recursion.
[ -n "${CLAUDE_WORKJOURNAL_LOCK:-}" ] && exit 0

MEM="${CLAUDE_MEMORY_DIR:-$HOME/.claude/memory}"
MODEL="${CLAUDE_MEMORY_MODEL:-haiku}"
CLI="${CLAUDE_BIN:-claude}"
mkdir -p "$MEM" 2>/dev/null || true
self="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/$(basename "${BASH_SOURCE[0]}")"
source "$(dirname "$self")/lib.sh"

# ============ worker (detached): does the slow work; output → .errors.log ============
if [ "${1:-}" = "--worker" ]; then
  set -e
  transcript="${2:-}"; cwd="${3:-}"; sid="${4:-}"
  [ -f "$transcript" ] || exit 0

  root="${cwd:-$PWD}"
  root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || echo "$root")"
  slug="$(wj_resolve_slug "$root" "$MEM")"
  dir="$MEM/$slug"
  day="$(date +%F)"

  # Idempotency: one entry per session id, searchable in the entry frontmatter.
  if [ -n "$sid" ] && [ -d "$dir" ] && grep -rsqF "session: $sid" "$dir"; then
    exit 0
  fi

  PROMPT=$(cat <<'EOF'
You are distilling a finished Claude Code session into ONE work-journal entry.
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
  out="$( cd "${TMPDIR:-/tmp}"
          { printf '%s\n\n=== TRANSCRIPT ===\n' "$PROMPT"; cat "$transcript"; } \
            | CLAUDE_WORKJOURNAL_LOCK=1 "$CLI" -p --model "$MODEL" 2>/dev/null )" || true
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
  file="$day-$taskslug.md"
  printf '%s\n' "$body" > "$dir/$file"

  # Serialize shared index/router writes so parallel sessions can't clobber them.
  {
    flock 9 2>/dev/null || true
    idx="$dir/INDEX.md"
    [ -f "$idx" ] || printf '# %s — work journal\n\n' "$slug" > "$idx"
    tmp="$(mktemp)"
    { head -n 2 "$idx"; printf -- '- [%s %s](%s) — %s\n' "$day" "$taskslug" "$file" "$hook"; tail -n +3 "$idx"; } > "$tmp"
    mv "$tmp" "$idx"
    { printf '# Work journal — projects\n\n'
      for p in "$MEM"/*/INDEX.md; do
        [ -e "$p" ] || continue
        d="$(basename "$(dirname "$p")")"
        n="$(grep -c '^- ' "$p" 2>/dev/null || true)"; n="${n:-0}"
        printf -- '- %s (%s entries) — %s/INDEX.md\n' "$d" "$n" "$d"
      done
    } > "$MEM/ROUTER.md"
  } 9>"$MEM/.lock"
  exit 0
fi

# ============ dispatcher (fast): parse payload, spawn worker, return now ============
command -v jq    >/dev/null 2>&1 || { echo "[$(date -Is)] work-journal: jq not installed — disabled" >> "$MEM/.errors.log"; exit 0; }
command -v "$CLI" >/dev/null 2>&1 || { echo "[$(date -Is)] work-journal: '$CLI' not found — set CLAUDE_BIN" >> "$MEM/.errors.log"; exit 0; }

input="$(cat)"   # hook payload on stdin
transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
sid="$(printf '%s' "$input" | jq -r '.session_id // empty')"
why="$(printf '%s' "$input" | jq -r '.reason // .source // empty')"
[ -f "$transcript" ] || exit 0
# Don't journal a mid-session compaction — wait for the real end. (Verify the
# exact reason value on your CC version; harmless if compaction doesn't fire SessionEnd.)
case "$why" in compact|compaction) exit 0 ;; esac

# nohup (POSIX, works on macOS too) detaches the worker; the hook exits immediately.
nohup bash "$self" --worker "$transcript" "$cwd" "$sid" >> "$MEM/.errors.log" 2>&1 < /dev/null &
exit 0
