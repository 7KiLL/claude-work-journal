#!/usr/bin/env bash
# SessionStart: inject this project's work-journal index, plus a one-time notice
# if capture logged any errors. Never blocks; a nonzero exit here is non-fatal.
set -uo pipefail

# Guard: capture runs `claude -p`, which re-fires this hook. The lock env var
# (set by capture.sh on that nested call) makes this a no-op inside it.
[ -n "${WORK_JOURNAL_LOCK:-}" ] && exit 0

MEM="${WORK_JOURNAL_DIR:-$HOME/.claude/work-journal}"
command -v jq >/dev/null 2>&1 || exit 0   # can't inject without jq (capture logs this)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/lib.sh"

# cwd selects the project; git root is the stable id. wj_resolve_slug handles
# same-named repos (suffixes -2/-3 only on a real collision).
root="${CLAUDE_PROJECT_DIR:-$PWD}"
root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || echo "$root")"
slug="$(wj_resolve_slug "$root" "$MEM")"
idx="$MEM/$slug/INDEX.md"

notice=""
# Surface capture errors once, then rotate so we don't nag forever.
if [ -s "$MEM/.errors.log" ]; then
  n="$(grep -c '' "$MEM/.errors.log" 2>/dev/null || echo '?')"
  notice="⚠️ work-journal logged $n issue(s) since last session — see $MEM/.errors.log"$'\n\n'
  mv -f "$MEM/.errors.log" "$MEM/.errors.log.shown" 2>/dev/null || true
fi

body=""
count=0
if [ -f "$idx" ]; then
  count="$(grep -c '^- \[' "$idx" 2>/dev/null || echo 0)"
  warn=""
  # ponytail: flat 150-entry threshold; raise/lower if it nags too early/late.
  [ "${count:-0}" -gt 150 ] && warn=" (this index has $count entries — consider trimming it)"
  body="## Work journal — ${slug}${warn}"$'\n'"Prior task entries; open a file when one is relevant to what we are about to do:"$'\n\n'"$(cat "$idx")"
fi

ctx="${notice}${body}"

# Visible one-line banner shown to the user. Silence with WORK_JOURNAL_QUIET=1.
msg=""
if [ -z "${WORK_JOURNAL_QUIET:-}" ]; then
  if [ "${count:-0}" -gt 0 ]; then
    word="entries"; [ "$count" = 1 ] && word="entry"
    msg="📓 work journal · ${slug} · ${count} ${word}"
  else
    msg="📓 work journal · ${slug} · new project"
  fi
fi

[ -n "$ctx$msg" ] || exit 0

# systemMessage is shown to the USER; additionalContext is injected into context.
jq -n --arg m "$msg" --arg c "$ctx" '
  (if $m == "" then {} else {systemMessage: $m} end)
  + (if $c == "" then {} else {hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}} end)'
