#!/usr/bin/env bash
# argonath-detect.sh — resolve the lint/format/build/test commands for the current repo.
#
# Inspects manifests at the repo root to choose a stack default, then deep-merges
# any overrides from `.skadi/argonath.yaml` (top-level keys: lint, format, build,
# test, test_scope). A step with no resolved command is rendered as "skipped" later;
# this hook simply emits an empty string for it.
#
# Output: single-line JSON
#   { "stack": string, "lint": string, "format": string, "build": string,
#     "test": string, "test_scope": "full"|"changed",
#     "source": "default"|"override"|"merged" }
#
# YAML override is read with `yq` if present; falls back to a tolerant grep
# parser handling `key: value` lines (no nesting, no lists). Comments stripped.
set -u

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  jq -nc '{stack:"unknown",lint:"",format:"",build:"",test:"",test_scope:"full",source:"default"}'
  exit 0
fi
# A root git named but that cannot be entered is a broken repo, not a missing
# one: carrying on would detect the stack against whatever tree the caller
# stood in and report it as this repo's. Keep the JSON contract so the caller
# can still parse a reply, but exit non-zero — the branch above returns the
# same shape with status 0, and the two must not read alike.
if ! cd "$REPO_ROOT"; then
  jq -nc '{stack:"unknown",lint:"",format:"",build:"",test:"",test_scope:"full",source:"default"}'
  exit 1
fi

stack="unknown"
lint=""
format=""
build=""
test_cmd=""

if [ -f "pubspec.yaml" ]; then
  stack="flutter"
  if [ -d ".fvm" ] || [ -f ".fvmrc" ]; then
    lint="fvm flutter analyze"
    format="fvm dart format --output=none --set-exit-if-changed ."
    build="fvm flutter build apk --debug"
    test_cmd="fvm flutter test"
  else
    lint="flutter analyze"
    format="dart format --output=none --set-exit-if-changed ."
    build="flutter build apk --debug"
    test_cmd="flutter test"
  fi
elif [ -f "package.json" ]; then
  stack="node"
  has_script() { jq -e --arg s "$1" '.scripts[$s] // empty' package.json >/dev/null 2>&1; }
  has_script lint      && lint="npm run lint"
  has_script typecheck && lint="${lint:+$lint && }npm run typecheck"
  has_script build     && build="npm run build"
  has_script test      && test_cmd="npm test"
elif [ -f "Cargo.toml" ]; then
  stack="rust"
  lint="cargo clippy --all-targets -- -D warnings"
  build="cargo build --release"
  test_cmd="cargo test"
elif [ -f "go.mod" ]; then
  stack="go"
  lint="go vet ./..."
  build="go build ./..."
  test_cmd="go test ./..."
elif [ -f "pyproject.toml" ] || [ -f "requirements.txt" ]; then
  stack="python"
  command -v ruff   >/dev/null 2>&1 && lint="ruff check"
  command -v pytest >/dev/null 2>&1 && test_cmd="pytest"
fi

test_scope="full"
source="default"

config=".skadi/argonath.yaml"
if [ -f "$config" ]; then
  source="override"
  read_yaml_key() {
    local key="$1"
    if command -v yq >/dev/null 2>&1; then
      yq -r ".${key} // \"\"" "$config" 2>/dev/null | sed 's/^null$//'
    else
      grep -E "^${key}:[[:space:]]*" "$config" 2>/dev/null \
        | head -1 \
        | sed -E "s/^${key}:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^[\"']//; s/[\"']$//"
    fi
  }
  override_lint="$(read_yaml_key lint)"
  override_format="$(read_yaml_key format)"
  override_build="$(read_yaml_key build)"
  override_test="$(read_yaml_key test)"
  override_scope="$(read_yaml_key test_scope)"

  if [ -n "$override_lint$override_format$override_build$override_test" ] && [ "$stack" != "unknown" ]; then
    source="merged"
  fi

  [ -n "$override_lint" ]   && lint="$override_lint"
  [ -n "$override_format" ] && format="$override_format"
  [ -n "$override_build" ]  && build="$override_build"
  [ -n "$override_test" ]   && test_cmd="$override_test"
  case "$override_scope" in
    full|changed) test_scope="$override_scope" ;;
  esac
fi

jq -nc \
  --arg stack  "$stack" \
  --arg lint   "$lint" \
  --arg format "$format" \
  --arg build  "$build" \
  --arg test   "$test_cmd" \
  --arg scope  "$test_scope" \
  --arg source "$source" \
  '{stack:$stack,lint:$lint,format:$format,build:$build,test:$test,test_scope:$scope,source:$source}'
