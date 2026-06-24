---
description: Work journal — remove a .work-journal marker, or one slug from its loads
argument-hint: <dir> [slug]
allowed-tools: Bash
---
Remove the marker (or just one slug from its loads) and report the output
concisely. No extra commentary.

```bash
root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"; [ -n "$root" ] && bash "$root/journal.sh" unlink $ARGUMENTS
```
