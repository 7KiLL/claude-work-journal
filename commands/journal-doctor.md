---
description: Work journal — health check (deps, project count, recent errors)
allowed-tools: Bash
---
Run the work-journal doctor and report its output concisely. No extra commentary.

```bash
root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"; [ -n "$root" ] || { printf '%s\n' "plugin root not set"; exit 1; }; bash "$root/journal.sh" doctor
```
