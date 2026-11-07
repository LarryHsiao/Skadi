#!/usr/bin/env bash
# amon-din-github.sh — recent GitHub Actions runs for one workflow.
# Read-only (`gh run list`).
#
# Usage:
#   amon-din-github.sh <owner/repo> <workflow> [<count>] [<branch>]
#     owner/repo — the repository (required)
#     workflow   — workflow file name or name, e.g. ci.yml (required)
#     count      — number of runs (default 3)
#     branch     — branch name (optional)
#
# Auth: whatever `gh auth status` already holds. No token is read here.
#
# Output (stdout): zero or more pipe-delimited lines
#   <number>|<status>|<branch>|<timestamp>|<url>
# where <status> is normalised to one of:
#   success | failed | running | queued | cancelled | unknown
#
# AMON_DIN_GITHUB_FIXTURE names a file holding a recorded `gh run list --json`
# body; when set, `gh` is not called. AMON_DIN_GITHUB_GH names a stand-in for
# the `gh` binary. Both exist for the offline test.
#
# Errors print to stderr and exit non-zero.

set -u

REPO="${1:-}"
WORKFLOW="${2:-}"
COUNT="${3:-3}"
BRANCH="${4:-}"

if [[ -z "$REPO" || -z "$WORKFLOW" ]]; then
  echo "usage: amon-din-github.sh <owner/repo> <workflow> [count] [branch]" >&2
  exit 1
fi

if [[ -n "${AMON_DIN_GITHUB_FIXTURE:-}" ]]; then
  resp=$(cat "$AMON_DIN_GITHUB_FIXTURE")
else
  GH="${AMON_DIN_GITHUB_GH:-gh}"
  if ! command -v "$GH" >/dev/null 2>&1; then
    echo "gh CLI not found on PATH" >&2
    exit 1
  fi
  args=(run list --repo "$REPO" --workflow "$WORKFLOW" --limit "$COUNT"
        --json "number,status,conclusion,headBranch,updatedAt,url")
  [[ -n "$BRANCH" ]] && args+=(--branch "$BRANCH")
  # stderr goes to its own file: a benign notice (an update banner, a warning)
  # on a successful call must not turn the JSON body into a parse failure.
  err_log=$(mktemp)
  trap 'rm -f "$err_log"' EXIT
  resp=$("$GH" "${args[@]}" 2>"$err_log") || {
    echo "gh run list failed for $REPO ($WORKFLOW): $(cat "$err_log")" >&2
    exit 1
  }
fi

# Anything but a JSON array means the request did not land.
case "$resp" in
  '['*) ;;
  *)
    echo "github returned a non-JSON response (likely auth or repo error):" >&2
    echo "$resp" | head -c 400 >&2
    echo >&2
    exit 1
    ;;
esac

printf '%s' "$resp" | jq -r '
  .[]
  | [
      (.number | tostring),
      (
        if   .status == "in_progress" then "running"
        elif (.status == "queued" or .status == "waiting"
              or .status == "pending" or .status == "requested") then "queued"
        elif .conclusion == "success" then "success"
        elif (.conclusion == "failure" or .conclusion == "timed_out"
              or .conclusion == "startup_failure") then "failed"
        elif (.conclusion == "cancelled" or .conclusion == "skipped"
              or .conclusion == "neutral" or .conclusion == "stale") then "cancelled"
        else "unknown"
        end
      ),
      (.headBranch // ""),
      (.updatedAt // ""),
      (.url // "")
    ]
  | @tsv
' | tr -d '\r' | tr '\t' '|'
