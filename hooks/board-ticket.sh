#!/bin/bash
# board-ticket.sh <ISSUE-KEY> [--active]
#
# Fetches a Jira issue and its subtasks, derives the AC rate from subtask
# completion (met = subtasks whose statusCategory is "done", or whose status
# name is listed in ac-done-statuses.json — the team's done-enough set), writes the
# channel file  ~/.skadi/board/ticket-<ISSUE-KEY>.json  that the situation
# board polls. Then regenerates channels.json — the manifest of every ticket
# channel present — so the page discovers new tickets without being told.
#
# --active marks this ticket the active one (the hero), and clears active on
# every other ticket channel so only one hero ever stands. Absent, active=false.
#
# Test seams (see board-ticket.test.sh): BOARD_DIR overrides the board folder,
# and BOARD_TICKET_ISSUE_FILE injects a pre-fetched issue JSON to skip the fetch.
#
# Creds resolve via secret.sh (Vaultwarden first, env fallback), same as the
# working/council Jira hooks. Jira REST v3. On failure, prints an error line
# and exits non-zero — the writer is an action, so it throws.

set -euo pipefail
export LC_ALL=C.UTF-8

BOARD_DIR="${BOARD_DIR:-$HOME/.skadi/board}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECRET="$HOME/.claude/hooks/secret.sh"

ISSUE_KEY="${1:-}"
ACTIVE="false"
[[ "${2:-}" == "--active" ]] && ACTIVE="true"

if [[ -z "$ISSUE_KEY" ]]; then
  echo "usage: board-ticket.sh <ISSUE-KEY> [--active]" >&2
  exit 1
fi

issue_file=$(mktemp)
trap 'rm -f "$issue_file"' EXIT

# Test seam: BOARD_TICKET_ISSUE_FILE injects a pre-fetched issue JSON, bypassing
# the live fetch and credentials so board-ticket.test.sh can exercise the shaping
# offline. Absent, the real Jira fetch runs.
if [[ -n "${BOARD_TICKET_ISSUE_FILE:-}" ]]; then
  cp "$BOARD_TICKET_ISSUE_FILE" "$issue_file"
  URL="https://example.atlassian.net"
else
  JIRA_URL="$("$SECRET" jira uri 2>/dev/null || true)"
  JIRA_EMAIL="$("$SECRET" jira username 2>/dev/null || true)"
  JIRA_TOKEN="$("$SECRET" jira password JIRA_API_TOKEN 2>/dev/null || true)"

  if [[ -z "$JIRA_URL" || -z "$JIRA_EMAIL" || -z "$JIRA_TOKEN" ]]; then
    echo "jira credentials missing (need uri, username, password from Vaultwarden item \"jira\" or env)" >&2
    exit 1
  fi

  URL="${JIRA_URL%/}"
  http=$(curl -sS -o "$issue_file" -w "%{http_code}" \
    -u "$JIRA_EMAIL:$JIRA_TOKEN" \
    -H "Accept: application/json" \
    "$URL/rest/api/3/issue/$ISSUE_KEY?fields=summary,status,issuetype,priority,subtasks")

  if [[ "$http" != 2* ]]; then
    echo "fetch issue failed for $ISSUE_KEY (http=$http)" >&2
    exit 1
  fi
fi

mkdir -p "$BOARD_DIR"
out_file="$BOARD_DIR/ticket-$ISSUE_KEY.json"

# The "done-enough" status names — the AC rate counts a subtask met when Jira's
# own statusCategory is "done" OR its status name is listed here. This mirrors
# the workflow's done-set (e.g. "5. UAT@DEMO") so the rate reads by the team's
# definition of done, not Jira's generic one. Absent or malformed, fall back to
# the strict category test alone.
DONE_STATUSES="$BOARD_DIR/ac-done-statuses.json"
DONE_JSON="[]"
if [[ -f "$DONE_STATUSES" ]] && jq -e 'type == "array"' "$DONE_STATUSES" >/dev/null 2>&1; then
  DONE_JSON="$(cat "$DONE_STATUSES")"
fi

# Shape the channel file. jq derives AC from subtask completion; the browse
# URL is composed from the Jira base; updated is stamped in UTC.
jq \
  --arg key "$ISSUE_KEY" \
  --arg base "$URL" \
  --arg active "$ACTIVE" \
  --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson doneNames "$DONE_JSON" \
  '
  .fields as $f
  | ($f.subtasks // []) as $subs
  | ($doneNames | map(select(type == "string") | ascii_downcase)) as $doneSet
  | ($subs | map(
        ((.fields.status.name // "") | ascii_downcase) as $sname
        | {
            id: .key,
            title: (.fields.summary // ""),
            status: ((.fields.status.name) // ""),
            done: (
              (((.fields.status.statusCategory.key) // "") == "done")
              or (($doneSet | index($sname)) != null)
            )
          }
    )) as $roster
  | ($roster | length) as $total
  | ($roster | map(select(.done)) | length) as $met
  | {
      channel: "ticket",
      id: $key,
      title: ($f.summary // ""),
      status: (($f.status.name) // ""),
      statusCategory: (($f.status.statusCategory.key) // ""),
      type: (($f.issuetype.name) // ""),
      priority: (($f.priority.name) // ""),
      blocked: (($f.status.name // "") | ascii_downcase | test("block")),
      ac: {
        met: $met,
        total: $total,
        pct: (if $total > 0 then (($met * 100 / $total) | floor) else null end)
      },
      subtasks: $roster,
      active: ($active == "true"),
      url: ($base + "/browse/" + $key),
      source: "jira",
      updated: $now
    }
  ' "$issue_file" > "$out_file"

# Exactly one hero: when this ticket is active, clear active on every other
# ticket channel, so the board never shows two active tickets at once.
if [[ "$ACTIVE" == "true" ]]; then
  python3 - "$BOARD_DIR" "$ISSUE_KEY" <<'PY'
import json, os, sys, glob
board, key = sys.argv[1], sys.argv[2]
current = "ticket-%s.json" % key
for path in glob.glob(os.path.join(board, "ticket-*.json")):
    if os.path.basename(path) == current:
        continue
    try:
        data = json.load(open(path, encoding="utf-8"))
    except (ValueError, OSError):
        continue
    if data.get("active"):
        data["active"] = False
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
PY
fi

# Regenerate the manifest over every channel present (tickets, growth, …).
python3 "$SCRIPT_DIR/board-manifest.py" "$BOARD_DIR"

echo "wrote $out_file"
