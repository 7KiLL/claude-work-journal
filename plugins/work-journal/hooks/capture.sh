#!/usr/bin/env bash
# SessionEnd: distill the finished session into ONE work-journal entry (or skip).
set -euo pipefail

# Guard: this runs `claude -p`, itself a session that re-fires the hooks.
# The lock env var makes both hooks no-op inside that nested call → no recursion.
[ -n "${CLAUDE_WORKJOURNAL_LOCK:-}" ] && exit 0

MEM="${CLAUDE_MEMORY_DIR:-$HOME/.claude/memory}"
MODEL="${CLAUDE_MEMORY_MODEL:-haiku}"
CLI="${CLAUDE_BIN:-claude}"

input="$(cat)"   # hook payload arrives on stdin
transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -f "$transcript" ] || exit 0

root="${CLAUDE_PROJECT_DIR:-${cwd:-$PWD}}"
root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || echo "$root")"
slug="$(basename "$root")"
dir="$MEM/$slug"
day="$(date +%F)"

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
# ponytail: synchronous — a few seconds at exit. nohup/setsid it if that ever annoys.
out="$( cd "${TMPDIR:-/tmp}" 2>/dev/null || true
        { printf '%s\n\n=== TRANSCRIPT ===\n' "$PROMPT"; cat "$transcript"; } \
          | CLAUDE_WORKJOURNAL_LOCK=1 "$CLI" -p --model "$MODEL" 2>/dev/null )" || exit 0
[ -n "$out" ] || exit 0

first="${out%%$'\n'*}"
[ "$first" = "SKIP" ] && exit 0
case "$first" in *" :: "*) ;; *) exit 0 ;; esac   # unexpected shape → write nothing

taskslug="${first%% :: *}"
hook="${first#* :: }"
taskslug="$(printf '%s' "$taskslug" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//')"
taskslug="${taskslug:0:50}"
[ -n "$taskslug" ] || taskslug="session"

body="${out#*$'\n'}"                              # everything after line 1
body="${body#"${body%%[![:space:]]*}"}"          # strip leading blank lines

mkdir -p "$dir"
file="$day-$taskslug.md"
printf '%s\n' "$body" > "$dir/$file"

# Prepend the index line (newest first); seed a header on first run.
idx="$dir/INDEX.md"
[ -f "$idx" ] || printf '# %s — work journal\n\n' "$slug" > "$idx"
tmp="$(mktemp)"
{ head -n 2 "$idx"; printf -- '- [%s %s](%s) — %s\n' "$day" "$taskslug" "$file" "$hook"; tail -n +3 "$idx"; } > "$tmp"
mv "$tmp" "$idx"

# Rebuild the top-level router from disk — always consistent, no diff logic.
{ printf '# Work journal — projects\n\n'
  for p in "$MEM"/*/INDEX.md; do
    [ -e "$p" ] || continue
    d="$(basename "$(dirname "$p")")"
    n="$(grep -c '^- ' "$p" 2>/dev/null || true)"; n="${n:-0}"
    printf -- '- %s (%s entries) — %s/INDEX.md\n' "$d" "$n" "$d"
  done
} > "$MEM/ROUTER.md"
