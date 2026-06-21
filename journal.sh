#!/usr/bin/env bash
# work-journal management CLI: doctor | ls | trim <project> [N] | mv <from> <to>
# Pure bash; only `trim` calls the model (to summarize archived entries).
set -uo pipefail

MEM="${CLAUDE_MEMORY_DIR:-$HOME/.claude/memory}"
MODEL="${CLAUDE_MEMORY_MODEL:-haiku}"
CLI="${CLAUDE_BIN:-claude}"

usage() {
  cat <<'EOF'
work-journal — manage ~/.claude/memory
  doctor              health check: deps, project count, recent errors
  ls                  list projects and entry counts
  trim <project> [N]  keep newest N entries (default 30); summarize the rest into archive.md
  mv <from> <to>      rename a project's journal, or merge it into an existing one
EOF
}

rebuild_router() {
  [ -d "$MEM" ] || return 0
  { printf '# Work journal — projects\n\n'
    for p in "$MEM"/*/INDEX.md; do
      [ -e "$p" ] || continue
      d="$(basename "$(dirname "$p")")"
      n="$(grep -c '^- ' "$p" 2>/dev/null || true)"; n="${n:-0}"
      printf -- '- %s (%s entries) — %s/INDEX.md\n' "$d" "$n" "$d"
    done
  } > "$MEM/ROUTER.md"
}

index_lines() { grep '^- \[' "$1" 2>/dev/null || true; }   # the "- [date slug](file) — hook" lines

cmd="${1:-}"; [ $# -gt 0 ] && shift

case "$cmd" in
  doctor)
    echo "memory dir: $MEM"
    for b in jq git "$CLI"; do
      if command -v "$b" >/dev/null 2>&1; then echo "  dep ok:      $b"; else echo "  dep MISSING: $b"; fi
    done
    np=0
    if [ -d "$MEM" ]; then for d in "$MEM"/*/; do [ -d "$d" ] && np=$((np+1)); done; fi
    echo "projects: $np"
    for f in "$MEM/.errors.log" "$MEM/.errors.log.shown"; do
      [ -s "$f" ] && { echo "--- $(basename "$f") (last 20) ---"; tail -n 20 "$f"; }
    done
    ;;

  ls)
    [ -d "$MEM" ] || { echo "(no journal yet)"; exit 0; }
    found=0
    for p in "$MEM"/*/INDEX.md; do
      [ -e "$p" ] || continue
      found=1
      d="$(basename "$(dirname "$p")")"
      n="$(grep -c '^- ' "$p" 2>/dev/null || true)"; n="${n:-0}"
      printf '%-30s %s entries\n' "$d" "$n"
    done
    [ "$found" = 1 ] || echo "(no projects)"
    ;;

  trim)
    proj="${1:-}"; keep="${2:-30}"
    [ -n "$proj" ] || { echo "usage: trim <project> [N]"; exit 1; }
    dir="$MEM/$proj"; idx="$dir/INDEX.md"
    [ -f "$idx" ] || { echo "no such project: $proj"; exit 1; }
    lines=()
    while IFS= read -r l; do lines+=("$l"); done < <(index_lines "$idx")
    total=${#lines[@]}
    [ "$total" -gt "$keep" ] || { echo "$total entries; nothing to trim (keep=$keep)"; exit 0; }
    keeplines=( "${lines[@]:0:$keep}" )
    oldlines=( "${lines[@]:$keep}" )
    oldfiles=()
    for l in "${oldlines[@]}"; do f="${l#*](}"; f="${f%%)*}"; oldfiles+=("$f"); done

    catf="$(mktemp)"
    for f in "${oldfiles[@]}"; do
      [ -f "$dir/$f" ] && { echo "### $f"; cat "$dir/$f"; echo; } >> "$catf"
    done
    summary="$( { printf 'Compress these older work-journal entries into a terse "Earlier work" digest — a handful of bullets capturing notable tasks, decisions, and gotchas. No fluff.\n\n'; cat "$catf"; } \
                | CLAUDE_WORKJOURNAL_LOCK=1 "$CLI" -p --model "$MODEL" 2>/dev/null )" || true
    rm -f "$catf"
    [ -n "$summary" ] || summary="(digest unavailable — ${#oldfiles[@]} entries archived without summary)"

    arch="$dir/archive.md"
    { [ -f "$arch" ] && cat "$arch"; printf '\n## Trimmed %s (%d entries)\n\n%s\n' "$(date +%F)" "${#oldfiles[@]}" "$summary"; } > "$arch.tmp" && mv "$arch.tmp" "$arch"
    for f in "${oldfiles[@]}"; do rm -f "$dir/$f"; done
    { head -n 2 "$idx"; printf '%s\n' "${keeplines[@]}"; printf -- '- [archive](archive.md) — older entries, summarized\n'; } > "$idx.tmp" && mv "$idx.tmp" "$idx"
    rebuild_router
    echo "trimmed ${#oldfiles[@]} entries into archive.md; kept $keep newest"
    ;;

  mv)
    from="${1:-}"; to="${2:-}"
    { [ -n "$from" ] && [ -n "$to" ]; } || { echo "usage: mv <from> <to>"; exit 1; }
    src="$MEM/$from"; dst="$MEM/$to"
    [ -d "$src" ] || { echo "no such project: $from"; exit 1; }
    if [ ! -d "$dst" ]; then
      mv "$src" "$dst"
      echo "renamed $from -> $to"
    else
      for f in "$src"/*.md; do
        [ -e "$f" ] || continue
        bn="$(basename "$f")"
        case "$bn" in INDEX.md|archive.md) continue ;; esac
        mv -n "$f" "$dst/$bn"
      done
      [ -f "$src/archive.md" ] && cat "$src/archive.md" >> "$dst/archive.md"
      header="$(head -n 1 "$dst/INDEX.md" 2>/dev/null || echo "# $to — work journal")"
      merged="$( { index_lines "$dst/INDEX.md"; index_lines "$src/INDEX.md"; } | sort -r | awk '!seen[$0]++' )"
      { printf '%s\n\n' "$header"; printf '%s\n' "$merged"; } > "$dst/INDEX.md"
      rm -rf "$src"
      echo "merged $from into $to"
    fi
    rebuild_router
    ;;

  ""|-h|--help|help) usage ;;
  *) echo "unknown command: $cmd"; echo; usage; exit 1 ;;
esac
