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

# Single filesystem component, safe to append under $WORK_JOURNAL_DIR. This is
# intentionally looser than explicit `slug:` validation so legacy journal folders
# with spaces remain readable, but traversal and control characters are rejected.
wj_valid_path_component() {
  local s="${1:-}"
  [ -n "$s" ] || return 1
  case "$s" in */*|.|..) return 1 ;; esac
  case "$s" in *[[:cntrl:]]*) return 1 ;; esac
  return 0
}

# User-authored slugs and `loads:` tokens are stricter: portable, shell-friendly,
# and bounded so they stay usable in slash commands and markdown links.
wj_valid_slug() {
  local s="${1:-}"
  wj_valid_path_component "$s" || return 1
  [[ "$s" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]]
}

wj_valid_project() {
  wj_valid_path_component "${1:-}"
}

wj_valid_slug_list() {
  local tok list="${1:-}"
  [ -n "$list" ] || return 0
  # shellcheck disable=SC2086 # intentional splitting of comma/space slug lists
  for tok in ${list//,/ }; do
    wj_valid_slug "$tok" || return 1
  done
}

wj_valid_root_value() {
  case "${1:-}" in ""|true|yes|1|false|no|0) return 0 ;; *) return 1 ;; esac
}

wj_slugify_component() {
  local s
  s="$(printf '%s' "${1:-project}" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cs 'a-z0-9._-' '-' | sed 's/^[^a-z0-9]*//; s/[^a-z0-9]*$//')"
  [ -n "$s" ] || s="project"
  printf '%s' "${s:0:80}"
}

wj_valid_entry_file() {
  local f="${1:-}"
  wj_valid_path_component "$f" || return 1
  [[ "$f" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[A-Za-z0-9._-]+\.md$ ]]
}

wj_entry_file_from_line() {
  local line="${1:-}" f
  f="${line#*](}"; f="${f%%)*}"
  [ "$f" != "$line" ] || return 1
  wj_valid_entry_file "$f" || return 1
  printf '%s' "$f"
}

wj_valid_keep() {
  local n="${1:-}"
  case "$n" in ""|*[!0-9]*) return 1 ;; esac
  [ "${#n}" -le 6 ]
}

wj_valid_cap() {
  local n="${1:-}"
  case "$n" in ""|*[!0-9]*) return 1 ;; esac
  [ "${#n}" -le 9 ] && [ "$n" -gt 0 ]
}

wj_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date 2>/dev/null || printf 'unknown-time'
}

wj_meta_value() {
  local s
  s="$(printf '%s' "${1:-}" | LC_ALL=C tr '\r\n\t' '   ' | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177')"
  printf '%s' "${s:0:240}"
}

wj_file_fingerprint() {
  [ -f "$1" ] || return 1
  cksum "$1" 2>/dev/null | awk '{print $1 ":" $2}'
}

