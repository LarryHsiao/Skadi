#!/bin/bash
# Offline tests for publish-dsym.sh — Crashlytics detection and dSYM collection
# for /publish-flutter's ios path. Fixtures are built in a temp dir; nothing is built or
# uploaded. Run: bash publish-dsym.test.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/publish-dsym.sh"
pass=0
fail=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
tmpdir() { mktemp -d "$ROOT/d.XXXXXX"; }

check() {
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# ── detect · 1 · firebase_crashlytics in pubspec -> enabled ──
d=$(tmpdir)
printf 'dependencies:\n  firebase_crashlytics: ^4.0.0\n' >"$d/pubspec.yaml"
out="$(bash "$SCRIPT" detect "$d")"
rc=$?
expected="0/enabled|firebase_crashlytics in pubspec.yaml"
check "pubspec dependency reads as enabled" "$expected" "$rc/$out"

# ── detect · 2 · plist beside the dependency is named as evidence ──
d=$(tmpdir)
printf 'dependencies:\n  firebase_crashlytics: ^4.0.0\n' >"$d/pubspec.yaml"
mkdir -p "$d/ios/Runner" && : >"$d/ios/Runner/GoogleService-Info.plist"
out="$(bash "$SCRIPT" detect "$d")"
expected="enabled|firebase_crashlytics in pubspec.yaml; ios/Runner/GoogleService-Info.plist present"
check "plist is reported as supporting evidence" "$expected" "$out"

# ── detect · 3 · no dependency -> disabled, exit 1 ──
d=$(tmpdir)
printf 'dependencies:\n  flutter:\n    sdk: flutter\n' >"$d/pubspec.yaml"
out="$(bash "$SCRIPT" detect "$d")"
rc=$?
expected="1/disabled|firebase_crashlytics not in pubspec.yaml"
check "no dependency reads as disabled" "$expected" "$rc/$out"

# ── detect · 4 · a commented-out dependency does not count ──
d=$(tmpdir)
printf 'dependencies:\n  # firebase_crashlytics: ^4.0.0\n' >"$d/pubspec.yaml"
out="$(bash "$SCRIPT" detect "$d")"
rc=$?
expected="1/disabled|firebase_crashlytics not in pubspec.yaml"
check "a commented-out dependency reads as disabled" "$expected" "$rc/$out"

# ── detect · 5 · no pubspec -> exit 2 ──
d=$(tmpdir)
bash "$SCRIPT" detect "$d" >/dev/null 2>&1
rc=$?
expected="2"
check "missing pubspec.yaml exits 2" "$expected" "$rc"

# ── collect · 1 · every .dSYM is copied and zipped ──
d=$(tmpdir)
dsyms="$d/build/ios/archive/Runner.xcarchive/dSYMs"
mkdir -p "$dsyms/Runner.app.dSYM/Contents" "$dsyms/App.framework.dSYM/Contents"
out="$(bash "$SCRIPT" collect "$d")"
rc=$?
expected="0/collected|2|build/publish/dSYMs"
check "two dSYM bundles are collected" "$expected" "$rc/$out"
expected="App.framework.dSYM Runner.app.dSYM"
actual="$(cd "$d/build/publish/dSYMs" && echo *)"
check "both bundles land in build/publish/dSYMs" "$expected" "$actual"
expected="yes"
actual="$([[ -s "$d/build/publish/dSYMs.zip" ]] && echo yes || echo no)"
check "dSYMs.zip is written beside the ipa" "$expected" "$actual"

# ── collect · 2 · no archive at all -> none, exit 1 ──
d=$(tmpdir)
out="$(bash "$SCRIPT" collect "$d")"
rc=$?
expected="1/none|no dSYMs under build/ios/archive/*.xcarchive/dSYMs"
check "no archive reads as none" "$expected" "$rc/$out"

# ── collect · 3 · archive with an empty dSYMs dir -> none, exit 1 ──
d=$(tmpdir)
mkdir -p "$d/build/ios/archive/Runner.xcarchive/dSYMs"
out="$(bash "$SCRIPT" collect "$d")"
rc=$?
expected="1/none|no dSYMs under build/ios/archive/*.xcarchive/dSYMs"
check "an empty dSYMs dir reads as none" "$expected" "$rc/$out"

echo "passed $pass, failed $fail"
[[ $fail -eq 0 ]]
