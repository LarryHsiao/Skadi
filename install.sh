#!/usr/bin/env bash
set -euo pipefail

# The digest maps below need associative arrays (bash 4.0) and namerefs (4.3).
# macOS still ships 3.2 as /bin/bash, so say why rather than fail cryptically.
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
  echo "install.sh needs bash 4.3 or newer (found $BASH_VERSION)" >&2
  exit 1
fi

# Use git rev-parse so the form ("C:/..." vs "/c/...") matches what the
# /install skill passes when invoking this script. Fall back to pwd outside a
# git repo (rare; install.sh always lives inside the skadi clone).
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && (git rev-parse --show-toplevel 2>/dev/null || pwd))"
CLAUDE_DIR="${1:-$HOME/.claude}"

# Content digests, keyed by absolute path, for the source tree and the live one.
# Filled once per run by hash_tree; read by install_file.
declare -A SRC_MD5 DST_MD5

# Hash every file under the given paths (directories or single files) into the
# named map. One md5sum for the whole tree replaces the per-file `diff` this
# script used to fork: on Windows a process spawn costs 40-170ms, and at ~260
# files that dominated the run. md5sum prints "<32-char digest> *<path>", so the
# digest and the path sit at fixed offsets.
hash_tree() {
  local -n map="$1"
  shift
  local line
  while IFS= read -r line; do
    map["${line:34}"]="${line:0:32}"
  done < <(find "$@" -name '.*' -prune -o -type f -print0 | xargs -0 -r md5sum)
}

install_file() {
  local src="$1"
  local dst="$2"

  # Remove stale symlink if present
  [ -L "$dst" ] && rm "$dst"

  # Distinct fallbacks on the two lookups, so a path absent from either map
  # never reads as a match.
  if [ -e "$dst" ] && [ "${SRC_MD5[$src]-src}" = "${DST_MD5[$dst]-dst}" ]; then
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

# Recreate a source tree's directory skeleton under dst in a single mkdir,
# rather than one call per copied file.
mirror_dirs() {
  local src="$1"
  local dst="$2"
  local dirs=("$dst")
  local dir
  while IFS= read -r -d '' dir; do
    dirs+=("$dst/${dir#$src/}")
  done < <(find "$src" -mindepth 1 -name '.*' -prune -o -type d -print0)
  mkdir -p "${dirs[@]}"
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

# Digest both trees up front — every install_file below reads these maps.
# settings.json is absent: install_settings compares the rendered text instead.
hash_tree SRC_MD5 \
  "$REPO/hooks" "$REPO/skills" "$REPO/docs" \
  "$REPO/CLAUDE.md" "$REPO/CLAUDE.stub.md" "$REPO/statusline.sh" \
  "$REPO/previews/henneth/skadi-theme.css"

live=()
for path in hooks skills docs CLAUDE.md statusline.sh previews/henneth/skadi-theme.css; do
  if [ -e "$CLAUDE_DIR/$path" ]; then
    live+=("$CLAUDE_DIR/$path")
  fi
done
if [ ${#live[@]} -gt 0 ]; then
  hash_tree DST_MD5 "${live[@]}"
fi

# Global CLAUDE.md — the full file, save for one case. Claude Code loads
# ~/.claude/CLAUDE.md as a baseline beside whichever profile root is active, so
# on a machine that HAS a profile root the full text would arrive twice in one
# context window; there the default root takes the stub instead. Where no
# profile root stands, ~/.claude *is* the active root and must carry the rules —
# keying on the path alone (as this once did) left them nowhere. compgen's
# trailing slash matches directories only, so ~/.claude.json cannot pass for one.
claude_md="$REPO/CLAUDE.md"
if [ "$CLAUDE_DIR" = "$HOME/.claude" ] && compgen -G "$HOME/.claude-*/" >/dev/null; then
  claude_md="$REPO/CLAUDE.stub.md"
fi
install_file "$claude_md" "$CLAUDE_DIR/CLAUDE.md"

# Global settings (with {{SKADI_ROOT}} substitution)
install_settings "$REPO/settings.json" "$CLAUDE_DIR/settings.json"

# Status line script
install_file "$REPO/statusline.sh" "$CLAUDE_DIR/statusline.sh"

# Hooks
mkdir -p "$CLAUDE_DIR/hooks"
for hook in "$REPO/hooks/"*; do
  [ -f "$hook" ] || continue
  hook_name="${hook##*/}"
  [[ "$hook_name" == ".gitkeep" ]] && continue
  install_file "$hook" "$CLAUDE_DIR/hooks/$hook_name"
done
prune_tree "$REPO/hooks" "$CLAUDE_DIR/hooks"

# Skills
mirror_dirs "$REPO/skills" "$CLAUDE_DIR/skills"
for skill in "$REPO/skills/"*; do
  skill_name="${skill##*/}"
  [[ "$skill_name" == ".gitkeep" ]] && continue
  if [ -d "$skill" ]; then
    # Mirror every file under the skill directory, preserving structure.
    while IFS= read -r -d '' src; do
      rel="${src#$skill/}"
      dst="$CLAUDE_DIR/skills/$skill_name/$rel"
      install_file "$src" "$dst"
    done < <(find "$skill" -name '.*' -prune -o -type f -print0)
  elif [ -f "$skill" ]; then
    skill_name="${skill_name%.*}"
    mkdir -p "$CLAUDE_DIR/skills/$skill_name"
    install_file "$skill" "$CLAUDE_DIR/skills/$skill_name/SKILL.md"
  fi
done
prune_tree "$REPO/skills" "$CLAUDE_DIR/skills"

# Docs
if [ -d "$REPO/docs" ]; then
  mirror_dirs "$REPO/docs" "$CLAUDE_DIR/docs"
  while IFS= read -r -d '' src; do
    rel="${src#$REPO/docs/}"
    dst="$CLAUDE_DIR/docs/$rel"
    install_file "$src" "$dst"
  done < <(find "$REPO/docs" -name '.*' -prune -o -type f -print0)
  prune_tree "$REPO/docs" "$CLAUDE_DIR/docs"
fi

# Preview theme — a single shared stylesheet for Henneth previews to link.
# Copy the one file only; never prune the previews folder — it holds the user's
# rendered artifacts, which are runtime, not ours to delete.
if [ -f "$REPO/previews/henneth/skadi-theme.css" ]; then
  mkdir -p "$CLAUDE_DIR/previews/henneth"
  install_file "$REPO/previews/henneth/skadi-theme.css" "$CLAUDE_DIR/previews/henneth/skadi-theme.css"
fi

echo ""
echo "Done."
