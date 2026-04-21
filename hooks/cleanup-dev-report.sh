#!/usr/bin/env bash
# cleanup-dev-report.sh — measure sizes of dev caches. Read-only.
# Output: pipe-delimited lines "bucket|size|detail"
set -uo pipefail

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  Darwin) OS=mac ;;
  *) OS=linux ;;
esac

# Normalize Windows env vars to POSIX paths when running in Git Bash.
if [ "$OS" = windows ]; then
  LOCALAPPDATA_POSIX="$(cygpath -u "${LOCALAPPDATA:-$HOME/AppData/Local}" 2>/dev/null || echo "$HOME/AppData/Local")"
  APPDATA_POSIX="$(cygpath -u "${APPDATA:-$HOME/AppData/Roaming}" 2>/dev/null || echo "$HOME/AppData/Roaming")"
fi

measure() {
  local key="$1" path="$2"
  if [ -e "$path" ]; then
    local size
    size="$(du -sh "$path" 2>/dev/null | awk '{print $1}')"
    printf "%s|%s|%s\n" "$key" "${size:-?}" "$path"
  else
    printf "%s|-|%s (missing)\n" "$key" "$path"
  fi
}

# Glob measure — sums matching directories under a parent.
measure_glob() {
  local key="$1" parent="$2" pattern="$3"
  if [ -d "$parent" ]; then
    local total
    # shellcheck disable=SC2086
    total="$(du -sch "$parent"/$pattern 2>/dev/null | awk 'END{print $1}')"
    if [ -n "$total" ] && [ "$total" != "0" ]; then
      printf "%s|%s|%s/%s\n" "$key" "$total" "$parent" "$pattern"
    else
      printf "%s|-|%s/%s (missing)\n" "$key" "$parent" "$pattern"
    fi
  else
    printf "%s|-|%s (missing)\n" "$key" "$parent"
  fi
}

if [ "$OS" = mac ]; then
  measure xcode-derived-data "$HOME/Library/Developer/Xcode/DerivedData"
  measure xcode-archives     "$HOME/Library/Developer/Xcode/Archives"
  measure homebrew-cache     "$HOME/Library/Caches/Homebrew"
  measure jetbrains-caches   "$HOME/Library/Caches/JetBrains"
  measure jetbrains-logs     "$HOME/Library/Logs/JetBrains"
  measure android-studio-caches "$HOME/Library/Caches/Google"
  measure pub-cache          "$HOME/.pub-cache"
  measure npm-cache          "$HOME/.npm/_cacache"
  measure yarn-cache         "$HOME/.yarn/cache"
elif [ "$OS" = windows ]; then
  measure jetbrains-caches   "$LOCALAPPDATA_POSIX/JetBrains"
  measure_glob jetbrains-logs "$LOCALAPPDATA_POSIX/JetBrains" "*/log"
  measure_glob android-studio-caches "$LOCALAPPDATA_POSIX/Google" "AndroidStudio*"
  measure pub-cache          "$LOCALAPPDATA_POSIX/Pub/Cache"
  measure yarn-cache         "$LOCALAPPDATA_POSIX/Yarn/Cache"
  measure npm-cache          "$APPDATA_POSIX/npm-cache"
  [ -d "$HOME/.npm/_cacache" ] && measure npm-cache-home "$HOME/.npm/_cacache"
else
  measure jetbrains-caches   "$HOME/.cache/JetBrains"
  measure pub-cache          "$HOME/.pub-cache"
  measure npm-cache          "$HOME/.npm/_cacache"
  measure yarn-cache         "$HOME/.yarn/cache"
fi

# Cross-platform buckets (Git Bash maps $HOME to %USERPROFILE% on Windows).
measure gradle-caches      "$HOME/.gradle/caches"
measure gradle-daemon      "$HOME/.gradle/daemon"
measure pnpm-store         "$HOME/.pnpm-store"
measure cargo-registry     "$HOME/.cargo/registry/cache"
measure cargo-git          "$HOME/.cargo/git"

# Xcode unavailable simulators — count, not size (macOS only).
if [ "$OS" = mac ] && command -v xcrun >/dev/null 2>&1; then
  count=$(xcrun simctl list devices 2>/dev/null | grep -c "unavailable" || true)
  printf "xcode-sim-unavailable|%s devices|xcrun simctl delete unavailable\n" "${count:-0}"
fi

# Docker dangling — runs anywhere Docker is installed.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  imgs=$(docker images -qf dangling=true 2>/dev/null | wc -l | tr -d ' ')
  vols=$(docker volume ls -qf dangling=true 2>/dev/null | wc -l | tr -d ' ')
  printf "docker-prune|%s imgs, %s vols|docker system prune -af + volume prune\n" "${imgs:-0}" "${vols:-0}"
fi

# fvm version count + cache size (interactive choice — not auto-deleted).
if command -v fvm >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  json="$(fvm api list --compress 2>/dev/null)"
  if [ -n "$json" ]; then
    size="$(echo "$json" | jq -r '.size // "?"')"
    count="$(echo "$json" | jq -r '.versions | length')"
    printf "fvm-versions|%s (%s total)|interactive (user picks)\n" "${count:-0} installed" "$size"
  fi
fi
