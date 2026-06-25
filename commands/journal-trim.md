---
description: Work journal — keep newest N entries, summarize the rest into archive.md
argument-hint: <project> [N]
allowed-tools: Bash
---
Trim the given project's journal and report the output concisely. Unsafe project
names and invalid keep counts are rejected by `journal.sh`. No extra commentary.

```bash
root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"; [ -n "$root" ] || { printf '%s\n' "plugin root not set"; exit 1; }; bash "$root/journal.sh" trim $ARGUMENTS
```
