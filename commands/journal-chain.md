---
description: Work journal — preview what recall loads from a dir (self + ancestors + loads)
argument-hint: [dir]
allowed-tools: Bash
---
Show the recall chain for the given directory (default: cwd) and report the
output concisely. No extra commentary.

```bash
root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"; [ -n "$root" ] || { printf '%s\n' "plugin root not set"; exit 1; }; bash "$root/journal.sh" chain $ARGUMENTS
```
