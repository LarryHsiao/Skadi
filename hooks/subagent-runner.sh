#!/usr/bin/env bash
# The profile's external subagent runner — the CLI a Claude session hands
# delegated work to instead of spawning an Agent-tool subagent. Read from
# ~/.skadi/profiles/<profile>/subagent-runner.md, the profile taken from
# SKADI_PROFILE (the installer stamps it into each root's settings.json), so
# a work profile may run on Codex while the personal one keeps to the Agent
# tool. Absent means never asked, `none` means asked and declined.
#
#   show          print the file, or `unset` when it does not exist
#   init          seed the file from a runner found on PATH; write nothing
#                 (and say so) when none is found; never overwrite
#   init --none   record that this profile has no runner, so no session asks
#
# Known runners live in write_runner. Adding one is one case line: the
# command template (prompt on stdin, `{model}` for the slug) and the tier
# slugs from docs/workflow/delegation.md's roster.

set -euo pipefail

FILE="$HOME/.skadi/profiles/${SKADI_PROFILE:-default}/subagent-runner.md"

write_runner() {
  case "$1" in
    codex)
      cat > "$FILE" <<'RUNNER'
codex exec --sandbox workspace-write -m {model} -
mechanical=gpt-5.6-luna
default=gpt-5.6-terra
strong=gpt-5.6-sol
RUNNER
      ;;
    none)
      printf 'none\n' > "$FILE"
      ;;
    *)
      echo "subagent-runner: unknown runner $1" >&2
      exit 2
      ;;
  esac
}

detect_runner() {
  if command -v codex >/dev/null 2>&1; then echo codex; fi
}

show() {
  if [ -f "$FILE" ]; then cat "$FILE"; else echo unset; fi
}

init() {
  if [ -f "$FILE" ]; then
    echo kept
    return
  fi
  local runner
  if [ "${1:-}" = "--none" ]; then
    runner=none
  else
    runner="$(detect_runner)"
  fi
  if [ -z "$runner" ]; then
    echo "no runner found" >&2
    return
  fi
  mkdir -p "$(dirname "$FILE")"
  write_runner "$runner"
  echo "runner:         $runner -> $FILE"
}

case "${1:-}" in
  show) show ;;
  init) shift; init "$@" ;;
  *)
    echo "usage: $0 show | init [--none]" >&2
    exit 2
    ;;
esac
