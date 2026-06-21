#!/usr/bin/env bash
# Wire the work-journal hooks into Codex's config.toml.
#   install-codex.sh [print|install|uninstall]   (default: print)
# Codex uses the same hook schema as Claude Code, so this just points its
# SessionStart/Stop hooks at the recall.sh/capture.sh in this checkout.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
beg="# >>> work-journal >>>"
end="# <<< work-journal <<<"
block="$( printf '%s\n' "$beg"
          sed "s|__WJ_ROOT__|$here|g" "$here/hooks/codex.config.toml"
          printf '%s\n' "$end" )"

case "${1:-print}" in
  print)
    printf '%s\n' "$block"
    printf '\n# Add the block above to %s — or run: %s install\n' "$cfg" "$0"
    ;;
  install)
    mkdir -p "$(dirname "$cfg")"; touch "$cfg"
    if grep -qF "$beg" "$cfg"; then echo "already installed in $cfg"; exit 0; fi
    printf '\n%s\n' "$block" >> "$cfg"
    echo "installed work-journal hooks into $cfg"
    command -v claude >/dev/null 2>&1 || \
      echo "note: 'claude' not on PATH — set WORK_JOURNAL_SUMMARIZER (e.g. 'codex exec') so capture can summarize"
    ;;
  uninstall)
    [ -f "$cfg" ] || { echo "no $cfg"; exit 0; }
    grep -qF "$beg" "$cfg" || { echo "not installed in $cfg"; exit 0; }
    awk -v b="$beg" -v e="$end" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$cfg" > "$cfg.tmp"
    mv "$cfg.tmp" "$cfg"
    echo "removed work-journal hooks from $cfg"
    ;;
  *) echo "usage: install-codex.sh [print|install|uninstall]"; exit 1 ;;
esac
