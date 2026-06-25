---
description: Work journal umbrella — any subcommand (or use the split /journal-* commands)
argument-hint: doctor | ls | trim <p> [N] | mv <a> <b> | link <dir> … | unlink <dir> [slug] | chain [dir]
allowed-tools: Bash
---
Run the work-journal management script with the user's arguments and report its
output concisely. Don't add commentary beyond what the script prints. Each
subcommand also has a dedicated command (`/journal-doctor`, `/journal-link`, …).
Unsafe project, slug, count, and file-link arguments are rejected by `journal.sh`;
report that error directly.

```bash
root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"; [ -n "$root" ] || { printf '%s\n' "plugin root not set"; exit 1; }; bash "$root/journal.sh" $ARGUMENTS
```

If no arguments were given, run it with none to show usage.
