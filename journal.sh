#!/usr/bin/env bash
# work-journal management CLI: doctor | ls | trim <project> [N] | mv <from> <to>
# Pure bash; only `trim` calls the model (to summarize archived entries).
set -uo pipefail

MEM="${WORK_JOURNAL_DIR:-$HOME/.claude/work-journal}"
MODEL="${WORK_JOURNAL_MODEL:-haiku}"
CLI="${CLAUDE_BIN:-claude}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/hooks/lib.sh"

usage() {
  cat <<'EOF'
work-journal — manage ~/.claude/work-journal
  doctor                health check: deps, project count, recent errors
  ls                    list projects and entry counts
  trim <project> [N]    keep newest N entries (default 30); summarize the rest into archive.md
  mv <from> <to>        rename a project's journal, or merge it into an existing one
  link <dir> [k=v …]    create/update a .work-journal marker (slug=, root=, loads=)
  unlink <dir> [slug]   remove the marker, or just one slug from its loads
  chain [dir]           preview what recall would load from <dir> (default: cwd)
EOF
}

index_lines() { grep '^- \[' "$1" 2>/dev/null || true; }   # the "- [date slug](file) — hook" lines

# Union two comma/space lists into a "a, b, c" string, order-preserving, deduped.
merge_loads() {
  local tok out="" seen="|"
  for tok in ${1//,/ } ${2//,/ }; do
    [ -n "$tok" ] || continue
    case "$seen" in *"|$tok|"*) continue ;; esac
    out="${out:+$out, }$tok"; seen="$seen$tok|"
  done
  printf '%s' "$out"
}

# (Re)write $1/.work-journal from slug/root/loads ($2/$3/$4); empty fields drop out.
write_marker() {
  local f="$1/.work-journal"
  { [ -n "$2" ] && printf 'slug: %s\n' "$2"
    [ -n "$3" ] && printf 'root: %s\n' "$3"
    [ -n "$4" ] && printf 'loads: %s\n' "$4"; } > "$f"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift

case "$cmd" in
  doctor)
    echo "journal dir: $MEM"
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
                | WORK_JOURNAL_LOCK=1 "$CLI" -p --model "$MODEL" 2>/dev/null )" || true
    rm -f "$catf"
    [ -n "$summary" ] || summary="(digest unavailable — ${#oldfiles[@]} entries archived without summary)"

    arch="$dir/archive.md"
    { [ -f "$arch" ] && cat "$arch"; printf '\n## Trimmed %s (%d entries)\n\n%s\n' "$(date +%F)" "${#oldfiles[@]}" "$summary"; } > "$arch.tmp" && mv "$arch.tmp" "$arch"
    for f in "${oldfiles[@]}"; do rm -f "$dir/$f"; done
    { head -n 2 "$idx"; printf '%s\n' "${keeplines[@]}"; printf -- '- [archive](archive.md) — older entries, summarized\n'; } > "$idx.tmp" && mv "$idx.tmp" "$idx"
    wj_rebuild_router "$MEM"
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
    wj_rebuild_router "$MEM"
    ;;

  link)
    dir="${1:-}"; [ $# -gt 0 ] && shift
    [ -n "$dir" ] || { echo "usage: link <dir> [slug=NAME] [root=true] [loads=a,b]"; exit 1; }
    [ -d "$dir" ] || { echo "no such directory: $dir"; exit 1; }
    s="$(wj_marker_field "$dir" slug)"; r="$(wj_marker_field "$dir" root)"; l="$(wj_marker_field "$dir" loads)"
    for kv in "$@"; do
      case "$kv" in
        slug=*)  s="${kv#slug=}" ;;
        root=*)  r="${kv#root=}" ;;
        loads=*) l="$(merge_loads "$l" "${kv#loads=}")" ;;   # link = add a connection → union
        *) echo "unknown field: $kv (want slug=, root=, or loads=)"; exit 1 ;;
      esac
    done
    write_marker "$dir" "$s" "$r" "$l"
    if [ -s "$dir/.work-journal" ]; then echo "wrote $dir/.work-journal:"; sed 's/^/  /' "$dir/.work-journal"
    else echo "marked $dir (empty marker — node named '$(basename "$dir")')"; fi
    ;;

  unlink)
    dir="${1:-}"; rm_slug="${2:-}"
    [ -n "$dir" ] || { echo "usage: unlink <dir> [slug]"; exit 1; }
    f="$dir/.work-journal"
    [ -f "$f" ] || { echo "no marker at $dir"; exit 0; }
    if [ -z "$rm_slug" ]; then
      rm -f "$f"; echo "removed marker $f"
    else
      s="$(wj_marker_field "$dir" slug)"; r="$(wj_marker_field "$dir" root)"
      new=""; for tok in $(wj_marker_field "$dir" loads | tr ',' ' '); do
        [ "$tok" = "$rm_slug" ] && continue; new="$(merge_loads "$new" "$tok")"; done
      write_marker "$dir" "$s" "$r" "$new"
      echo "removed '$rm_slug' from loads in $f"
    fi
    ;;

  chain)
    dir="${1:-$PWD}"
    root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")"
    echo "recall chain for $root:"
    while IFS="$(printf '\t')" read -r tag slug; do
      [ -n "$slug" ] || continue
      [ -d "$MEM/$slug" ] && mark="✓ has journal" || mark="· no journal yet (load is a no-op)"
      printf '  %-7s %-24s %s\n' "$tag" "$slug" "$mark"
    done < <(wj_recall_chain "$root" "$MEM")
    ;;

  ""|-h|--help|help) usage ;;
  *) echo "unknown command: $cmd"; echo; usage; exit 1 ;;
esac
