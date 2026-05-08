#!/usr/bin/env bash
# argonath-detect.sh — resolve the lint/build/test commands for the current repo.
#
# Inspects manifests at the repo root to choose a stack default, then deep-merges
# any overrides from `.skadi/argonath.yaml` (top-level keys: lint, build, test,
# test_scope). A step with no resolved command is rendered as "skipped" later;
# this hook simply emits an empty string for it.
#
# Output: single-line JSON
#   { "stack": string, "lint": string, "build": string, "test": string,
#     "test_scope": "full"|"changed", "source": "default"|"override"|"merged" }
#
# YAML override is read with `yq` if present; falls back to a tolerant grep
# parser handling `key: value` lines (no nesting, no lists). Comments stripped.
set -u

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  jq -nc '{stack:"unknown",lint:"",build:"",test:"",test_scope:"full",source:"default"}'
  exit 0
fi
cd "$REPO_ROOT"

stack="unknown"
lint=""
build=""
test_cmd=""

if [ -f "pubspec.yaml" ]; then
  stack="flutter"
  if [ -d ".fvm" ] || [ -f ".fvmrc" ]; then
    lint="fvm flutter analyze"
    build="fvm flutter build apk --debug"
    test_cmd="fvm flutter test"
  else
    lint="flutter analyze"
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
  override_build="$(read_yaml_key build)"
  override_test="$(read_yaml_key test)"
  override_scope="$(read_yaml_key test_scope)"

  if [ -n "$override_lint$override_build$override_test" ] && [ "$stack" != "unknown" ]; then
    source="merged"
  fi

  [ -n "$override_lint" ]  && lint="$override_lint"
  [ -n "$override_build" ] && build="$override_build"
  [ -n "$override_test" ]  && test_cmd="$override_test"
  case "$override_scope" in
    full|changed) test_scope="$override_scope" ;;
  esac
fi

jq -nc \
  --arg stack "$stack" \
  --arg lint  "$lint" \
  --arg build "$build" \
  --arg test  "$test_cmd" \
  --arg scope "$test_scope" \
  --arg source "$source" \
  '{stack:$stack,lint:$lint,build:$build,test:$test,test_scope:$scope,source:$source}'
