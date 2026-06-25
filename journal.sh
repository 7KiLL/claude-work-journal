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

# (Re)write $1/.work-journal from slug/root/loads ($2/$3/$4); empty fields drop out.
write_marker() {
  local f="$1/.work-journal"
  local tmp
  tmp="$(wj_tmp_for "$f")" || return 1
  { [ -n "$2" ] && printf 'slug: %s\n' "$2"
    [ -n "$3" ] && printf 'root: %s\n' "$3"
    [ -n "$4" ] && printf 'loads: %s\n' "$4"
    true; } > "$tmp" && mv -f "$tmp" "$f" || {
    rm -f "$tmp"
    return 1
  }
}

oldfile_contains() {
  local want="$1" f
  for f in "${oldfiles[@]}"; do
    [ "$f" = "$want" ] && return 0
  done
  return 1
}

trim_commit() {
  local l f present=0 removed=0 arch arch_tmp idx_tmp
  [ -f "$idx" ] || { echo "no such project: $proj"; return 1; }
  while IFS= read -r l; do
    f="$(wj_entry_file_from_line "$l")" || continue
    oldfile_contains "$f" && { present=1; break; }
  done < <(wj_entry_lines "$idx")
  [ "$present" = 1 ] || { echo "entries already trimmed; nothing to update"; return 0; }

  arch="$dir/archive.md"
  arch_tmp="$(wj_tmp_for "$arch")" || return 1
  { [ -f "$arch" ] && cat "$arch"; printf '\n## Trimmed %s (%d entries)\n\n%s\n' "$(date +%F)" "${#oldfiles[@]}" "$summary"; } > "$arch_tmp" && mv -f "$arch_tmp" "$arch" || {
    rm -f "$arch_tmp"
    return 1
  }

  for f in "${oldfiles[@]}"; do
    [ -f "$dir/$f" ] || continue
    rm -f "$dir/$f" && removed=$((removed+1))
  done

  idx_tmp="$(wj_tmp_for "$idx")" || return 1
  {
    head -n 2 "$idx"
    while IFS= read -r l; do
      f="$(wj_entry_file_from_line "$l")" || continue
      oldfile_contains "$f" && continue
      printf '%s\n' "$l"
    done < <(wj_entry_lines "$idx")
    printf -- '- [archive](archive.md) — older entries, summarized\n'
  } > "$idx_tmp" && mv -f "$idx_tmp" "$idx" || {
    rm -f "$idx_tmp"
    return 1
  }
  wj_rebuild_router "$MEM" || true
  echo "trimmed $removed entries into archive.md; kept target $keep newest"
}

mv_lookup() {
  local want="$1" i
  i=0
  while [ "$i" -lt "${#renamed_from[@]}" ]; do
    [ "${renamed_from[$i]}" = "$want" ] && { printf '%s' "${renamed_to[$i]}"; return 0; }
    i=$((i+1))
  done
  printf '%s' "$want"
}

