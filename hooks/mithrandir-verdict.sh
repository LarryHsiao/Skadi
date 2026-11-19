#!/usr/bin/env bash
# Usage: mithrandir-verdict.sh save <repo-path>   (the `To pass` list on stdin)
#        mithrandir-verdict.sh read <repo-path>
#
# Keeps the `To pass` list of a branch-path /mithrandir verdict, so /narvi's
# step 9c has something to compare reviewer comments against when no verdict
# was posted on the forge.
#
# The file is keyed by profile, origin remote, and branch — not by checkout
# path — because /narvi reads it from a worktree or temp clone of the repo.
# Line 1 is `sha: <HEAD at save time>`; the list follows.
#
# save: prints the file path. With no origin remote, or on a detached HEAD, it
#       saves nothing, prints `skipped (<reason>)`, and exits 0 — a review must
#       not fail on it.
# read: prints the file. No saved verdict (or no origin, or a detached HEAD):
#       prints nothing, exits 0. Saved sha no longer an ancestor of HEAD (the
#       branch was rewritten): prints `stale: ...` on stderr, exits 3. First
#       line not a sha: prints `unreadable saved verdict` on stderr, exits 1.
#
# Branch names are slugged, so `feature/a` and `feature_a` share one file; the
# ancestor check on read keeps one from being served the other's verdict.
#
# Platforms: macOS (/bin/bash 3.2), Linux, Windows Git Bash.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STALE_EXIT=3
DETACHED=HEAD

die() {
  echo "mithrandir-verdict: $1" >&2
  exit 1
}

slug() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_'
}

# git@host:Owner/Repo.git, https://host/owner/repo/ and
# ssh://git@host:2222/owner/repo.git name one remote.
remote_key() {
  local url
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  url="${url%/}"
  url="${url%.git}"
  case "$url" in
    *://*)
      url="${url#*://}"
      url="${url#*@}"
      url="$(printf '%s' "$url" | sed -E 's#^([^/:]+):[0-9]+/#\1/#')"
      ;;
    *) url="${url#*@}" ;;
  esac
  slug "$(printf '%s' "$url" | tr 'A-Z' 'a-z')"
}

verdict_file() {
  local remote="$1" branch="$2" dir
  dir="$("$HERE/skadi-state.sh" profile-path "${SKADI_PROFILE:-default}" mithrandir-verdicts)/$remote"
  mkdir -p "$dir"
  printf '%s/%s.md\n' "$dir" "$(slug "$branch")"
}

# A sha-1 or sha-256 object name: 40 or 64 hex characters.
is_sha() {
  case "$1" in
    *[!0-9a-f]* | "") return 1 ;;
  esac
  [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]
}

skip() {
  [ "$verb" = save ] && echo "skipped ($1)"
  exit 0
}

verb="${1:-}"
repo="${2:-}"
case "$verb" in
  save | read) ;;
  *) die "expected save <repo-path> or read <repo-path>" ;;
esac
[ -n "$repo" ] || die "$verb: missing repo path"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "$verb: not a git repo: $repo"

remote="$(remote_key "$repo")" || skip "no origin remote"
branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
[ "$branch" != "$DETACHED" ] || skip "detached HEAD"
file="$(verdict_file "$remote" "$branch")"

if [ "$verb" = save ]; then
  {
    printf 'sha: %s\n' "$(git -C "$repo" rev-parse HEAD)"
    cat
  } >"$file.tmp"
  mv "$file.tmp" "$file"
  printf '%s\n' "$file"
  exit 0
fi

[ -f "$file" ] || exit 0
sha="$(head -n 1 "$file")"
sha="${sha#sha: }"
is_sha "$sha" || die "unreadable saved verdict: $file"
if ! git -C "$repo" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
  echo "stale: saved sha ${sha:0:7} is not on $branch" >&2
  exit "$STALE_EXIT"
fi
cat "$file"
