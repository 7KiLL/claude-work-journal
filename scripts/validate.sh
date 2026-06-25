#!/usr/bin/env bash
# Lightweight repository checks for work-journal. Model-free and temp-dir only.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT" || exit 1

fail=0

ok() { printf 'ok - %s\n' "$1"; }
warn() { printf 'warn - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1"; fail=1; }

if bash -n journal.sh hooks/*.sh scripts/validate.sh; then ok "shell syntax"; else bad "shell syntax"; fi

json_files=(
  .claude-plugin/plugin.json
  .codex-plugin/plugin.json
  .claude-plugin/marketplace.json
  .agents/plugins/marketplace.json
  hooks/hooks.json
  hooks/hooks.codex.json
)

if command -v jq >/dev/null 2>&1; then
  if jq -e . "${json_files[@]}" >/dev/null; then ok "json manifests parse"; else bad "json manifests parse"; fi
  claude_v="$(jq -r .version .claude-plugin/plugin.json)"
  codex_v="$(jq -r .version .codex-plugin/plugin.json)"
  if [ "$claude_v" = "$codex_v" ]; then ok "plugin versions match ($claude_v)"; else bad "plugin versions differ: claude=$claude_v codex=$codex_v"; fi
else
  bad "jq is required for manifest and hook validation"
fi

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck hooks/*.sh journal.sh scripts/validate.sh; then ok "shellcheck"; else bad "shellcheck"; fi
else
  warn "shellcheck not installed; skipped"
fi

# shellcheck source=../hooks/lib.sh
source hooks/lib.sh

assert_valid() {
  local fn="$1" value="$2" label="$3"
  if "$fn" "$value"; then ok "$label"; else bad "$label"; fi
}

assert_invalid() {
  local fn="$1" value="$2" label="$3"
  if "$fn" "$value"; then bad "$label"; else ok "$label"; fi
}

assert_valid wj_valid_slug good-slug_1 "valid slug accepted"
assert_invalid wj_valid_slug ../bad "path slug rejected"
assert_invalid wj_valid_slug "bad slug" "space slug rejected"
assert_valid wj_valid_project "legacy project" "legacy project component accepted"
assert_invalid wj_valid_project ../bad "path project rejected"
assert_valid wj_valid_entry_file 2026-06-25-safe-entry.md "entry filename accepted"
assert_invalid wj_valid_entry_file ../../bad.md "path entry filename rejected"
assert_valid wj_valid_keep 0 "zero keep accepted"
assert_invalid wj_valid_keep abc "non-numeric keep rejected"
assert_valid wj_valid_cap 200000 "valid cap accepted"
assert_invalid wj_valid_cap 0 "zero cap rejected"

tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/project" "$tmp/journal" "$tmp/journal/proj" || exit 1

if WORK_JOURNAL_DIR="$tmp/journal" bash journal.sh link "$tmp/project" slug=good root=true loads=alpha,beta >/dev/null; then
  ok "link accepts safe marker"
else
  bad "link accepts safe marker"
fi

if WORK_JOURNAL_DIR="$tmp/journal" bash journal.sh link "$tmp/project" slug=../bad >"$tmp/out" 2>&1; then
  bad "link rejects unsafe slug"
else
  ok "link rejects unsafe slug"
fi

printf '# proj - work journal\n\n' > "$tmp/journal/proj/INDEX.md"
if WORK_JOURNAL_DIR="$tmp/journal" bash journal.sh trim proj abc >"$tmp/out" 2>&1; then
  bad "trim rejects invalid keep"
else
  ok "trim rejects invalid keep"
fi

if command -v jq >/dev/null 2>&1; then
  recall_out="$tmp/recall.json"
  if printf '{"cwd":"%s"}\n' "$tmp/project" | WORK_JOURNAL_DIR="$tmp/journal" bash hooks/recall.sh > "$recall_out"; then
    if [ -s "$recall_out" ]; then
      if jq -e . "$recall_out" >/dev/null; then ok "recall emits valid json"; else bad "recall emits valid json"; fi
    else
      ok "recall may exit silently"
    fi
  else
    bad "recall hook exits cleanly"
  fi
fi

if [ -e .agents/plugins/plugins/work-journal/hooks ] && [ -e .agents/plugins/plugins/work-journal/journal.sh ]; then
  ok "codex marketplace mirror paths resolve"
else
  bad "codex marketplace mirror paths resolve"
fi

exit "$fail"
