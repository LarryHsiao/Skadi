#!/bin/bash
# publish-dsym.sh — Crashlytics detection and dSYM collection for /publish-flutter's ios path.
#
# Usage:
#   publish-dsym.sh detect [project-dir]
#       Prints `enabled|<evidence>` (exit 0), `disabled|<reason>` (exit 1), and
#       exits 2 when project-dir has no pubspec.yaml.
#   publish-dsym.sh collect [project-dir]
#       Copies every .dSYM from build/ios/archive/*.xcarchive/dSYMs into
#       build/publish/dSYMs and zips them to build/publish/dSYMs.zip. Prints
#       `collected|<count>|build/publish/dSYMs` (exit 0), or `none|<reason>` (exit 1).
set -uo pipefail

CRASHLYTICS_PACKAGE="firebase_crashlytics"
PLIST_PATH="ios/Runner/GoogleService-Info.plist"
ARCHIVE_DSYMS_GLOB="build/ios/archive/*.xcarchive/dSYMs"
PUBLISH_DSYMS="build/publish/dSYMs"

detect() {
  local dir="${1:-.}"
  if [[ ! -f "$dir/pubspec.yaml" ]]; then
    echo "no pubspec.yaml in $dir" >&2
    return 2
  fi
  if ! grep -Eq "^[[:space:]]*${CRASHLYTICS_PACKAGE}:" "$dir/pubspec.yaml"; then
    echo "disabled|$CRASHLYTICS_PACKAGE not in pubspec.yaml"
    return 1
  fi
  local evidence="$CRASHLYTICS_PACKAGE in pubspec.yaml"
  [[ -f "$dir/$PLIST_PATH" ]] && evidence="$evidence; $PLIST_PATH present"
  echo "enabled|$evidence"
}

collect() {
  local dir="${1:-.}"
  local found=()
  local bundle
  # The glob constant must stay unquoted so the shell expands it.
  # shellcheck disable=SC2231
  for bundle in "$dir"/$ARCHIVE_DSYMS_GLOB/*.dSYM; do
    [[ -d "$bundle" ]] && found+=("$bundle")
  done
  if [[ ${#found[@]} -eq 0 ]]; then
    echo "none|no dSYMs under $ARCHIVE_DSYMS_GLOB"
    return 1
  fi
  rm -rf "${dir:?}/$PUBLISH_DSYMS" "$dir/$PUBLISH_DSYMS.zip"
  mkdir -p "$dir/$PUBLISH_DSYMS"
  cp -R "${found[@]}" "$dir/$PUBLISH_DSYMS/"
  ditto -c -k --keepParent "$dir/$PUBLISH_DSYMS" "$dir/$PUBLISH_DSYMS.zip"
  echo "collected|${#found[@]}|$PUBLISH_DSYMS"
}

case "${1:-}" in
  detect) shift; detect "$@" ;;
  collect) shift; collect "$@" ;;
  *) echo "usage: publish-dsym.sh detect|collect [project-dir]" >&2; exit 2 ;;
esac
