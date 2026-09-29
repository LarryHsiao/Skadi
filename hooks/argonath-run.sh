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
# Secret placeholders: an argument may carry `{{NAME}}`. NAME is looked up in
# the repo's `test_env.md` in Skadi state (`skadi-state.sh path … test_env.md`),
# one `NAME=secret:<item>:<field>` line per secret, and resolved through
# secret.sh. The real value reaches only the command's own argv: the recorded
# `command` keeps the placeholder, and the value is masked as `***` in the log.
# An undeclared name, a missing file, or a secret the vault cannot give fails
# the step before the command runs — a credential-gated suite run without its
# credentials fails every test, and reads as a broken suite, not a missing key.
#
# Exits 0 always. Caller decides verdict from `ok`.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PLACEHOLDER='\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}'

step="${1:-}"
shift || true

if [ -z "$step" ] || [ "$#" -eq 0 ]; then
  jq -nc --arg step "$step" \
    '{step:$step,ok:false,command:"",summary:"argonath-run: no command given",log:"",exit:2}'
  exit 0
fi

cmd_str="$*"

# Print a failed row for a step that never ran, then stop.
refuse() { # summary
  jq -nc --arg step "$step" --arg cmd "$cmd_str" --arg summary "$1" \
    '{step:$step,ok:false,command:$cmd,summary:$summary,log:"",exit:2}'
  exit 0
}

# The `<item>:<field>` reference test_env.md declares for NAME, or nothing.
secret_ref() { # env_file name
  [ -f "$1" ] || return 0
  grep -E "^$2=secret:" "$1" | head -1 | sed -E "s/^$2=secret://" | tr -d '\r'
}

# Resolve NAME into `resolved`, refusing the step when it cannot. Runs in the
# main shell, not a $(…) subshell, so a refusal ends the script.
resolve_secret() { # name
  local ref item field
  [ -n "$env_file" ] || env_file="$("$HERE/skadi-state.sh" path "${SKADI_PROFILE:-default}" "$PWD" test_env.md)"
  ref="$(secret_ref "$env_file" "$1")"
  [ -n "$ref" ] || refuse "test_env.md does not declare $1 — add it at $env_file"
  item="${ref%%:*}"
  field="${ref#*:}"
  resolved="$("$HERE/secret.sh" "$item" "$field" 2>/dev/null)" || resolved=""
  [ -n "$resolved" ] || refuse "secret unresolved for $1 ($item $field)"
}

# Swap every {{NAME}} in the arguments for its value, into run_args.
env_file=""
run_args=()
secret_values=()
for arg in "$@"; do
  while [[ "$arg" =~ $PLACEHOLDER ]]; do
    name="${BASH_REMATCH[1]}"
    resolve_secret "$name"
    secret_values+=("$resolved")
    arg="${arg//"{{$name}}"/"$resolved"}"
  done
  run_args+=("$arg")
done

log_file="$(mktemp -t "argonath-${step// /_}.XXXXXX")"

# Mask each resolved secret in the log, so no value outlives the run on disk.
mask_secrets() {
  [ "${#secret_values[@]}" -gt 0 ] || return 0
  local content v
  content="$(<"$log_file")"
  for v in "${secret_values[@]}"; do content="${content//"$v"/"***"}"; done
  printf '%s\n' "$content" > "$log_file"
}

# Run the command, capturing stdout+stderr together.
if "${run_args[@]}" >"$log_file" 2>&1; then
  exit_code=0
  ok=true
else
  exit_code=$?
  ok=false
fi
mask_secrets

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
