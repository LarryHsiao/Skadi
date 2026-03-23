#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

link() {
  local src="$1"
  local dst="$2"

  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    echo "already linked: $dst"
    return
  fi

  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    local backup="${dst}.bak.$(date +%Y%m%d%H%M%S)"
    echo "backing up:     $dst -> $backup"
    mv "$dst" "$backup"
  fi

  ln -sf "$src" "$dst"
  echo "linked:         $dst -> $src"
}

# Global CLAUDE.md
link "$REPO/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"

# Global settings
link "$REPO/settings.json" "$CLAUDE_DIR/settings.json"

# Skills — link each file individually
mkdir -p "$CLAUDE_DIR/skills"
for skill in "$REPO/skills/"*; do
  [[ "$(basename "$skill")" == ".gitkeep" ]] && continue
  [ -f "$skill" ] && link "$skill" "$CLAUDE_DIR/skills/$(basename "$skill")"
done

echo ""
echo "Done."
