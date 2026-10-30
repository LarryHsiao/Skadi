#!/bin/bash
# Offline tests for shadowfax-toolchain.sh. The contract: a directory with no
# pubspec.yaml is left alone; the SDK path follows the version the project pins,
# falling back through .fvm/fvm_config.json to stable; an SDK already
# standing is reused rather than cloned again; the git@github.com: rewrite is
# added once and only when the pubspec needs it; --sdk-only fetches nothing. No
# test touches the network — each plants a stub SDK where the clone would land,
# and HOME points at a scratch folder so the global git config stays untouched.
# Run: bash shadowfax-toolchain.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/shadowfax-toolchain.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export SHADOWFAX_SDK_HOME="$WORK/sdks"
export HOME="$WORK/home"
mkdir -p "$HOME"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# stub_sdk <version> — flutter and dart binaries where the clone would have
# put them; each logs its arguments to calls.log so a test can see what ran.
stub_sdk() {
  local bin="$SHADOWFAX_SDK_HOME/flutter-$1/bin" tool
  mkdir -p "$bin"
  for tool in flutter dart; do
    printf '#!/bin/sh\necho "%s $*" >>"%s/calls.log"\n' "$tool" "$WORK" >"$bin/$tool"
    chmod +x "$bin/$tool"
  done
}

rewrites() { git config --global --get-all url."https://github.com/".insteadOf | grep -cx "git@github.com:"; }

# project <name> — an empty Flutter project directory.
project() {
  mkdir -p "$WORK/$1"
  echo "name: $1" >"$WORK/$1/pubspec.yaml"
  echo "$WORK/$1"
}

# ── 1 · a directory with no pubspec.yaml is not a Flutter project ──
mkdir -p "$WORK/plain"
expected_plain="not-flutter"
actual_plain=$(bash "$HOOK" "$WORK/plain" --sdk-only 2>&1 >/dev/null | grep -q "not a Flutter project" && echo "not-flutter")
check "a directory with no pubspec.yaml is left alone" "$expected_plain" "$actual_plain"

# ── 2 · the .fvmrc version names the SDK on PATH ──
dir=$(project pinned)
echo '{"flutter": "3.41.0"}' >"$dir/.fvmrc"
stub_sdk 3.41.0
expected_pinned="export PATH=\"$SHADOWFAX_SDK_HOME/flutter-3.41.0/bin:\$PATH\""
actual_pinned=$(bash "$HOOK" "$dir" --sdk-only | tail -1)
check ".fvmrc's version names the SDK on PATH" "$expected_pinned" "$actual_pinned"

# ── 3 · the older fvm layout is read when .fvmrc is absent ──
dir=$(project legacy)
mkdir -p "$dir/.fvm"
echo '{"flutterSdkVersion": "3.29.0"}' >"$dir/.fvm/fvm_config.json"
stub_sdk 3.29.0
expected_legacy="export PATH=\"$SHADOWFAX_SDK_HOME/flutter-3.29.0/bin:\$PATH\""
actual_legacy=$(bash "$HOOK" "$dir" --sdk-only | tail -1)
check ".fvm/fvm_config.json is read when .fvmrc is absent" "$expected_legacy" "$actual_legacy"

# ── 4 · no pin at all falls back to stable ──
dir=$(project unpinned)
stub_sdk stable
expected_stable="export PATH=\"$SHADOWFAX_SDK_HOME/flutter-stable/bin:\$PATH\""
actual_stable=$(bash "$HOOK" "$dir" --sdk-only | tail -1)
check "an unpinned project falls back to stable" "$expected_stable" "$actual_stable"

# ── 5 · a .fvmrc lacking its key falls through to the older layout ──
dir=$(project fallthrough)
echo '{}' >"$dir/.fvmrc"
mkdir -p "$dir/.fvm"
echo '{"flutterSdkVersion": "3.29.0"}' >"$dir/.fvm/fvm_config.json"
expected_fall="export PATH=\"$SHADOWFAX_SDK_HOME/flutter-3.29.0/bin:\$PATH\""
actual_fall=$(bash "$HOOK" "$dir" --sdk-only | tail -1)
check "a .fvmrc lacking its key falls through" "$expected_fall" "$actual_fall"

# ── 6 · --sdk-only fetches nothing and rewrites nothing ──
dir=$(project sdkonly)
echo '  dep: {git: git@github.com:me/dep}' >>"$dir/pubspec.yaml"
rm -f "$WORK/calls.log"
bash "$HOOK" "$dir" --sdk-only >/dev/null
expected_quiet="0 0"
actual_quiet="$(cat "$WORK/calls.log" 2>/dev/null | wc -l | tr -d ' ') $(rewrites)"
check "--sdk-only runs no pub get and adds no rewrite" "$expected_quiet" "$actual_quiet"

# ── 7 · a git@github.com: dependency adds the https rewrite exactly once ──
bash "$HOOK" "$dir" >/dev/null 2>&1
bash "$HOOK" "$dir" >/dev/null 2>&1
expected_once="1"
actual_once=$(rewrites)
check "the git@github.com: rewrite is added once across two runs" "$expected_once" "$actual_once"

# ── 8 · a pubspec with no git@github.com: dependency adds no rewrite ──
git config --global --unset-all url."https://github.com/".insteadOf
dir=$(project nossh)
bash "$HOOK" "$dir" >/dev/null 2>&1
expected_none="0"
actual_none=$(rewrites)
check "a pubspec without git@github.com: adds no rewrite" "$expected_none" "$actual_none"

# ── 9 · pub get always runs; build_runner only when the pubspec names it ──
rm -f "$WORK/calls.log"
bash "$HOOK" "$dir" >/dev/null 2>&1
echo '  build_runner: any' >>"$dir/pubspec.yaml"
bash "$HOOK" "$dir" >/dev/null 2>&1
expected_calls="flutter pub get|flutter pub get|dart run build_runner build --delete-conflicting-outputs"
actual_calls=$(paste -sd'|' "$WORK/calls.log")
check "build_runner runs only when the pubspec names it" "$expected_calls" "$actual_calls"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
