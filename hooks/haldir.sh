#!/usr/bin/env bash
# Launches one native background Claude Code session per repo, each named
# for its repo, isolated into its own worktree, running in auto-mode (no TTY
# to answer interactive prompts), and subscribed to a handoff channel of the
# same name.
#
# The repo list is read from a global flat file — one absolute path per
# markdown bullet ("- /path/to/repo") — NOT auto-memory: auto-memory is
# scoped per project directory and invisible to a session rooted elsewhere.
# Same reasoning as mend_repos.md / protected_repos.md. Missing or empty
# falls back to $HOME/skadi alone.

set -euo pipefail

REPOS_LIST="$HOME/.skadi/repo-watch/repos.md"

echo "repo list source: $REPOS_LIST (edit it to add or remove repos)"

REPOS=()
while IFS= read -r line; do
  REPOS+=("$line")
done < <(grep -oE '^- (/.*)$' "$REPOS_LIST" 2>/dev/null | sed 's/^- //')

if [ "${#REPOS[@]}" -eq 0 ]; then
  echo "not set up yet — defaulting to \$HOME/skadi only. Add more repos as bullets in the file above first."
  REPOS=("$HOME/skadi")
fi

for repo in "${REPOS[@]}"; do
  name=$(basename "$repo")
  (
    cd "$repo"
    claude "Run /handoff subscribe $name --from $name to join your channel, then run /loop with no interval so you keep watching it and act on whatever arrives." \
      --bg --name "$name" --worktree "$name" --permission-mode auto
  )
  echo "launched: $name ($repo)"
done

echo "manage with: claude agents"