mv_commit() {
  local header f bn base n newbn src_arch dst_arch arch_tmp entries_tmp idx_tmp l tgt newtgt seen
  [ -d "$src" ] || { echo "no such project: $from"; return 1; }
  if [ ! -d "$dst" ]; then
    mv "$src" "$dst" || return 1
    wj_rebuild_router "$MEM" || true
    echo "renamed $from -> $to"
    return 0
  fi

  renamed_from=(); renamed_to=()
  for f in "$src"/*.md; do
    [ -e "$f" ] || continue
    bn="$(basename "$f")"
    case "$bn" in INDEX.md|archive.md) continue ;; esac
    wj_valid_path_component "$bn" || continue
    if [ ! -e "$dst/$bn" ]; then
      mv "$f" "$dst/$bn" || return 1
    else
      base="${bn%.md}"; n=2
      while [ -e "$dst/$base-$n.md" ]; do n=$((n+1)); done
      newbn="$base-$n.md"
      mv "$f" "$dst/$newbn" || return 1
      renamed_from+=("$bn"); renamed_to+=("$newbn")
    fi
  done

  src_arch="$src/archive.md"; dst_arch="$dst/archive.md"
  if [ -f "$src_arch" ]; then
    arch_tmp="$(wj_tmp_for "$dst_arch")" || return 1
    { [ -f "$dst_arch" ] && cat "$dst_arch"; cat "$src_arch"; } > "$arch_tmp" && mv -f "$arch_tmp" "$dst_arch" || {
      rm -f "$arch_tmp"
      return 1
    }
  fi

  header="$(head -n 1 "$dst/INDEX.md" 2>/dev/null || echo "# $to — work journal")"
  entries_tmp="$(wj_tmp_for "$dst/INDEX.entries")" || return 1
  {
    wj_entry_lines "$dst/INDEX.md"
    wj_entry_lines "$src/INDEX.md" | while IFS= read -r l; do
      tgt="$(wj_entry_file_from_line "$l")" || continue
      newtgt="$(mv_lookup "$tgt")"
      if [ "$newtgt" != "$tgt" ]; then
        printf '%s\n' "${l/($tgt)/($newtgt)}"
      else
        printf '%s\n' "$l"
      fi
    done
  } | sort -r > "$entries_tmp"

  idx_tmp="$(wj_tmp_for "$dst/INDEX.md")" || { rm -f "$entries_tmp"; return 1; }
  {
    printf '%s\n\n' "$header"
    seen="|"
    while IFS= read -r l; do
      tgt="$(wj_entry_file_from_line "$l")" || continue
      case "$seen" in *"|$tgt|"*) continue ;; esac
      printf '%s\n' "$l"
      seen="$seen$tgt|"
    done < "$entries_tmp"
    [ -f "$dst_arch" ] && printf -- '- [archive](archive.md) — older entries, summarized\n'
    true
  } > "$idx_tmp" && mv -f "$idx_tmp" "$dst/INDEX.md" || {
    rm -f "$idx_tmp" "$entries_tmp"
    return 1
  }
  rm -f "$entries_tmp"
  rm -rf "$src"
  wj_rebuild_router "$MEM" || true
  echo "merged $from into $to"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift

case "$cmd" in
  doctor)
    echo "journal dir: $MEM"
    echo "bash:        ${BASH_VERSION:-unknown}"
    if command -v flock >/dev/null 2>&1; then
      echo "lock:        flock"
    else
      echo "lock:        mkdir fallback (flock not found)"
    fi
    deps="jq git"
    if [ -n "${WORK_JOURNAL_SUMMARIZER:-}" ]; then
      echo "summarizer:  $WORK_JOURNAL_SUMMARIZER (custom)"
    elif command -v "$CLI" >/dev/null 2>&1; then
      echo "summarizer:  $CLI -p --model $MODEL"; deps="$deps $CLI"
    elif command -v codex >/dev/null 2>&1; then
      echo "summarizer:  codex exec (claude not found)"; deps="$deps codex"
    else
      echo "summarizer:  NONE — install claude/codex or set WORK_JOURNAL_SUMMARIZER"
    fi
    for b in $deps; do
      if command -v "$b" >/dev/null 2>&1; then echo "  dep ok:      $b"; else echo "  dep MISSING: $b"; fi
    done
    np=0; ne=0
    if [ -d "$MEM" ]; then for d in "$MEM"/*/INDEX.md; do
      [ -e "$d" ] || continue
      np=$((np+1))
      c="$(wj_entry_lines "$d" | grep -c '' 2>/dev/null || true)"; ne=$((ne+${c:-0}))
    done; fi
    echo "projects: $np (${ne} entries total)"
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
      n="$(wj_entry_lines "$p" | grep -c '' 2>/dev/null || true)"; n="${n:-0}"
      printf '%-30s %s entries\n' "$d" "$n"
    done
    [ "$found" = 1 ] || echo "(no projects)"
    ;;

  trim)
    proj="${1:-}"; keep="${2:-30}"
    [ -n "$proj" ] || { echo "usage: trim <project> [N]"; exit 1; }
    wj_valid_project "$proj" || { echo "invalid project name: $proj"; exit 1; }
    wj_valid_keep "$keep" || { echo "invalid keep count: $keep"; exit 1; }
    dir="$MEM/$proj"; idx="$dir/INDEX.md"
    [ -f "$idx" ] || { echo "no such project: $proj"; exit 1; }
    # Snapshot only selects files to summarize. The final mutation re-reads the
    # index under lock so captures that land during the model call are preserved.
    lines=()
    while IFS= read -r l; do lines+=("$l"); done < <(wj_entry_lines "$idx")
    total=${#lines[@]}
    [ "$total" -gt "$keep" ] || { echo "$total entries; nothing to trim (keep=$keep)"; exit 0; }
    oldlines=( "${lines[@]:$keep}" )
    oldfiles=()
    for l in "${oldlines[@]}"; do
      f="$(wj_entry_file_from_line "$l")" || continue
      oldfiles+=("$f")
    done
    [ "${#oldfiles[@]}" -gt 0 ] || { echo "no safe entry files to trim"; exit 0; }

    catf="$(mktemp)"
    for f in "${oldfiles[@]}"; do
      [ -f "$dir/$f" ] && { echo "### $f"; cat "$dir/$f"; echo; } >> "$catf"
    done
    summary="$( { printf 'Compress these older work-journal entries into a terse "Earlier work" digest — a handful of bullets capturing notable tasks, decisions, and gotchas. No fluff.\n\n'; cat "$catf"; } \
                | wj_summarize 2>/dev/null )" || true
    rm -f "$catf"
    [ -n "$summary" ] || summary="(digest unavailable — ${#oldfiles[@]} entries archived without summary)"

    wj_with_lock "$MEM" trim_commit || { echo "journal update failed"; exit 1; }
    ;;

  mv)
    from="${1:-}"; to="${2:-}"
    { [ -n "$from" ] && [ -n "$to" ]; } || { echo "usage: mv <from> <to>"; exit 1; }
    wj_valid_project "$from" || { echo "invalid source project name: $from"; exit 1; }
    wj_valid_project "$to" || { echo "invalid destination project name: $to"; exit 1; }
    [ "$from" != "$to" ] || { echo "source and destination are the same"; exit 0; }
    src="$MEM/$from"; dst="$MEM/$to"
    wj_with_lock "$MEM" mv_commit || { echo "journal update failed"; exit 1; }
    ;;

  link)
    dir="${1:-}"; [ $# -gt 0 ] && shift
    [ -n "$dir" ] || { echo "usage: link <dir> [slug=NAME] [root=true] [loads=a,b]"; exit 1; }
    [ -d "$dir" ] || { echo "no such directory: $dir"; exit 1; }
    s="$(wj_marker_field "$dir" slug)"; wj_valid_slug "$s" || s=""
    r="$(wj_marker_field "$dir" root)"; wj_valid_root_value "$r" || r=""
    l="$(merge_loads "" "$(wj_marker_field "$dir" loads)")"
    for kv in "$@"; do
      case "$kv" in
        slug=*)
          s="${kv#slug=}"
          [ -z "$s" ] || wj_valid_slug "$s" || { echo "invalid slug: $s"; exit 1; }
          ;;
        root=*)
          r="${kv#root=}"
          wj_valid_root_value "$r" || { echo "invalid root value: $r"; exit 1; }
          ;;
        loads=*)
          wj_valid_slug_list "${kv#loads=}" || { echo "invalid loads list: ${kv#loads=}"; exit 1; }
          l="$(merge_loads "$l" "${kv#loads=}")" ;;   # link = add a connection → union
        *) echo "unknown field: $kv (want slug=, root=, or loads=)"; exit 1 ;;
      esac
    done
    write_marker "$dir" "$s" "$r" "$l" || { echo "could not write $dir/.work-journal"; exit 1; }
    if [ -s "$dir/.work-journal" ]; then echo "wrote $dir/.work-journal:"; sed 's/^/  /' "$dir/.work-journal"
    else echo "marked $dir (empty marker — node named '$(basename "$dir")')"; fi
    ;;

  unlink)
    dir="${1:-}"; rm_slug="${2:-}"
    [ -n "$dir" ] || { echo "usage: unlink <dir> [slug]"; exit 1; }
    [ -z "$rm_slug" ] || wj_valid_slug "$rm_slug" || { echo "invalid slug: $rm_slug"; exit 1; }
    f="$dir/.work-journal"
    [ -f "$f" ] || { echo "no marker at $dir"; exit 0; }
    if [ -z "$rm_slug" ]; then
      rm -f "$f"; echo "removed marker $f"
    else
      s="$(wj_marker_field "$dir" slug)"; wj_valid_slug "$s" || s=""
      r="$(wj_marker_field "$dir" root)"; wj_valid_root_value "$r" || r=""
      new=""; for tok in $(wj_marker_field "$dir" loads | tr ',' ' '); do
        [ "$tok" = "$rm_slug" ] && continue; new="$(merge_loads "$new" "$tok")"; done
      write_marker "$dir" "$s" "$r" "$new" || { echo "could not write $f"; exit 1; }
      echo "removed '$rm_slug' from loads in $f"
    fi
    ;;

  chain)
    dir="${1:-$PWD}"
    root="$(wj_repo_root "$dir")"
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
