---
description: Work journal — list projects and entry counts
allowed-tools: Bash
---
List the work-journal projects and report the output concisely. No extra commentary.

```bash
root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"; [ -n "$root" ] || { printf '%s\n' "plugin root not set"; exit 1; }; bash "$root/journal.sh" ls
```
