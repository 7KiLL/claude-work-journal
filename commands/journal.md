---
description: Work journal umbrella — any subcommand (or use the split /journal-* commands)
argument-hint: doctor | ls | trim <p> [N] | mv <a> <b> | link <dir> … | unlink <dir> [slug] | chain [dir]
allowed-tools: Bash
---
Run the work-journal management script with the user's arguments and report its
output concisely. Don't add commentary beyond what the script prints. Each
subcommand also has a dedicated command (`/journal-doctor`, `/journal-link`, …).

```bash
root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"; [ -n "$root" ] && bash "$root/journal.sh" $ARGUMENTS
```

If no arguments were given, run it with none to show usage.
