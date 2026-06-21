---
description: Manage the work journal — doctor, ls, trim, mv
argument-hint: doctor | ls | trim <project> [N] | mv <from> <to>
allowed-tools: Bash
---
Run the work-journal management script with the user's arguments and report its
output concisely. Don't add commentary beyond what the script prints.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/journal.sh" $ARGUMENTS
```

If no arguments were given, run it with none to show usage.
