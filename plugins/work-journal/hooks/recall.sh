#!/usr/bin/env bash
# SessionStart: inject this project's work-journal index into the model context.
set -euo pipefail

# Guard: the capture step runs `claude -p`, which re-fires this hook. The lock
# env var (set by capture.sh) makes both hooks no-op inside that sub-session.
[ -n "${CLAUDE_WORKJOURNAL_LOCK:-}" ] && exit 0

MEM="${CLAUDE_MEMORY_DIR:-$HOME/.claude/memory}"

# cwd selects the project — no router query needed. git root is the stable id.
root="${CLAUDE_PROJECT_DIR:-$PWD}"
root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || echo "$root")"
slug="$(basename "$root")"
idx="$MEM/$slug/INDEX.md"

[ -f "$idx" ] || exit 0   # nothing remembered for this project yet → stay quiet

ctx="$(printf '## Work journal — %s\nPrior task entries for this project. Open a file when one looks relevant to what we are about to do:\n\n' "$slug"; cat "$idx")"

# Plain stdout is NOT injected; SessionStart context must be this JSON shape.
jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
