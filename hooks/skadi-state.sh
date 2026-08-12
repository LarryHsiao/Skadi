#!/usr/bin/env bash
# Resolve and migrate Skadi-owned workflow state. Chat history and agent memory
# remain product-owned; routing/preferences shared by paired profiles live here.

set -euo pipefail

die() {
  echo "skadi-state: $1" >&2
  exit 1
}

slug_profile() {
  case "${1:-default}" in
    default|.claude|.codex) echo default ;;
    personal|.claude-personal|.codex-personal) echo personal ;;
    work|.claude-work|.codex-work) echo work ;;
    *) printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_' ;;
  esac
}

project_root() {
  local path="${1:-$PWD}"
  git -C "$path" rev-parse --show-toplevel 2>/dev/null || (cd "$path" && pwd -P)
}

project_key() {
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

state_dir() {
  local profile root key
  profile="$(slug_profile "$1")"
  root="$(project_root "$2")"
  key="$(project_key "$root")"
  printf '%s/.skadi/profiles/%s/projects/%s\n' "$HOME" "$profile" "$key"
}

verb="${1:-}"
case "$verb" in
  project-dir)
    profile="${2:-default}"
    project="${3:-$PWD}"
    dir="$(state_dir "$profile" "$project")"
    mkdir -p "$dir"
    printf '%s\n' "$dir"
    ;;

  path)
    profile="${2:-default}"
    project="${3:-$PWD}"
    file="${4:-}"
    [ -n "$file" ] || die "path: missing filename"
    dir="$(state_dir "$profile" "$project")"
    mkdir -p "$dir"
    printf '%s/%s\n' "$dir" "$file"
    ;;

  migrate)
    profile="${2:-default}"
    project="${3:-$PWD}"
    claude_root="${4:-$HOME/.claude}"
    root="$(project_root "$project")"
    destination="$(state_dir "$profile" "$root")"
    legacy_key="${root//\//-}"
    source="$claude_root/projects/$legacy_key/memory"
    [ -d "$source" ] || exit 0
    mkdir -p "$destination"
    conflicts=0
    while IFS= read -r -d '' file; do
      name="${file##*/}"
      case "$name" in MEMORY.md) continue ;; esac
      target="$destination/$name"
      if [ ! -e "$target" ]; then
        cp -p "$file" "$target"
        echo "migrated: $name"
      elif ! cmp -s "$file" "$target"; then
        echo "conflict: $name ($file != $target)" >&2
        conflicts=1
      fi
    done < <(find "$source" -maxdepth 1 -type f -print0)
    [ "$conflicts" -eq 0 ] || exit 2
    ;;

  *)
    die "expected project-dir <profile> [project], path <profile> <project> <file>, or migrate <profile> <project> [claude-root]"
    ;;
esac
