#!/usr/bin/env bash
# argonath-run.sh — execute one named step of the pre-push analysis.
#
# Usage: argonath-run.sh <step-label> <command...>
#   step-label: short tag for the row in the report (e.g. "Lint", "Build", "Tests").
#               Used by the caller to identify the row.
#
# The command is invoked verbatim. stdout and stderr are captured, the exit code
# is read, and a short summary is extracted (the first non-empty failure-shaped
# line, or the count of "issue"-shaped tokens). The full output is written to a
# tempfile and its path is reported so the caller can read details on demand.
#
# Output: single-line JSON
#   { "step": string, "ok": bool, "command": string, "summary": string,
#     "log": string, "exit": int }
#
# Exits 0 always. Caller decides verdict from `ok`.
set -u

step="${1:-}"
shift || true

if [ -z "$step" ] || [ "$#" -eq 0 ]; then
  jq -nc --arg step "$step" \
    '{step:$step,ok:false,command:"",summary:"argonath-run: no command given",log:"",exit:2}'
  exit 0
fi

cmd_str="$*"

log_file="$(mktemp -t "argonath-${step// /_}.XXXXXX")"

# Run the command, capturing stdout+stderr together.
if "$@" >"$log_file" 2>&1; then
  exit_code=0
  ok=true
else
  exit_code=$?
  ok=false
fi

# Tail of the log used to derive a short summary line.
summary=""
if [ "$ok" = "true" ]; then
  summary="ok"
else
  summary="$(grep -m1 -E '^(error|FAILED|FAIL\b|✗|✖|×)' "$log_file" 2>/dev/null \
            | head -c 120 \
            | tr -d '\r' \
            | sed 's/[[:space:]]*$//')"
  if [ -z "$summary" ]; then
    summary="$(tail -n 3 "$log_file" 2>/dev/null \
              | grep -m1 -v '^[[:space:]]*$' \
              | head -c 120 \
              | tr -d '\r' \
              | sed 's/[[:space:]]*$//')"
  fi
  [ -z "$summary" ] && summary="exit ${exit_code}"
fi

jq -nc \
  --arg step    "$step" \
  --arg cmd     "$cmd_str" \
  --arg summary "$summary" \
  --arg log     "$log_file" \
  --argjson ok  "$ok" \
  --argjson exit "$exit_code" \
  '{step:$step,ok:$ok,command:$cmd,summary:$summary,log:$log,exit:$exit}'
