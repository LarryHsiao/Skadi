#!/usr/bin/env bash
# pengolodh.sh — a verified per-repo mechanism cache.
#
# Records file:line-anchored facts about a repo that grep cannot answer on its
# own — entry points, live-vs-dead modules, seams, invariants, conventions in
# force. Every entry carries a literal anchor (`<!-- a:LITERAL c:high|low -->`)
# beside its `` `file:line` `` span, so `verify` (backed by pengolodh.py) can
# check it mechanically: repaired in place when the anchored code merely
# moved, reported STALE when the literal is gone, MISSING when the file
# itself is gone. `gc` deletes confirmed-dead (STALE/MISSING) entries for
# good; `inject` only withholds them for one session, leaving the file
# untouched. See docs/workflow/mechanism-cache.md for the entry format and
# the recording rule.
#
# Storage: ~/.skadi/mechanisms/<repo-key>/index.md, one file per repo. Git is
# optional — status offers `git init` when absent, and pull/push only run
# when ~/.skadi/mechanisms/.autosync exists (offered alongside git init).
# Nothing here ever runs `git init` itself, and sync is `--ff-only` — it
# stops rather than auto-merges on divergence. When git is present, verify/
# inject/gc each commit whatever they find dirty in that one repo's index —
# local only, unconditional, no .autosync needed; that switch gates only the
# network half (pull/push).
#
# Test seams: PENGOLODH_DIR overrides the cache root; PENGOLODH_INJECT_BUDGET
# (read by pengolodh.py) overrides the inject size cap.
set -euo pipefail

PENGOLODH_DIR="${PENGOLODH_DIR:-$HOME/.skadi/mechanisms}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
  echo "pengolodh: $1" >&2
  exit 1
}

repo_root() {
  local path="${1:-$PWD}"
  git -C "$path" rev-parse --show-toplevel 2>/dev/null || (cd "$path" && pwd -P)
}

# Deliberately duplicates hooks/skadi-state.sh's project_key idiom (same
# hash fallback chain, same sanitization) rather than sourcing it —
# skadi-state.sh is a dispatched script, not a library, and this is only
# the second such site. A third hashing site should lift both into a
# shared helper per docs/style/universal.md's "third recurrence" rule.
repo_key() {
  local root="$1"
  local name digest
  name="$(printf '%s' "$(basename "$root")" | tr -cs 'A-Za-z0-9._-' '_')"
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s' "$root" | sha256sum | cut -c1-12)"
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s' "$root" | shasum -a 256 | cut -c1-12)"
  else
    digest="$(printf '%s' "$root" | md5sum | cut -c1-12)"
  fi
  printf '%s-%s\n' "$name" "$digest"
}

index_path() {
  local root key dir
  root="$(repo_root "$1")"
  key="$(repo_key "$root")"
  dir="$PENGOLODH_DIR/$key"
  mkdir -p "$dir"
  printf '%s/index.md\n' "$dir"
}

# Prints one of: absent | unsynced | diverged | behind N | synced
git_posture() {
  if [[ ! -d "$PENGOLODH_DIR/.git" ]]; then
    echo "absent"
    return
  fi
  if [[ ! -f "$PENGOLODH_DIR/.autosync" ]]; then
    echo "unsynced"
    return
  fi
  local counts ahead behind
  counts="$(git -C "$PENGOLODH_DIR" rev-list --left-right --count 'HEAD...@{u}' 2>/dev/null || echo "0 0")"
  ahead="$(awk '{print $1}' <<<"$counts")"
  behind="$(awk '{print $2}' <<<"$counts")"
  if [[ "${ahead:-0}" -gt 0 && "${behind:-0}" -gt 0 ]]; then
    echo "diverged"
  elif [[ "${behind:-0}" -gt 0 ]]; then
    echo "behind $behind"
  else
    echo "synced"
  fi
}

cmd_path() {
  index_path "${1:-$PWD}"
}

