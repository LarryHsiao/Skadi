#!/usr/bin/env bash
# eod-git-check.sh — scan one or more git repos for uncommitted/unpushed work.
# Usage: eod-git-check.sh <dir> [<dir> ...]
# Output (one line per dir): DIR|STATE|DIRTY|UNTRACKED|AHEAD|BRANCH|REMOTE
#   STATE: ok | dirty | unpushed | both | no-git | no-remote | error
#   DIRTY: count of modified/staged files
#   UNTRACKED: count of untracked files
#   AHEAD: count of commits ahead of upstream (0 if no upstream)

set -u

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <dir> [<dir> ...]" >&2
  exit 2
fi

for raw in "$@"; do
  dir="${raw/#\~/$HOME}"

  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo "$raw|no-git|0|0|0|-|-"
    continue
  fi

  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch="-"

  porcelain=$(git -C "$dir" status --porcelain 2>/dev/null) || {
    echo "$raw|error|0|0|0|$branch|-"
    continue
  }

  dirty=$(printf '%s\n' "$porcelain" | grep -cE '^[^?]' || true)
  untracked=$(printf '%s\n' "$porcelain" | grep -cE '^\?\?' || true)
  [[ -z "$porcelain" ]] && { dirty=0; untracked=0; }

  upstream=$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || upstream=""

  if [[ -z "$upstream" ]]; then
    ahead=0
    remote_state="no-remote"
  else
    ahead=$(git -C "$dir" rev-list --count "$upstream"..HEAD 2>/dev/null) || ahead=0
    remote_state="$upstream"
  fi

  if (( dirty + untracked > 0 )) && (( ahead > 0 )); then
    state="both"
  elif (( dirty + untracked > 0 )); then
    state="dirty"
  elif (( ahead > 0 )); then
    state="unpushed"
  elif [[ "$remote_state" == "no-remote" ]]; then
    state="no-remote"
  else
    state="ok"
  fi

  echo "$raw|$state|$dirty|$untracked|$ahead|$branch|$remote_state"
done
