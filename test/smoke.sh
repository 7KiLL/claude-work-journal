#!/usr/bin/env bash
# Smoke test for the hooks, with a stubbed `claude`. No network, no real model.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hooks="$here/plugins/work-journal/hooks"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export CLAUDE_MEMORY_DIR="$work/mem"
proj="$work/proj/myapp"; mkdir -p "$proj"
export CLAUDE_PROJECT_DIR="$proj"

# Stub claude via the CLAUDE_BIN seam: drain stdin (avoids SIGPIPE), print $STUB.
stub="$work/bin"; mkdir -p "$stub"
cat > "$stub/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
cat "$STUB"
STUB
chmod +x "$stub/claude"
export CLAUDE_BIN="$stub/claude"

transcript="$work/t.jsonl"; printf '{"x":1}\n' > "$transcript"
payload="$(jq -nc --arg t "$transcript" --arg c "$proj" '{transcript_path:$t,cwd:$c}')"
day="$(date +%F)"

# 1) a real entry gets written, indexed, routed
printf 'fix-auth-race :: fixed a token refresh race\n---\ntask: Fix auth race\nstatus: done\nfiles: auth.ts\n---\nNarrowed a TOCTOU on refresh.\n' > "$work/out.txt"
STUB="$work/out.txt" bash "$hooks/capture.sh" <<<"$payload"
[ -f "$CLAUDE_MEMORY_DIR/myapp/$day-fix-auth-race.md" ] || { echo "FAIL: entry not written"; exit 1; }
grep -q 'TOCTOU' "$CLAUDE_MEMORY_DIR/myapp/$day-fix-auth-race.md" || { echo "FAIL: body missing"; exit 1; }
grep -q 'fixed a token refresh race' "$CLAUDE_MEMORY_DIR/myapp/INDEX.md" || { echo "FAIL: index line missing"; exit 1; }
[ -f "$CLAUDE_MEMORY_DIR/ROUTER.md" ] || { echo "FAIL: router missing"; exit 1; }

# 2) SKIP writes nothing new
before="$(ls "$CLAUDE_MEMORY_DIR/myapp" | wc -l)"
printf 'SKIP\n' > "$work/out.txt"
STUB="$work/out.txt" bash "$hooks/capture.sh" <<<"$payload"
[ "$before" = "$(ls "$CLAUDE_MEMORY_DIR/myapp" | wc -l)" ] || { echo "FAIL: SKIP added files"; exit 1; }

# 3) recall emits additionalContext containing the index
ctx="$(bash "$hooks/recall.sh" </dev/null | jq -r '.hookSpecificOutput.additionalContext')"
printf '%s' "$ctx" | grep -q 'fixed a token refresh race' || { echo "FAIL: recall missing index"; exit 1; }

# 4) lock guard makes capture a no-op
rm -rf "$CLAUDE_MEMORY_DIR/myapp"
CLAUDE_WORKJOURNAL_LOCK=1 STUB="$work/out.txt" bash "$hooks/capture.sh" <<<"$payload"
[ -d "$CLAUDE_MEMORY_DIR/myapp" ] && { echo "FAIL: guard did not stop capture"; exit 1; }

echo "OK: all smoke checks passed"
