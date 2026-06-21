#!/usr/bin/env bash
# Shared helpers for the work-journal hooks. Sourced by recall.sh and capture.sh
# so both ALWAYS resolve the same slug for a repo — otherwise recall would read
# one folder while capture writes another.

# Stable identity of the repo rooted at $1: its git remote, else its abs path.
wj_source_id() {
  local root="$1" url
  url="$(git -C "$root" config --get remote.origin.url 2>/dev/null || true)"
  [ -n "$url" ] && printf '%s' "$url" || printf '%s' "$root"
}

# Echo the journal slug for repo root $1 under memory dir $2. Read-only; never
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
