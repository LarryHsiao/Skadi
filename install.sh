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

# Status line script
link "$REPO/statusline.sh" "$CLAUDE_DIR/statusline.sh"

# Skills — create a directory per skill, link as SKILL.md
mkdir -p "$CLAUDE_DIR/skills"
for skill in "$REPO/skills/"*; do
  [[ "$(basename "$skill")" == ".gitkeep" ]] && continue
  if [ -d "$skill" ]; then
    skill_name="$(basename "$skill")"
    mkdir -p "$CLAUDE_DIR/skills/$skill_name"
    [ -f "$skill/SKILL.md" ] && link "$skill/SKILL.md" "$CLAUDE_DIR/skills/$skill_name/SKILL.md"
  elif [ -f "$skill" ]; then
    skill_name="$(basename "${skill%.*}")"
    mkdir -p "$CLAUDE_DIR/skills/$skill_name"
    link "$skill" "$CLAUDE_DIR/skills/$skill_name/SKILL.md"
  fi
done

echo ""
echo "Done."
