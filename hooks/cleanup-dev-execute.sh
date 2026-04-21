#!/usr/bin/env bash
# cleanup-dev-execute.sh — delete approved dev-cache buckets.
# Destructive. Only runs what the caller asks for.
#
# Usage:
#   cleanup-dev-execute.sh BUCKET [BUCKET...]
#   cleanup-dev-execute.sh fvm-remove VERSION [VERSION...]
#   cleanup-dev-execute.sh project-path PATH [PATH...]
set -uo pipefail

clean_bucket() {
  case "$1" in
    xcode-derived-data)
      rm -rf "$HOME/Library/Developer/Xcode/DerivedData"/* 2>/dev/null || true
      ;;
    xcode-archives)
      rm -rf "$HOME/Library/Developer/Xcode/Archives"/* 2>/dev/null || true
      ;;
    xcode-sim-unavailable)
      xcrun simctl delete unavailable
      ;;
    gradle-caches)
      rm -rf "$HOME/.gradle/caches" 2>/dev/null || true
      ;;
    gradle-daemon)
      rm -rf "$HOME/.gradle/daemon" 2>/dev/null || true
      ;;
    pub-cache)
      if command -v fvm >/dev/null 2>&1; then
        fvm dart pub cache clean -f 2>/dev/null || rm -rf "$HOME/.pub-cache"
      else
        rm -rf "$HOME/.pub-cache"
      fi
      ;;
    homebrew-cache)
      brew cleanup -s
      rm -rf "$(brew --cache)" 2>/dev/null || true
      ;;
    npm-cache)
      npm cache clean --force 2>/dev/null || rm -rf "$HOME/.npm/_cacache"
      ;;
    pnpm-store)
      pnpm store prune 2>/dev/null || true
      ;;
    yarn-cache)
      yarn cache clean 2>/dev/null || rm -rf "$HOME/.yarn/cache"
      ;;
    cargo-registry)
      rm -rf "$HOME/.cargo/registry/cache" 2>/dev/null || true
      ;;
    cargo-git)
      rm -rf "$HOME/.cargo/git" 2>/dev/null || true
      ;;
    jetbrains-caches)
      rm -rf "$HOME/Library/Caches/JetBrains" 2>/dev/null || true
      ;;
    jetbrains-logs)
      rm -rf "$HOME/Library/Logs/JetBrains" 2>/dev/null || true
      ;;
    android-studio-caches)
      rm -rf "$HOME/Library/Caches/Google"/AndroidStudio* 2>/dev/null || true
      ;;
    docker-prune)
      docker system prune -af
      docker volume prune -f
      ;;
    *)
      echo "unknown bucket: $1" >&2
      return 1
      ;;
  esac
  echo "done: $1"
}

if [ $# -eq 0 ]; then
  echo "usage: $(basename "$0") BUCKET [BUCKET...]"
  echo "       $(basename "$0") fvm-remove VERSION [VERSION...]"
  echo "       $(basename "$0") project-path PATH [PATH...]"
  exit 2
fi

case "$1" in
  fvm-remove)
    shift
    [ $# -eq 0 ] && { echo "fvm-remove: missing VERSION" >&2; exit 2; }
    for v in "$@"; do
      fvm remove "$v" && echo "fvm removed: $v"
    done
    ;;
  project-path)
    shift
    [ $# -eq 0 ] && { echo "project-path: missing PATH" >&2; exit 2; }
    for p in "$@"; do
      base="$(basename "$p")"
      case "$base" in
        node_modules|.dart_tool|build|target|.next)
          if [ -d "$p" ]; then
            rm -rf "$p" && echo "removed: $p"
          else
            echo "skip (not found): $p"
          fi
          ;;
        *)
          echo "refused: $p (not a recognized artifact dir)" >&2
          ;;
      esac
    done
    ;;
  *)
    for b in "$@"; do
      clean_bucket "$b"
    done
    ;;
esac
