---
description: Work journal — keep newest N entries, summarize the rest into archive.md
argument-hint: <project> [N]
allowed-tools: Bash
---
Trim the given project's journal and report the output concisely. No extra commentary.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/journal.sh" trim $ARGUMENTS
```
