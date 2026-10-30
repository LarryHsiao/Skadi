#!/usr/bin/env bash
# shadowfax-toolchain.sh — ready a fresh cloud container for a Flutter project.
#
#   shadowfax-toolchain.sh [project-dir] [--sdk-only]
#
# A cloud session starts on a bare container: no Flutter SDK, no generated code,
# and a git dependency pinned to git@github.com: that has no SSH key to answer
# it. This script pays those three costs once per container:
#
#   1. The SDK version the project pins (.fvmrc, else .fvm/fvm_config.json,
#      else stable) is cloned under SHADOWFAX_SDK_HOME (default ~/.shadowfax)
#      unless it already stands there.
#   2. git@github.com: is rewritten to https://github.com/ when the project's
#      pubspec names it, so pub reaches the dependency through the agent proxy.
#   3. `flutter pub get`, then `dart run build_runner build` when the project
#      leans on build_runner — generated files are not checked in, and the
#      analyzer reads their absence as hundreds of errors.
#
# --sdk-only stops after step 1. On success the only line on stdout is the
# PATH export to prefix later Flutter calls with; progress goes to stderr. A
# directory with no pubspec.yaml prints a note to stderr and nothing to stdout,
# exiting 0, since a non-Flutter project brings its own setup. Only a tag or
# channel pin (3.41.0, stable) can be cloned; an fvm fork or commit pin cannot.
set -euo pipefail

FLUTTER_GIT="https://github.com/flutter/flutter.git"
SDK_HOME="${SHADOWFAX_SDK_HOME:-$HOME/.shadowfax}"

project="$PWD"
sdk_only=false
for arg in "$@"; do
  case "$arg" in
    --sdk-only) sdk_only=true ;;
    *) project="$arg" ;;
  esac
done

if [ ! -f "$project/pubspec.yaml" ]; then
  echo "shadowfax: no pubspec.yaml in $project — not a Flutter project; use its own setup." >&2
  exit 0
fi

# The pinned version, read with the json key each fvm layout uses; a file
# that lacks its key falls through to the next layout.
pinned_version() {
  local pair file key version
  for pair in ".fvmrc:flutter" ".fvm/fvm_config.json:flutterSdkVersion"; do
    file="$project/${pair%%:*}" key="${pair##*:}"
    [ -f "$file" ] || continue
    version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$file" "$key")"
    [ -n "$version" ] && { echo "$version"; return; }
  done
  return 0
}

version="$(pinned_version)"
version="${version:-stable}"
sdk="$SDK_HOME/flutter-$version"

if [ ! -x "$sdk/bin/flutter" ]; then
  mkdir -p "$SDK_HOME"
  git clone -q --depth 1 -b "$version" "$FLUTTER_GIT" "$sdk" >&2
fi

if [ "$sdk_only" = false ]; then
  if grep -q "git@github.com:" "$project/pubspec.yaml" \
    && ! git config --global --get-all url."https://github.com/".insteadOf | grep -qx "git@github.com:"; then
    git config --global --add url."https://github.com/".insteadOf "git@github.com:"
  fi
  (cd "$project" && "$sdk/bin/flutter" pub get >&2)
  if grep -q "build_runner" "$project/pubspec.yaml"; then
    (cd "$project" && "$sdk/bin/dart" run build_runner build --delete-conflicting-outputs >&2)
  fi
fi

echo "export PATH=\"$sdk/bin:\$PATH\""
