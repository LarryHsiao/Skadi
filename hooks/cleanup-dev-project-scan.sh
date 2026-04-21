#!/usr/bin/env bash
# cleanup-dev-project-scan.sh — find per-project build artifacts under $HOME.
# Output: pipe-delimited lines "size|path"
# Read-only. Excludes system/app-data dirs. Max depth 5.
set -uo pipefail

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  Darwin) OS=mac ;;
  *) OS=linux ;;
esac

excludes=(
  -not -path "$HOME/.Trash/*" -not -path "$HOME/.Trash"
)

if [ "$OS" = mac ]; then
  excludes+=( -not -path "$HOME/Library/*" )
elif [ "$OS" = windows ]; then
  excludes+=(
    -not -path "$HOME/AppData/*"
    -not -path "$HOME/OneDrive*/*"
    -not -path "$HOME/\$Recycle.Bin/*"
    -not -path "$HOME/NTUSER.DAT*"
  )
fi

find "$HOME" -maxdepth 5 -type d \
  \( -name node_modules -o -name .dart_tool -o -name build -o -name target -o -name .next \) \
  "${excludes[@]}" \
  -prune 2>/dev/null | while IFS= read -r path; do
    size="$(du -sh "$path" 2>/dev/null | awk '{print $1}')"
    printf "%s|%s\n" "${size:-?}" "$path"
  done | sort -hr
