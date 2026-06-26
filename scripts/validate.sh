#!/usr/bin/env bash
# Lightweight repository checks for work-journal. Model-free and temp-dir only.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT" || exit 1

fail=0

ok() { printf 'ok - %s\n' "$1"; }
warn() { printf 'warn - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1"; fail=1; }

if bash -n journal.sh hooks/*.sh scripts/*.sh; then ok "shell syntax"; else bad "shell syntax"; fi

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
  if shellcheck hooks/*.sh journal.sh scripts/*.sh; then ok "shellcheck"; else bad "shellcheck"; fi
else
  warn "shellcheck not installed; skipped"
fi

if command -v node >/dev/null 2>&1; then
  if node --check kilo-plugin/work-journal.js >/dev/null; then ok "kilo plugin syntax"; else bad "kilo plugin syntax"; fi
else
  warn "node not installed; skipped kilo plugin syntax"
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

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if [ -f "$file" ] && grep -Fq "$needle" "$file"; then ok "$label"; else bad "$label"; fi
}

entry_count() {
  wj_entry_lines "$1" | grep -c '' 2>/dev/null || true
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

summarizer="$tmp/summarizer.sh"
cat > "$summarizer" <<'EOS'
#!/usr/bin/env bash
cat >/dev/null
case "${WJ_TEST_SUMMARY:-first}" in
  first)
    printf '%s\n' 'first-task :: first summary' '---' 'task: First' 'status: done' 'files: a.txt' '---' 'first body'
    ;;
  second)
    printf '%s\n' 'second-task :: second summary' '---' 'task: Second' 'status: done' 'files: b.txt' '---' 'second body'
    ;;
  malformed)
    printf '%s\n' 'malformed :: malformed summary' 'body without model frontmatter'
    ;;
esac
EOS
chmod +x "$summarizer"
capture_project="$tmp/capture-project"
mkdir "$capture_project" || exit 1

printf '{"message":"first"}\n' > "$tmp/transcript-1.jsonl"
if WORK_JOURNAL_DIR="$tmp/journal" WORK_JOURNAL_SUMMARIZER="$summarizer" WJ_TEST_SUMMARY=first \
  bash hooks/capture.sh --worker "$tmp/transcript-1.jsonl" "$capture_project" resume-session cap-one; then
  ok "capture worker creates entry"
else
  bad "capture worker creates entry"
fi
idx="$tmp/journal/capture-project/INDEX.md"
if [ "$(entry_count "$idx")" = 1 ]; then ok "capture creates one index entry"; else bad "capture creates one index entry"; fi
entry_file=""
for f in "$tmp/journal/capture-project"/20*.md; do [ -e "$f" ] && entry_file="$f" && break; done
assert_contains "$entry_file" 'session: resume-session' "capture stamps session"
assert_contains "$entry_file" 'capture: cap-one' "capture stamps capture key"

if WORK_JOURNAL_DIR="$tmp/journal" WORK_JOURNAL_SUMMARIZER="$summarizer" WJ_TEST_SUMMARY=second \
  bash hooks/capture.sh --worker "$tmp/transcript-1.jsonl" "$capture_project" resume-session cap-one; then
  ok "duplicate capture exits cleanly"
else
  bad "duplicate capture exits cleanly"
fi
if [ "$(entry_count "$idx")" = 1 ] && grep -Fq 'first body' "$entry_file"; then ok "duplicate capture does not rewrite entry"; else bad "duplicate capture does not rewrite entry"; fi

printf '{"message":"second"}\n' > "$tmp/transcript-2.jsonl"
if WORK_JOURNAL_DIR="$tmp/journal" WORK_JOURNAL_SUMMARIZER="$summarizer" WJ_TEST_SUMMARY=second \
  bash hooks/capture.sh --worker "$tmp/transcript-2.jsonl" "$capture_project" resume-session cap-two; then
  ok "resumed capture exits cleanly"
else
  bad "resumed capture exits cleanly"
fi
if [ "$(entry_count "$idx")" = 1 ]; then ok "resumed capture keeps one index entry"; else bad "resumed capture keeps one index entry"; fi
assert_contains "$entry_file" 'capture: cap-two' "resumed capture updates capture key"
assert_contains "$entry_file" 'second body' "resumed capture replaces body"
assert_contains "$idx" 'second summary' "resumed capture updates index summary"
assert_contains "$tmp/journal/capture-project/.captures" 'cap-one' "capture ledger preserves first key"
assert_contains "$tmp/journal/capture-project/.captures" 'cap-two' "capture ledger records resumed key"

printf '{"message":"malformed"}\n' > "$tmp/transcript-3.jsonl"
if WORK_JOURNAL_DIR="$tmp/journal" WORK_JOURNAL_SUMMARIZER="$summarizer" WJ_TEST_SUMMARY=malformed \
  bash hooks/capture.sh --worker "$tmp/transcript-3.jsonl" "$capture_project" malformed-session cap-malformed; then
  ok "malformed capture exits cleanly"
else
  bad "malformed capture exits cleanly"
fi
malformed_file=""
for f in "$tmp/journal/capture-project"/20*-malformed.md; do [ -e "$f" ] && malformed_file="$f" && break; done
assert_contains "$malformed_file" 'session: malformed-session' "malformed output gets session frontmatter"
assert_contains "$malformed_file" 'capture: cap-malformed' "malformed output gets capture frontmatter"

printf '{"transcript_path":"%s","cwd":"%s","session_id":"compact-session","reason":"compact"}\n' "$tmp/transcript-3.jsonl" "$capture_project" |
  WORK_JOURNAL_DIR="$tmp/journal" WORK_JOURNAL_SUMMARIZER="$summarizer" bash hooks/capture.sh >/dev/null 2>&1
if grep -Fq 'compact-session' "$tmp/journal/capture-project/.sessions" 2>/dev/null; then bad "dispatcher skips compaction captures"; else ok "dispatcher skips compaction captures"; fi

merge_dir="$tmp/journal/merge-target"
mkdir "$merge_dir" || exit 1
printf '%s\n\n' '# merge-target - work journal' > "$merge_dir/INDEX.md"
printf '%s\n' '---' 'session: existing-session' 'capture: existing-cap' '---' 'existing body' > "$merge_dir/2026-01-01-existing.md"
printf '%s\n' '- [2026-01-01 existing](2026-01-01-existing.md) — existing' >> "$merge_dir/INDEX.md"
printf '%s\n' 'existing-cap' > "$merge_dir/.captures"
printf '%s\t%s\n' 'existing-session' '2026-01-01-existing.md' > "$merge_dir/.sessions"
if WORK_JOURNAL_DIR="$tmp/journal" bash journal.sh mv capture-project merge-target > "$tmp/mv.out" 2>&1; then
  ok "mv merge exits cleanly"
else
  bad "mv merge exits cleanly"
fi
assert_contains "$merge_dir/.captures" 'cap-two' "mv merge preserves capture ledger"
assert_contains "$merge_dir/.sessions" 'resume-session' "mv merge preserves session ledger"

if WORK_JOURNAL_DIR="$tmp/doctor-journal" WORK_JOURNAL_SUMMARIZER="$summarizer" bash journal.sh doctor --strict > "$tmp/doctor.out" 2>&1; then
  ok "doctor strict passes in temp journal"
else
  bad "doctor strict passes in temp journal"
fi

if [ -e .agents/plugins/plugins/work-journal/hooks ] && [ -e .agents/plugins/plugins/work-journal/journal.sh ]; then
  ok "codex marketplace mirror paths resolve"
else
  bad "codex marketplace mirror paths resolve"
fi

if [ -f kilo-plugin/work-journal.js ]; then
  ok "kilo plugin adapter exists"
else
  bad "kilo plugin adapter exists"
fi

if [ -x scripts/install.sh ]; then
  ok "install helper is executable"
else
  bad "install helper is executable"
fi

install_tmp="$tmp/install-target"
mkdir "$install_tmp" || exit 1
if bash scripts/install.sh kilo --project "$install_tmp" > "$tmp/install-kilo.out" 2>&1; then
  ok "installer writes Kilo project config"
else
  bad "installer writes Kilo project config"
fi
assert_contains "$install_tmp/.kilo/kilo.jsonc" '"plugin"' "Kilo installer config has plugin key"
assert_contains "$install_tmp/.kilo/kilo.jsonc" 'file://' "Kilo installer config uses file URL"

if bash scripts/install.sh opencode --project "$install_tmp" > "$tmp/install-opencode.out" 2>&1; then
  ok "installer writes OpenCode plugin wrapper"
else
  bad "installer writes OpenCode plugin wrapper"
fi
assert_contains "$install_tmp/.opencode/plugins/work-journal.js" 'export { WorkJournal }' "OpenCode installer exports plugin"
assert_contains "$install_tmp/.opencode/plugins/work-journal.js" 'file://' "OpenCode installer wrapper uses file URL"

exit "$fail"
