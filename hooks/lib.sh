#!/usr/bin/env bash
# Shared helpers for the work-journal hooks and CLI. Sourced by recall.sh,
# capture.sh and journal.sh so they all agree on slug resolution and the router.

# Stable identity of the repo rooted at $1: its git remote, else its abs path.
wj_source_id() {
  local root="$1" url
  url="$(git -C "$root" config --get remote.origin.url 2>/dev/null || true)"
  [ -n "$url" ] && printf '%s' "$url" || printf '%s' "$root"
}

# Echo the journal slug for repo root $1 under journal dir $2. Read-only; never
# creates anything. Pretty name by default; suffixes -2/-3… only on a real
# collision (a *different* repo that already owns the base name).
wj_resolve_slug() {
  local root="$1" mem="$2"
  local base id d i
  base="$(basename "$root")"
  id="$(wj_source_id "$root")"
  # 1) reuse a folder that already records this exact id
  for d in "$mem/$base" "$mem/$base"-*; do
    [ -d "$d" ] || continue
    [ -f "$d/.source" ] || continue
    [ "$(cat "$d/.source" 2>/dev/null)" = "$id" ] && { basename "$d"; return 0; }
  done
  # 2) adopt a legacy base folder (created before .source existed)
  [ -d "$mem/$base" ] && [ ! -f "$mem/$base/.source" ] && { printf '%s' "$base"; return 0; }
  # 3) base name is free
  [ -d "$mem/$base" ] || { printf '%s' "$base"; return 0; }
  # 4) base taken by another repo → first free suffix
  i=2
  while [ -d "$mem/$base-$i" ]; do i=$((i+1)); done
  printf '%s' "$base-$i"
}

# Rebuild the top-level ROUTER.md from disk under journal dir $1 — always
# consistent, no incremental diff logic.
wj_rebuild_router() {
  local mem="$1" p d n
  [ -d "$mem" ] || return 0
  { printf '# Work journal — projects\n\n'
    for p in "$mem"/*/INDEX.md; do
      [ -e "$p" ] || continue
      d="$(basename "$(dirname "$p")")"
      n="$(grep -c '^- ' "$p" 2>/dev/null || true)"; n="${n:-0}"
      printf -- '- %s (%s entries) — %s/INDEX.md\n' "$d" "$n" "$d"
    done
  } > "$mem/ROUTER.md"
}
