#!/usr/bin/env bash
# cleanup-dev-execute.sh — delete approved dev-cache buckets.
# Destructive. Only runs what the caller asks for.
#
# Usage:
#   cleanup-dev-execute.sh BUCKET [BUCKET...]
#   cleanup-dev-execute.sh fvm-remove VERSION [VERSION...]
#   cleanup-dev-execute.sh project-path PATH [PATH...]
set -uo pipefail

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  Darwin) OS=mac ;;
  *) OS=linux ;;
esac

if [ "$OS" = windows ]; then
  LOCALAPPDATA_POSIX="$(cygpath -u "${LOCALAPPDATA:-$HOME/AppData/Local}" 2>/dev/null || echo "$HOME/AppData/Local")"
  APPDATA_POSIX="$(cygpath -u "${APPDATA:-$HOME/AppData/Roaming}" 2>/dev/null || echo "$HOME/AppData/Roaming")"
fi

rmrf_glob() {
  # shellcheck disable=SC2086
  rm -rf $1 2>/dev/null || true
}

clean_bucket() {
  case "$1" in
    xcode-derived-data)
      [ "$OS" = mac ] || { echo "skip $1 (macOS only)"; return 0; }
      rm -rf "$HOME/Library/Developer/Xcode/DerivedData"/* 2>/dev/null || true
      ;;
    xcode-archives)
      [ "$OS" = mac ] || { echo "skip $1 (macOS only)"; return 0; }
      rm -rf "$HOME/Library/Developer/Xcode/Archives"/* 2>/dev/null || true
      ;;
    xcode-sim-unavailable)
      [ "$OS" = mac ] || { echo "skip $1 (macOS only)"; return 0; }
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
        fvm dart pub cache clean -f 2>/dev/null && { echo "done: $1"; return 0; }
      fi
      case "$OS" in
        windows) rm -rf "$LOCALAPPDATA_POSIX/Pub/Cache" 2>/dev/null || true ;;
        *)       rm -rf "$HOME/.pub-cache" 2>/dev/null || true ;;
      esac
      ;;
    homebrew-cache)
      [ "$OS" = mac ] || { echo "skip $1 (macOS only)"; return 0; }
      brew cleanup -s
      rm -rf "$(brew --cache)" 2>/dev/null || true
      ;;
    npm-cache)
      npm cache clean --force 2>/dev/null && { echo "done: $1"; return 0; }
      case "$OS" in
        windows) rm -rf "$APPDATA_POSIX/npm-cache" 2>/dev/null || true ;;
        *)       rm -rf "$HOME/.npm/_cacache" 2>/dev/null || true ;;
      esac
      ;;
    npm-cache-home)
      rm -rf "$HOME/.npm/_cacache" 2>/dev/null || true
      ;;
    pnpm-store)
      pnpm store prune 2>/dev/null || true
      ;;
    yarn-cache)
      yarn cache clean 2>/dev/null && { echo "done: $1"; return 0; }
      case "$OS" in
        windows) rm -rf "$LOCALAPPDATA_POSIX/Yarn/Cache" 2>/dev/null || true ;;
        *)       rm -rf "$HOME/.yarn/cache" 2>/dev/null || true ;;
      esac
      ;;
    cargo-registry)
      rm -rf "$HOME/.cargo/registry/cache" 2>/dev/null || true
      ;;
    cargo-git)
      rm -rf "$HOME/.cargo/git" 2>/dev/null || true
      ;;
    jetbrains-caches)
      case "$OS" in
        mac)     rm -rf "$HOME/Library/Caches/JetBrains" 2>/dev/null || true ;;
        windows) rm -rf "$LOCALAPPDATA_POSIX/JetBrains"/*/caches 2>/dev/null || true ;;
        *)       rm -rf "$HOME/.cache/JetBrains" 2>/dev/null || true ;;
      esac
      ;;
    jetbrains-logs)
      case "$OS" in
        mac)     rm -rf "$HOME/Library/Logs/JetBrains" 2>/dev/null || true ;;
        windows) rmrf_glob "$LOCALAPPDATA_POSIX/JetBrains/*/log" ;;
        *)       : ;;
      esac
      ;;
    android-studio-caches)
      case "$OS" in
        mac)     rmrf_glob "$HOME/Library/Caches/Google/AndroidStudio*" ;;
        windows) rmrf_glob "$LOCALAPPDATA_POSIX/Google/AndroidStudio*" ;;
        *)       : ;;
      esac
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
