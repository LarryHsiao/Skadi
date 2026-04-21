#!/usr/bin/env bash
# cleanup-dev-report.sh — measure sizes of dev caches. Read-only.
# Output: pipe-delimited lines "bucket|size|detail"
set -uo pipefail

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

measure xcode-derived-data "$HOME/Library/Developer/Xcode/DerivedData"
measure xcode-archives     "$HOME/Library/Developer/Xcode/Archives"
measure gradle-caches      "$HOME/.gradle/caches"
measure gradle-daemon      "$HOME/.gradle/daemon"
measure pub-cache          "$HOME/.pub-cache"
measure homebrew-cache     "$HOME/Library/Caches/Homebrew"
measure npm-cache          "$HOME/.npm/_cacache"
measure pnpm-store         "$HOME/.pnpm-store"
measure yarn-cache         "$HOME/.yarn/cache"
measure cargo-registry     "$HOME/.cargo/registry/cache"
measure cargo-git          "$HOME/.cargo/git"
measure jetbrains-caches   "$HOME/Library/Caches/JetBrains"
measure jetbrains-logs     "$HOME/Library/Logs/JetBrains"

# Android Studio caches (glob)
as_dir="$HOME/Library/Caches/Google"
if [ -d "$as_dir" ]; then
  size="$(du -sh "$as_dir" 2>/dev/null | awk '{print $1}')"
  printf "android-studio-caches|%s|%s/AndroidStudio*\n" "${size:-?}" "$as_dir"
else
  printf "android-studio-caches|-|%s (missing)\n" "$as_dir"
fi

# Xcode unavailable simulators — count, not size
if command -v xcrun >/dev/null 2>&1; then
  count=$(xcrun simctl list devices 2>/dev/null | grep -c "unavailable" || true)
  printf "xcode-sim-unavailable|%s devices|xcrun simctl delete unavailable\n" "${count:-0}"
fi

# Docker dangling
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  imgs=$(docker images -qf dangling=true 2>/dev/null | wc -l | tr -d ' ')
  vols=$(docker volume ls -qf dangling=true 2>/dev/null | wc -l | tr -d ' ')
  printf "docker-prune|%s imgs, %s vols|docker system prune -af + volume prune\n" "${imgs:-0}" "${vols:-0}"
fi

# fvm version count + cache size (interactive choice — not auto-deleted)
if command -v fvm >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  json="$(fvm api list --compress 2>/dev/null)"
  if [ -n "$json" ]; then
    size="$(echo "$json" | jq -r '.size // "?"')"
    count="$(echo "$json" | jq -r '.versions | length')"
    printf "fvm-versions|%s (%s total)|interactive (user picks)\n" "${count:-0} installed" "$size"
  fi
fi
