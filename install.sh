#!/usr/bin/env bash
set -euo pipefail

# Use git rev-parse so the form ("C:/..." vs "/c/...") matches what the
# /install skill passes when invoking this script. Fall back to pwd outside a
# git repo (rare; install.sh always lives inside the skadi clone).
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && (git rev-parse --show-toplevel 2>/dev/null || pwd))"
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

# Render settings.json with {{SKADI_ROOT}} substituted to this machine's repo root.
# Source-of-truth uses the placeholder so the file stays portable across machines;
# the rendered live copy carries the per-machine absolute path that the harness needs.
install_settings() {
  local src="$1"
  local dst="$2"

  [ -L "$dst" ] && rm "$dst"

  local rendered
  rendered=$(sed "s|{{SKADI_ROOT}}|$REPO|g" "$src")

  if [ -e "$dst" ] && [ "$(cat "$dst")" = "$rendered" ]; then
    echo "up to date:     $dst"
    return
  fi

  printf '%s' "$rendered" > "$dst"
  echo "installed:      $dst"
}

# Global CLAUDE.md
install_file "$REPO/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"

# Global settings (with {{SKADI_ROOT}} substitution)
install_settings "$REPO/settings.json" "$CLAUDE_DIR/settings.json"

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
    # Mirror every file under the skill directory, preserving structure.
    while IFS= read -r -d '' src; do
      rel="${src#$skill/}"
      dst="$CLAUDE_DIR/skills/$skill_name/$rel"
      mkdir -p "$(dirname "$dst")"
      install_file "$src" "$dst"
    done < <(find "$skill" -type f -not -path '*/.*' -print0)
  elif [ -f "$skill" ]; then
    skill_name="$(basename "${skill%.*}")"
    mkdir -p "$CLAUDE_DIR/skills/$skill_name"
    install_file "$skill" "$CLAUDE_DIR/skills/$skill_name/SKILL.md"
  fi
done

# Docs
if [ -d "$REPO/docs" ]; then
  mkdir -p "$CLAUDE_DIR/docs"
  while IFS= read -r -d '' src; do
    rel="${src#$REPO/docs/}"
    dst="$CLAUDE_DIR/docs/$rel"
    mkdir -p "$(dirname "$dst")"
    install_file "$src" "$dst"
  done < <(find "$REPO/docs" -type f -not -path '*/.*' -print0)
fi

echo ""
echo "Done."
