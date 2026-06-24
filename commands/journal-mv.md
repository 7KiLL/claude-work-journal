---
description: Work journal — rename a project's journal, or merge it into another
argument-hint: <from> <to>
allowed-tools: Bash
---
Rename/merge the project journal and report the output concisely. No extra commentary.

```bash
root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"; [ -n "$root" ] && bash "$root/journal.sh" mv $ARGUMENTS
```
