#!/bin/bash
# board-ticket.sh <ISSUE-KEY> [--active] [--tracker jira|youtrack]
#
# Fetches an issue and its subtasks from Jira (REST v3) or YouTrack (Bearer
# token), selected by --tracker (default jira), and derives the AC rate from
# subtask completion the same way for both (met = subtasks whose done signal
# fires — statusCategory "done" for Jira, a resolved timestamp for YouTrack —
# or whose status name is listed in ac-done-statuses.json — the team's
# done-enough set), writes the channel file
# ~/.skadi/board/ticket-<ISSUE-KEY>.json  that the situation board polls.
# Then regenerates channels.json — the manifest of every ticket channel
# present — so the page discovers new tickets without being told.
#
# --active marks this ticket the active one (the hero), and clears active on
# every other ticket channel so only one hero ever stands. Absent, active=false.
#
# Test seams (see board-ticket.test.sh): BOARD_DIR overrides the board folder,
# and BOARD_TICKET_ISSUE_FILE injects a pre-fetched issue JSON to skip the fetch.
#
# Creds resolve via secret.sh (Vaultwarden first, env fallback), same as the
# working/council Jira hooks. On failure, prints an error line and exits
# non-zero — the writer is an action, so it throws.

set -euo pipefail
export LC_ALL=C.UTF-8

BOARD_DIR="${BOARD_DIR:-$HOME/.skadi/board}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECRET="$HOME/.claude/hooks/secret.sh"

ISSUE_KEY=""
ACTIVE="false"
TRACKER="jira"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --active)  ACTIVE="true" ;;
    --tracker) TRACKER="${2:-}"; shift ;;
    -*)        echo "board-ticket: unknown flag $1" >&2; exit 1 ;;
    *)         ISSUE_KEY="$1" ;;
  esac
  shift
done

if [[ -z "$ISSUE_KEY" ]]; then
  echo "usage: board-ticket.sh <ISSUE-KEY> [--active] [--tracker jira|youtrack]" >&2
  exit 1
fi

issue_file=$(mktemp)   # raw tracker response
norm_file=$(mktemp)    # normalized intermediate
trap 'rm -f "$issue_file" "$norm_file"' EXIT

mkdir -p "$BOARD_DIR"
out_file="$BOARD_DIR/ticket-$ISSUE_KEY.json"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# The "done-enough" status names — a subtask counts met when the tracker's own
# done signal fires OR its status name is listed here. Absent/malformed, the
# name-set is empty and only the tracker's signal counts.
DONE_STATUSES="$BOARD_DIR/ac-done-statuses.json"
DONE_JSON="[]"
if [[ -f "$DONE_STATUSES" ]] && jq -e 'type == "array"' "$DONE_STATUSES" >/dev/null 2>&1; then
  DONE_JSON="$(cat "$DONE_STATUSES")"
fi

# ── Jira: fetch raw issue into $issue_file, set $BASE ──
fetch_jira() {
  BASE="https://example.atlassian.net"
  if [[ -n "${BOARD_TICKET_ISSUE_FILE:-}" ]]; then
    cp "$BOARD_TICKET_ISSUE_FILE" "$issue_file"
    return
  fi
  local jira_url jira_email jira_token http
  jira_url="$("$SECRET" jira uri 2>/dev/null || true)"
  jira_email="$("$SECRET" jira username 2>/dev/null || true)"
  jira_token="$("$SECRET" jira password JIRA_API_TOKEN 2>/dev/null || true)"
  if [[ -z "$jira_url" || -z "$jira_email" || -z "$jira_token" ]]; then
    echo "jira credentials missing (need uri, username, password from Vaultwarden item \"jira\" or env)" >&2
    exit 1
  fi
  BASE="${jira_url%/}"
  http=$(curl -sS -o "$issue_file" -w "%{http_code}" \
    -u "$jira_email:$jira_token" \
    -H "Accept: application/json" \
    "$BASE/rest/api/3/issue/$ISSUE_KEY?fields=summary,status,issuetype,priority,subtasks,description")
  if [[ "$http" != 2* ]]; then
    echo "fetch issue failed for $ISSUE_KEY (http=$http)" >&2
    exit 1
  fi
}

