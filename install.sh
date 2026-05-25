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
    # Content matches; ensure the executable bit matches too.
    # cp without -p drops mode, so older installs of hook scripts ended up
    # non-executable in dst even when source was +x.
    if [ -x "$src" ] && [ ! -x "$dst" ]; then
      chmod +x "$dst"
      echo "chmod +x:       $dst"
    elif [ ! -x "$src" ] && [ -x "$dst" ]; then
      chmod -x "$dst"
      echo "chmod -x:       $dst"
    else
      echo "up to date:     $dst"
    fi
    return
  fi

  cp -p "$src" "$dst"
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

  # RTK is not wired on Windows. Its PreToolUse entry is a self-contained
  # line, so dropping it here leaves valid JSON. Strip before the comparison
  # so re-runs on Windows stay idempotent.
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) rendered=$(printf '%s' "$rendered" | sed '/rtk hook claude/d') ;;
  esac

  if [ -e "$dst" ] && [ "$(cat "$dst")" = "$rendered" ]; then
    echo "up to date:     $dst"
    return
  fi

  printf '%s' "$rendered" > "$dst"
  echo "installed:      $dst"
}

# Remove files in dst that have no counterpart in src, then sweep empty dirs.
# Hidden files and directories under dst are left alone — those belong to the
# user, not to skadi.
prune_tree() {
  local src="$1"
  local dst="$2"
  [ -d "$dst" ] || return 0

  while IFS= read -r -d '' path; do
    local rel="${path#$dst/}"
    if [ ! -e "$src/$rel" ]; then
      rm -f "$path"
      echo "pruned:         $path"
    fi
  done < <(find "$dst" -name '.*' -prune -o -type f -print0)

  find "$dst" -depth -mindepth 1 -type d -empty -not -name '.*' -delete 2>/dev/null || true
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
prune_tree "$REPO/hooks" "$CLAUDE_DIR/hooks"

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
    done < <(find "$skill" -name '.*' -prune -o -type f -print0)
  elif [ -f "$skill" ]; then
    skill_name="$(basename "${skill%.*}")"
    mkdir -p "$CLAUDE_DIR/skills/$skill_name"
    install_file "$skill" "$CLAUDE_DIR/skills/$skill_name/SKILL.md"
  fi
done
prune_tree "$REPO/skills" "$CLAUDE_DIR/skills"

# Docs
if [ -d "$REPO/docs" ]; then
  mkdir -p "$CLAUDE_DIR/docs"
  while IFS= read -r -d '' src; do
    rel="${src#$REPO/docs/}"
    dst="$CLAUDE_DIR/docs/$rel"
    mkdir -p "$(dirname "$dst")"
    install_file "$src" "$dst"
  done < <(find "$REPO/docs" -name '.*' -prune -o -type f -print0)
  prune_tree "$REPO/docs" "$CLAUDE_DIR/docs"
fi

echo ""
echo "Done."