wj_entry_has_meta() {
  local file="$1" key="$2" value="$3"
  [ -f "$file" ] || return 1
  awk -v want="$key: $value" '
    BEGIN { found = 0; inside = 0 }
    NR == 1 {
      if ($0 == "---") { inside = 1; next }
      exit
    }
    inside && $0 == "---" { exit }
    inside && $0 == want { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

wj_find_entry_by_meta() {
  local dir="$1" key="$2" value="$3" f bn
  [ -d "$dir" ] && [ -n "$value" ] || return 1
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    bn="$(basename "$f")"
    wj_valid_entry_file "$bn" || continue
    if wj_entry_has_meta "$f" "$key" "$value"; then
      printf '%s' "$bn"
      return 0
    fi
  done
  return 1
}

wj_capture_seen() {
  local dir="$1" key="$2"
  [ -d "$dir" ] && [ -n "$key" ] || return 1
  if [ -f "$dir/.captures" ] && grep -Fxq "$key" "$dir/.captures" 2>/dev/null; then
    return 0
  fi
  wj_find_entry_by_meta "$dir" capture "$key" >/dev/null
}

wj_capture_mark_locked() {
  local dir="$1" key="$2" tmp
  [ -d "$dir" ] && [ -n "$key" ] || return 1
  if [ -f "$dir/.captures" ] && grep -Fxq "$key" "$dir/.captures" 2>/dev/null; then
    return 0
  fi
  tmp="$(wj_tmp_for "$dir/.captures")" || return 1
  { [ -f "$dir/.captures" ] && cat "$dir/.captures"; printf '%s\n' "$key"; } > "$tmp" && mv -f "$tmp" "$dir/.captures" || {
    rm -f "$tmp"
    return 1
  }
}

wj_session_entry_file() {
  local dir="$1" sid="$2" f
  [ -d "$dir" ] && [ -n "$sid" ] || return 1
  if [ -f "$dir/.sessions" ]; then
    f="$(awk -F '\t' -v s="$sid" '$1 == s { print $2; exit }' "$dir/.sessions" 2>/dev/null || true)"
    if wj_valid_entry_file "$f" && [ -f "$dir/$f" ]; then
      printf '%s' "$f"
      return 0
    fi
  fi
  wj_find_entry_by_meta "$dir" session "$sid"
}

wj_session_record_locked() {
  local dir="$1" sid="$2" file="$3" tmp
  [ -d "$dir" ] && [ -n "$sid" ] && wj_valid_entry_file "$file" || return 1
  tmp="$(wj_tmp_for "$dir/.sessions")" || return 1
  { [ -f "$dir/.sessions" ] && awk -F '\t' -v s="$sid" '$1 != s' "$dir/.sessions"; printf '%s\t%s\n' "$sid" "$file"; } > "$tmp" && mv -f "$tmp" "$dir/.sessions" || {
    rm -f "$tmp"
    return 1
  }
}

wj_tmp_for() {
  local target="$1" dir base
  dir="$(dirname "$target")"; base="$(basename "$target")"
  mktemp "$dir/.$base.tmp.XXXXXX"
}

# Run a command while holding the journal lock. Prefer flock when available; use
# a mkdir lock directory otherwise so macOS and minimal systems keep serializing
# writes instead of silently racing. Hooks still fail soft if the lock is stuck.
wj_with_lock() {
  local mem="$1" tries="${WORK_JOURNAL_LOCK_TRIES:-100}" delay="${WORK_JOURNAL_LOCK_DELAY:-0.1}"
  shift
  mkdir -p "$mem" 2>/dev/null || return 1
  if command -v flock >/dev/null 2>&1; then
    (
      local i=0
      while ! flock -n 9 2>/dev/null; do
        i=$((i+1)); [ "$i" -ge "$tries" ] && exit 1
        sleep "$delay"
      done
      "$@"
    ) 9>"$mem/.lock"
  else
    (
      local lockdir="$mem/.lock.d" i=0
      while ! mkdir "$lockdir" 2>/dev/null; do
        i=$((i+1)); [ "$i" -ge "$tries" ] && exit 1
        sleep "$delay"
      done
      trap 'rmdir "$lockdir" 2>/dev/null || true' EXIT HUP INT TERM
      "$@"
    )
  fi
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
  local base id d i s src
  # A marker's explicit `slug:` wins outright — the user owns that name, so no
  # collision suffix and no .source dance.
  s="$(wj_marker_field "$root" slug)"
  [ -n "$s" ] && wj_valid_slug "$s" && { printf '%s' "$s"; return 0; }
  id="$(wj_source_id "$root")"
  # 0) reuse any folder that already records this exact id, including legacy
  # names that predate today's slug rules.
  for src in "$mem"/*/.source; do
    [ -f "$src" ] || continue
    [ "$(cat "$src" 2>/dev/null)" = "$id" ] || continue
    d="$(basename "$(dirname "$src")")"
    wj_valid_path_component "$d" && { printf '%s' "$d"; return 0; }
  done
  base="$(basename "$root")"
  wj_valid_path_component "$base" || base="$(wj_slugify_component "$base")"
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

wj_write_source_locked() {
  local dir="$1" id="$2" tmp
  [ -f "$dir/.source" ] && return 0
  tmp="$(wj_tmp_for "$dir/.source")" || return 1
  printf '%s\n' "$id" > "$tmp" && mv -f "$tmp" "$dir/.source" || {
    rm -f "$tmp"
    return 1
  }
}

# Resolve and claim the slug for a writer. Call only from inside wj_with_lock.
wj_claim_slug_locked() {
  local root="$1" mem="$2"
  local s base id d i src
  s="$(wj_marker_field "$root" slug)"
  id="$(wj_source_id "$root")"
  if [ -n "$s" ] && wj_valid_slug "$s"; then
    mkdir -p "$mem/$s" 2>/dev/null || return 1
    wj_write_source_locked "$mem/$s" "$id" || true
    printf '%s' "$s"
    return 0
  fi
  for src in "$mem"/*/.source; do
    [ -f "$src" ] || continue
    [ "$(cat "$src" 2>/dev/null)" = "$id" ] || continue
    d="$(basename "$(dirname "$src")")"
    wj_valid_path_component "$d" && { printf '%s' "$d"; return 0; }
  done
  base="$(basename "$root")"
  wj_valid_path_component "$base" || base="$(wj_slugify_component "$base")"
  if [ -d "$mem/$base" ] && [ ! -f "$mem/$base/.source" ]; then
    wj_write_source_locked "$mem/$base" "$id" || return 1
    printf '%s' "$base"
    return 0
  fi
  s="$base"; i=2
  while :; do
    d="$mem/$s"
    if [ ! -d "$d" ]; then
      mkdir "$d" 2>/dev/null || { s="$base-$i"; i=$((i+1)); continue; }
      wj_write_source_locked "$d" "$id" || return 1
      printf '%s' "$s"
      return 0
    fi
    if [ -f "$d/.source" ] && [ "$(cat "$d/.source" 2>/dev/null)" = "$id" ]; then
      printf '%s' "$s"
      return 0
    fi
    s="$base-$i"; i=$((i+1))
  done
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
    wj_valid_slug "$tok" || continue
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
  stop="$(wj_marker_field "$root" root)"
  case "$stop" in true|yes|1) return 0 ;; esac
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

wj_summarize_run_file_cli() {
  local cli="$1" override_model="$2" model="$3" prompt rc selected_model
  prompt="$(mktemp "${TMPDIR:-/tmp}/work-journal-prompt.XXXXXX")" || return 1
  cat > "$prompt"
  selected_model="$override_model"
  [ -n "$selected_model" ] || case "$model" in */*) selected_model="$model" ;; esac
  if [ -n "$selected_model" ]; then
    WORK_JOURNAL_LOCK=1 "$cli" run --pure --model "$selected_model" --file "$prompt" "Read the attached work-journal prompt and respond exactly as instructed."
  else
    WORK_JOURNAL_LOCK=1 "$cli" run --pure --file "$prompt" "Read the attached work-journal prompt and respond exactly as instructed."
  fi
  rc=$?
  rm -f "$prompt"
  return "$rc"
}

wj_summarize_codex() {
  if [ -n "${WORK_JOURNAL_CODEX_MODEL:-}" ]; then
    WORK_JOURNAL_LOCK=1 codex exec --model "$WORK_JOURNAL_CODEX_MODEL"
  else
    WORK_JOURNAL_LOCK=1 codex exec
  fi
}

# Summarize: read a prompt on stdin, print the model's reply on stdout. Uses the
# Claude CLI by default ($CLAUDE_BIN, $WORK_JOURNAL_MODEL). Set
# WORK_JOURNAL_SUMMARIZER to a stdin-reading command to use any custom model.
# Fallbacks prefer the active Kilo/OpenCode host when known, then Codex.
# WORK_JOURNAL_LOCK stops nested calls from re-firing our own hooks.
wj_summarize() {
  local claude="${CLAUDE_BIN:-claude}" model="${WORK_JOURNAL_MODEL:-haiku}" host="${WORK_JOURNAL_HOST:-}"
  if [ -n "${WORK_JOURNAL_SUMMARIZER:-}" ]; then
    WORK_JOURNAL_LOCK=1 bash -c "$WORK_JOURNAL_SUMMARIZER"
  elif command -v "$claude" >/dev/null 2>&1; then
    WORK_JOURNAL_LOCK=1 "$claude" -p --model "$model"
  elif [ "$host" = opencode ] && command -v opencode >/dev/null 2>&1; then
    wj_summarize_run_file_cli opencode "${WORK_JOURNAL_OPENCODE_MODEL:-}" "$model"
  elif [ "$host" = kilo ] && command -v kilo >/dev/null 2>&1; then
    wj_summarize_run_file_cli kilo "${WORK_JOURNAL_KILO_MODEL:-}" "$model"
  elif command -v codex >/dev/null 2>&1; then
    # ponytail: best-effort Codex fallback when claude is absent — lets the Codex
    # plugin work with no config. If your build's `codex exec` doesn't read the
    # prompt on stdin, set WORK_JOURNAL_SUMMARIZER. Failure is logged, never fatal.
    wj_summarize_codex
  elif command -v kilo >/dev/null 2>&1; then
    wj_summarize_run_file_cli kilo "${WORK_JOURNAL_KILO_MODEL:-}" "$model"
  elif command -v opencode >/dev/null 2>&1; then
    wj_summarize_run_file_cli opencode "${WORK_JOURNAL_OPENCODE_MODEL:-}" "$model"
  else
    return 1
  fi
}

# Rebuild the top-level ROUTER.md from disk under journal dir $1 — always
# consistent, no incremental diff logic.
wj_rebuild_router() {
  local mem="$1" p d n tmp
  [ -d "$mem" ] || return 0
  tmp="$(wj_tmp_for "$mem/ROUTER.md")" || return 1
  { printf '# Work journal — projects\n\n'
    for p in "$mem"/*/INDEX.md; do
      [ -e "$p" ] || continue
      d="$(basename "$(dirname "$p")")"
      n="$(wj_entry_lines "$p" | grep -c '' 2>/dev/null || true)"; n="${n:-0}"
      printf -- '- %s (%s entries) — %s/INDEX.md\n' "$d" "$n" "$d"
    done
  } > "$tmp" && mv -f "$tmp" "$mem/ROUTER.md" || {
    rm -f "$tmp"
    return 1
  }
}