cmd_status() {
  local root idx entries posture
  root="$(repo_root "${1:-$PWD}")"
  idx="$(index_path "$root")"
  entries=0
  [[ -s "$idx" ]] && entries="$(grep -c '<!-- a:' "$idx" || true)"

  echo "index: $idx"
  echo "entries: $entries"

  posture="$(git_posture)"
  case "$posture" in
    absent)
      echo "git: not initialized — optional; enables cross-machine sync"
      echo "  run: git -C \"$PENGOLODH_DIR\" init"
      ;;
    unsynced)
      echo "git: initialized, sync off — a commit-only local history"
      echo "  enable pull/push with: touch \"$PENGOLODH_DIR/.autosync\""
      ;;
    diverged)
      echo "git: diverged from upstream — sync stopped, resolve by hand in $PENGOLODH_DIR"
      ;;
    behind*)
      echo "git: $posture — will catch up on next sync"
      ;;
    synced)
      echo "git: synced"
      ;;
  esac
}

# Commits whatever is sitting dirty in one repo's index — a line verify just
# repaired, entries gc just deleted, or an entry a session appended by hand
# before ever calling a pengolodh.sh verb. Scoped to that one index path, not
# the whole cache tree, so one repo's commit never sweeps in another
# session's concurrent, unrelated, mid-write changes to a different repo's
# index. Local only — never touches the network; that is sync's job, and
# only once .autosync exists. A no-op whenever git is absent.
commit_if_dirty() {
  local idx="$1" rel
  [[ -d "$PENGOLODH_DIR/.git" ]] || return 0
  rel="${idx#"$PENGOLODH_DIR"/}"
  git -C "$PENGOLODH_DIR" diff --quiet -- "$rel" 2>/dev/null \
    && [[ -z "$(git -C "$PENGOLODH_DIR" ls-files --others --exclude-standard -- "$rel" 2>/dev/null)" ]] \
    && return 0
  git -C "$PENGOLODH_DIR" add -- "$rel" 2>/dev/null
  git -C "$PENGOLODH_DIR" commit -q -m "pengolodh: update $rel" >/dev/null 2>&1 || true
}

cmd_verify() {
  local root idx
  root="$(repo_root "${1:-$PWD}")"
  idx="$(index_path "$root")"
  python3 "$SCRIPT_DIR/pengolodh.py" verify "$idx" "$root"
  commit_if_dirty "$idx"
}

cmd_inject() {
  local root idx
  root="$(repo_root "${1:-$PWD}")"
  idx="$(index_path "$root")"
  [[ -s "$idx" ]] || exit 0
  python3 "$SCRIPT_DIR/pengolodh.py" inject "$idx" "$root"
  commit_if_dirty "$idx"
}

# Permanently deletes entries verify confirms STALE or MISSING. Leaves
# c:low entries that still verify OK alone — gc removes what is confirmed
# dead, never what is merely uncertain.
cmd_gc() {
  local root idx
  root="$(repo_root "${1:-$PWD}")"
  idx="$(index_path "$root")"
  [[ -s "$idx" ]] || { echo "removed 0 stale/missing entries"; return; }
  python3 "$SCRIPT_DIR/pengolodh.py" gc "$idx" "$root"
  commit_if_dirty "$idx"
}

# Pull-then-push, --ff-only. Syncs the whole mechanisms cache (every repo's
# index lives in one small git repo), so it takes no <repo-root> — unlike
# every other verb here. A no-op whenever git is absent or .autosync is not
# set, so it is safe to invoke unconditionally and detached from
# pengolodh-inject.sh. Never auto-merges: on divergence it stops and leaves
# the local copy untouched, surfaced later by `status`, not by this call's
# exit code — nothing reads a detached call's exit code.
cmd_sync() {
  [[ -d "$PENGOLODH_DIR/.git" ]] || exit 0
  [[ -f "$PENGOLODH_DIR/.autosync" ]] || exit 0
  git -C "$PENGOLODH_DIR" fetch --quiet origin 2>/dev/null || exit 0
  git -C "$PENGOLODH_DIR" merge --ff-only --quiet '@{u}' 2>/dev/null || exit 0
  git -C "$PENGOLODH_DIR" push --quiet 2>/dev/null || true
}

verb="${1:-}"
[[ $# -gt 0 ]] && shift

case "$verb" in
  path) cmd_path "$@" ;;
  status) cmd_status "$@" ;;
  verify) cmd_verify "$@" ;;
  inject) cmd_inject "$@" ;;
  gc) cmd_gc "$@" ;;
  sync) cmd_sync ;;
  *) die "expected path|status|verify|inject|gc <repo-root>, or sync" ;;
esac
