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

# cwd selects the project; git root is the stable id. wj_recall_chain handles
# same-named repos plus ancestor (.work-journal) and `loads:` inheritance.
root="${CLAUDE_PROJECT_DIR:-$PWD}"
root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || echo "$root")"

notice=""
# Surface capture errors once, then rotate so we don't nag forever.
if [ -s "$MEM/.errors.log" ]; then
  n="$(grep -c '' "$MEM/.errors.log" 2>/dev/null || echo '?')"
  notice="⚠️ work-journal logged $n issue(s) since last session — see $MEM/.errors.log"$'\n\n'
  mv -f "$MEM/.errors.log" "$MEM/.errors.log.shown" 2>/dev/null || true
fi

# Walk the chain: self (the project you're in), then any inherited journals.
self=""; count=0; extra=0; body=""
while IFS="$(printf '\t')" read -r tag slug; do
  [ -n "$slug" ] || continue
  sidx="$MEM/$slug/INDEX.md"
  if [ "$tag" = self ]; then
    self="$slug"
    [ -f "$sidx" ] || continue
    count="$(grep -c '^- \[' "$sidx" 2>/dev/null || echo 0)"
    warn=""
    # ponytail: flat 150-entry threshold; raise/lower if it nags too early/late.
    [ "${count:-0}" -gt 150 ] && warn=" (this index has $count entries — consider trimming it)"
    body="## Work journal — ${slug}${warn}"$'\n'"Prior task entries; open a file when one is relevant to what we are about to do:"$'\n\n'"$(cat "$sidx")"
  else
    [ -f "$sidx" ] || continue
    label="linked"; [ "$tag" = parent ] && label="ancestor"
    body="${body}"$'\n\n'"## Linked journal — ${slug} (${label})"$'\n\n'"$(cat "$sidx")"
    extra=$((extra+1))
  fi
done < <(wj_recall_chain "$root" "$MEM")

ctx="${notice}${body}"

# Visible one-line banner shown to the user. Silence with WORK_JOURNAL_QUIET=1.
msg=""
if [ -z "${WORK_JOURNAL_QUIET:-}" ]; then
  if [ "${count:-0}" -gt 0 ]; then
    word="entries"; [ "$count" = 1 ] && word="entry"
    msg="📓 work journal · ${self} · ${count} ${word}"
  else
    msg="📓 work journal · ${self} · new project"
  fi
  [ "$extra" -gt 0 ] && msg="${msg} (+${extra} linked)"
fi

[ -n "$ctx$msg" ] || exit 0

# systemMessage is shown to the USER; additionalContext is injected into context.
jq -n --arg m "$msg" --arg c "$ctx" '
  (if $m == "" then {} else {systemMessage: $m} end)
  + (if $c == "" then {} else {hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}} end)'
