---
description: Work journal — rename a project's journal, or merge it into another
argument-hint: <from> <to>
allowed-tools: Bash
---
Rename/merge the project journal and report the output concisely. Unsafe project
names are rejected by `journal.sh`. No extra commentary.

```bash
root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"; [ -n "$root" ] || { printf '%s\n' "plugin root not set"; exit 1; }; bash "$root/journal.sh" mv $ARGUMENTS
```
