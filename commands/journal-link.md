---
description: Work journal — create/update a .work-journal marker (slug=, root=, loads=)
argument-hint: <dir> [slug=NAME] [root=true] [loads=a,b]
allowed-tools: Bash
---
Create or update the directory's `.work-journal` marker and report the output
concisely. `loads=` unions into any existing loads. Unsafe slug/load tokens are
rejected by `journal.sh`. No extra commentary.

```bash
root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"; [ -n "$root" ] || { printf '%s\n' "plugin root not set"; exit 1; }; bash "$root/journal.sh" link $ARGUMENTS
```
