#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${1:-$HOME/.claude}"

install_file() {
  local src="$1"
  local dst="$2"

  # Remove stale symlink if present
  [ -L "$dst" ] && rm "$dst"

  if [ -e "$dst" ] && diff -q "$src" "$dst" &>/dev/null; then
    echo "up to date:     $dst"
    return
  fi

  cp "$src" "$dst"
  echo "installed:      $dst"
}

# Check for rtk
if ! command -v rtk &>/dev/null; then
  printf '\033[33mwarning: '"'"'rtk'"'"' not found. Install it from https://github.com/rtk-ai/rtk\033[0m\n'
fi

# Global CLAUDE.md
install_file "$REPO/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"

# Global settings
install_file "$REPO/settings.json" "$CLAUDE_DIR/settings.json"

# Status line script
install_file "$REPO/statusline.sh" "$CLAUDE_DIR/statusline.sh"

# Hooks
mkdir -p "$CLAUDE_DIR/hooks"
for hook in "$REPO/hooks/"*.sh; do
  [ -f "$hook" ] && install_file "$hook" "$CLAUDE_DIR/hooks/$(basename "$hook")"
done

# Skills
mkdir -p "$CLAUDE_DIR/skills"
for skill in "$REPO/skills/"*; do
  [[ "$(basename "$skill")" == ".gitkeep" ]] && continue
  if [ -d "$skill" ]; then
    skill_name="$(basename "$skill")"
    mkdir -p "$CLAUDE_DIR/skills/$skill_name"
    [ -f "$skill/SKILL.md" ] && install_file "$skill/SKILL.md" "$CLAUDE_DIR/skills/$skill_name/SKILL.md"
  elif [ -f "$skill" ]; then
    skill_name="$(basename "${skill%.*}")"
    mkdir -p "$CLAUDE_DIR/skills/$skill_name"
    install_file "$skill" "$CLAUDE_DIR/skills/$skill_name/SKILL.md"
  fi
done

echo ""
echo "Done."
