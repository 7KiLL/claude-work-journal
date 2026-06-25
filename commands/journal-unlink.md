---
description: Work journal — remove a .work-journal marker, or one slug from its loads
argument-hint: <dir> [slug]
allowed-tools: Bash
---
Remove the marker (or just one slug from its loads) and report the output
concisely. Unsafe slug tokens are rejected by `journal.sh`. No extra commentary.

```bash
root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"; [ -n "$root" ] || { printf '%s\n' "plugin root not set"; exit 1; }; bash "$root/journal.sh" unlink $ARGUMENTS
```
