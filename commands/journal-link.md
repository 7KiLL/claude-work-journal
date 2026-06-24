---
description: Work journal — create/update a .work-journal marker (slug=, root=, loads=)
argument-hint: <dir> [slug=NAME] [root=true] [loads=a,b]
allowed-tools: Bash
---
Create or update the directory's `.work-journal` marker and report the output
concisely. `loads=` unions into any existing loads. No extra commentary.

```bash
root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"; [ -n "$root" ] && bash "$root/journal.sh" link $ARGUMENTS
```