# ── Jira: raw issue -> normalized intermediate ──
normalize_jira() {
  jq --arg key "$ISSUE_KEY" --arg base "$BASE" --argjson doneNames "$DONE_JSON" '
    ($doneNames | map(select(type == "string") | ascii_downcase)) as $doneSet
    | .fields as $f
    | {
        id: $key,
        title: ($f.summary // ""),
        status: (($f.status.name) // ""),
        statusCategory: (($f.status.statusCategory.key) // ""),
        type: (($f.issuetype.name) // ""),
        priority: (($f.priority.name) // ""),
        url: ($base + "/browse/" + $key),
        source: "jira",
        descAc: (
          # A description checklist is an ADF taskList of taskItems; count them
          # at any depth. state == "DONE" is met. Feeds the AC bar only when the
          # ticket bears no subtasks — the shared shaper picks the source.
          [ ($f.description // {}) | .. | objects | select(.type? == "taskItem") ] as $items
          | { met: ($items | map(select(.attrs.state? == "DONE")) | length),
              total: ($items | length) }
        ),
        subtasks: (($f.subtasks // []) | map(
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
        ))
      }
  ' "$issue_file" > "$norm_file"
}

# ── YouTrack: fetch raw issue into $issue_file, set $BASE ──
fetch_youtrack() {
  BASE="https://youtrack.example.com"
  if [[ -n "${BOARD_TICKET_ISSUE_FILE:-}" ]]; then
    cp "$BOARD_TICKET_ISSUE_FILE" "$issue_file"
    return
  fi
  local yt_url yt_token http
  yt_url="$("$SECRET" youtrack uri 2>/dev/null || true)"
  yt_token="$("$SECRET" youtrack 2>/dev/null || true)"
  if [[ -z "$yt_url" || -z "$yt_token" ]]; then
    echo "youtrack credentials missing (need uri + token from Vaultwarden item \"youtrack\" or env)" >&2
    exit 1
  fi
  BASE="${yt_url%/}"
  local fields="idReadable,summary,description,resolved,customFields(name,value(name)),links(direction,linkType(name),issues(idReadable,summary,resolved,customFields(name,value(name))))"
  http=$(curl -sS -o "$issue_file" -w "%{http_code}" \
    -H "Authorization: Bearer $yt_token" \
    -H "Accept: application/json" \
    "$BASE/api/issues/$ISSUE_KEY?fields=$fields")
  if [[ "$http" != 2* ]]; then
    echo "fetch issue failed for $ISSUE_KEY (http=$http)" >&2
    exit 1
  fi
}

# ── YouTrack: raw issue -> normalized intermediate ──
normalize_youtrack() {
  jq --arg key "$ISSUE_KEY" --arg base "$BASE" --argjson doneNames "$DONE_JSON" '
    def cf($fields; $name): (($fields // []) | map(select(.name == $name)) | (.[0].value.name? // ""));
    def isdone($resolved; $state; $doneSet):
      (($resolved != null) or (($doneSet | index(($state // "") | ascii_downcase)) != null));
    ($doneNames | map(select(type == "string") | ascii_downcase)) as $doneSet
    | {
        id: (.idReadable // $key),
        title: (.summary // ""),
        status: (cf(.customFields; "State")),
        statusCategory: (if .resolved != null then "done" else "" end),
        type: (cf(.customFields; "Type")),
        priority: (cf(.customFields; "Priority")),
        url: ($base + "/issue/" + $key),
        source: "youtrack",
        descAc: (
          # A YouTrack description is markdown; its checklist is "- [ ]" / "- [x]"
          # lines. Feeds the AC bar only when the ticket bears no subtasks.
          [ (.description // "") | split("\n")[]
            | select(test("^[[:space:]]*[-*+][[:space:]]+\\[[ xX]\\]")) ] as $lines
          | { met: ($lines | map(select(test("\\[[xX]\\]"))) | length),
              total: ($lines | length) }
        ),
        subtasks: (
          (.links // [])
          | map(select((.linkType.name == "Subtask") and (.direction == "OUTWARD")))
          | (map(.issues // []) | add // [])
          | map(
              (cf(.customFields; "State")) as $sstate
              | {
                  id: (.idReadable // ""),
                  title: (.summary // ""),
                  status: $sstate,
                  done: isdone(.resolved; $sstate; $doneSet)
                }
            )
        )
      }
  ' "$issue_file" > "$norm_file"
}

case "$TRACKER" in
  jira)     fetch_jira;     normalize_jira ;;
  youtrack) fetch_youtrack; normalize_youtrack ;;
  *)        echo "board-ticket: unknown tracker \"$TRACKER\"" >&2; exit 1 ;;
esac

# ── Shared shaper: normalized intermediate -> channel ──
jq --arg active "$ACTIVE" --arg now "$NOW" '
  . as $n
  | ($n.subtasks) as $roster
  | ($roster | length) as $subTotal
  | ($roster | map(select(.done)) | length) as $subMet
  # Subtasks are the AC roster where they exist; a ticket without them falls to
  # the description checklist; a ticket with neither has no AC to show.
  | (if $subTotal > 0
       then {met: $subMet, total: $subTotal, source: "subtasks"}
     elif (($n.descAc.total) // 0) > 0
       then {met: $n.descAc.met, total: $n.descAc.total, source: "description"}
     else {met: 0, total: 0, source: "none"} end) as $acc
  | {
      channel: "ticket",
      id: $n.id,
      title: $n.title,
      status: $n.status,
      statusCategory: $n.statusCategory,
      type: $n.type,
      priority: $n.priority,
      blocked: (($n.status // "") | ascii_downcase | test("block")),
      ac: {
        met: $acc.met,
        total: $acc.total,
        pct: (if $acc.total > 0 then (($acc.met * 100 / $acc.total) | floor) else null end),
        source: $acc.source
      },
      subtasks: $roster,
      active: ($active == "true"),
      url: $n.url,
      source: $n.source,
      updated: $now
    }
' "$norm_file" > "$out_file"

# Exactly one hero: when this ticket is active, clear active on every other
# ticket channel, so the board never shows two active tickets at once. The flip
# is single-homed in board-active.py, shared with the page's click endpoint.
if [[ "$ACTIVE" == "true" ]]; then
  python3 "$SCRIPT_DIR/board-active.py" "$BOARD_DIR" "$ISSUE_KEY"
fi

# Regenerate the manifest over every channel present (tickets, growth, …).
python3 "$SCRIPT_DIR/board-manifest.py" "$BOARD_DIR"

echo "wrote $out_file"
