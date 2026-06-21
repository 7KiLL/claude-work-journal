---
description: Work journal — create/update a .work-journal marker (slug=, root=, loads=)
argument-hint: <dir> [slug=NAME] [root=true] [loads=a,b]
allowed-tools: Bash
---
Create or update the directory's `.work-journal` marker and report the output
concisely. `loads=` unions into any existing loads. No extra commentary.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/journal.sh" link $ARGUMENTS
```
