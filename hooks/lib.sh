#!/usr/bin/env bash
# Shared helpers for the work-journal hooks and CLI. Sourced by recall.sh,
# capture.sh and journal.sh so they all agree on slug resolution and the router.

# Resolve $1 to the project's *main* worktree root. Git worktrees — including the
# ephemeral ones Claude Code/paseo spin up per task — each report their own
# `--show-toplevel` and a different basename, which would mint a fresh slug per
# worktree and scatter (then orphan) entries when the worktree is removed. `git
# worktree list` always prints the main worktree first, so any linked worktree
# maps back to the one shared identity. Falls back to the plain toplevel, then to
# $1 itself, for non-worktree / non-git directories.
wj_repo_root() {
  local start="$1" main
  main="$(git -C "$start" worktree list --porcelain 2>/dev/null \
            | awk '/^worktree /{print substr($0,10); exit}')"
  [ -n "$main" ] && { printf '%s' "$main"; return 0; }
  git -C "$start" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$start"
}

# Stable identity of the repo rooted at $1: its git remote, else its abs path.
# Pass a main-worktree root (see wj_repo_root) so linked worktrees of a remoteless
# repo don't each resolve to a distinct path-based id.
wj_source_id() {
  local root="$1" url
  url="$(git -C "$root" config --get remote.origin.url 2>/dev/null || true)"
  [ -n "$url" ] && printf '%s' "$url" || printf '%s' "$root"
}

# A .work-journal marker turns a plain directory into a journal node and can
# declare a few optional `key: value` lines (slug, loads, root). Read one field
# from $1/.work-journal; empty if absent. Trailing `# comment` and surrounding
# whitespace are stripped.
wj_marker_field() {
  local f="$1/.work-journal" key="$2" line val
  [ -f "$f" ] || return 0
  line="$(grep -m1 -E "^[[:space:]]*$key[[:space:]]*:" "$f" 2>/dev/null)" || return 0
  val="${line#*:}"; val="${val%%#*}"
  val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "$val"
}

# Print only real entry lines (`- [YYYY-MM-DD slug](file) — hook`) from $1,
# dropping the `- [archive]` row and any other `- [` lines. Centralized so
# trim/mv/ls/recall/router all agree on what counts as an entry: the link text
# always starts with the 4-digit date written by capture.sh as `date +%F`.
wj_entry_lines() {
  grep -E '^- \[[0-9]{4}-' "$1" 2>/dev/null || true
}

# Echo the journal slug for repo root $1 under journal dir $2. Read-only; never
# creates anything. Pretty name by default; suffixes -2/-3… only on a real
# collision (a *different* repo that already owns the base name).
wj_resolve_slug() {
  local root="$1" mem="$2"
  local base id d i s
  # A marker's explicit `slug:` wins outright — the user owns that name, so no
  # collision suffix and no .source dance.
  s="$(wj_marker_field "$root" slug)"
  [ -n "$s" ] && { printf '%s' "$s"; return 0; }
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

# Order-preserving union of the tokens in args $3.. against the seen-set value
# in $1. Prints each newly-seen token — prefixed with `$2\t` when $2 is non-empty
# (so callers can tag them), bare otherwise — and threads the updated set out via
# $_WJ_SEEN. Shared dedup core: _wj_loads passes a tag and relies on the
# out-param; merge_loads passes an empty tag and joins the printed tokens.
wj_union_loads() {
  _WJ_SEEN="$1"; local tag="$2" tok
  for tok in "${@:3}"; do
    [ -n "$tok" ] || continue
    case "$_WJ_SEEN" in *"|$tok|"*) continue ;; esac
    if [ -n "$tag" ]; then printf '%s\t%s\n' "$tag" "$tok"; else printf '%s\n' "$tok"; fi
    _WJ_SEEN="$_WJ_SEEN$tok|"
  done
}

# Emit `<tag>\t<slug>` for each `loads:` entry of the marker in $1, skipping
# slugs already in the seen-set $4. Threads the updated set out via $_WJ_SEEN
# (bash can't return a string and print lines at once).
_wj_loads() {
  local dir="$1" tag="$3" loads
  loads="$(wj_marker_field "$dir" loads)"
  [ -n "$loads" ] || { _WJ_SEEN="$4"; return 0; }
  # shellcheck disable=SC2086 # intentional word-splitting of the loads list
  wj_union_loads "$4" "$tag" ${loads//,/ }
}

# Union two comma/space lists into a "a, b, c" string, order-preserving, deduped.
# Thin wrapper over wj_union_loads (bare tokens, then re-joined with commas).
merge_loads() {
  local tok out=""
  # shellcheck disable=SC2086 # intentional word-splitting of both lists
  while IFS= read -r tok; do
    out="${out:+$out, }$tok"
  done < <(wj_union_loads "|" "" ${1//,/ } ${2//,/ })
  printf '%s' "$out"
}

# Ordered, deduped set of journal slugs to load for a session rooted at $1,
# under journal dir $2. Prints `<tag>\t<slug>` lines: self, then ancestors
# (walking up, nearest first, stopping at a `root: true` marker or /), then
# one-hop `loads:` from each marker. Lateral loads are NOT followed transitively.
wj_recall_chain() {
  local root="$1" mem="$2"
  local seen self d slug stop
  self="$(wj_resolve_slug "$root" "$mem")"
  printf 'self\t%s\n' "$self"
  seen="|$self|"
  _wj_loads "$root" "$mem" link "$seen"; seen="$_WJ_SEEN"
  d="$(dirname "$root")"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/.work-journal" ]; then
      slug="$(wj_resolve_slug "$d" "$mem")"
      case "$seen" in
        *"|$slug|"*) ;;
        *) printf 'parent\t%s\n' "$slug"; seen="$seen$slug|" ;;
      esac
      _wj_loads "$d" "$mem" link "$seen"; seen="$_WJ_SEEN"
      stop="$(wj_marker_field "$d" root)"
      case "$stop" in true|yes|1) break ;; esac
    fi
    d="$(dirname "$d")"
  done
}

# Summarize: read a prompt on stdin, print the model's reply on stdout. Uses the
# Claude CLI by default ($CLAUDE_BIN, $WORK_JOURNAL_MODEL). Set
# WORK_JOURNAL_SUMMARIZER to a stdin-reading command to use Codex or any other
# model (e.g. `codex exec`) on a box without `claude`. WORK_JOURNAL_LOCK stops
# the nested call from re-firing our own hooks.
wj_summarize() {
  local claude="${CLAUDE_BIN:-claude}" model="${WORK_JOURNAL_MODEL:-haiku}"
  if [ -n "${WORK_JOURNAL_SUMMARIZER:-}" ]; then
    WORK_JOURNAL_LOCK=1 bash -c "$WORK_JOURNAL_SUMMARIZER"
  elif command -v "$claude" >/dev/null 2>&1; then
    WORK_JOURNAL_LOCK=1 "$claude" -p --model "$model"
  else
    # ponytail: best-effort Codex fallback when claude is absent — lets the Codex
    # plugin work with no config. If your build's `codex exec` doesn't read the
    # prompt on stdin, set WORK_JOURNAL_SUMMARIZER. Failure is logged, never fatal.
    WORK_JOURNAL_LOCK=1 codex exec
  fi
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
      n="$(wj_entry_lines "$p" | grep -c '' 2>/dev/null || true)"; n="${n:-0}"
      printf -- '- %s (%s entries) — %s/INDEX.md\n' "$d" "$n" "$d"
    done
  } > "$mem/ROUTER.md"
}
