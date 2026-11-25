#!/bin/bash
# board-attention.sh <surface> [--clear] [--from-json <file>]
#
# Writes one attention-<surface>.json channel — "what awaits me" outside the
# curated ticket set: open GitLab MRs, open GitHub PRs, Jira tickets that moved
# or name you in the last day, and (via a separate model-fed path) unread mail. Modeled on
# board-sweep.sh's shape — one channel type, many files — so a partial failure
# in one surface can never clobber another's channel.
#
#   mrs   — glab merge requests you're reviewing or authored, via mrs-check.sh
#   prs   — GitHub PRs you're reviewing or authored, via prs-check.sh
#   jira  — tickets assigned to you or naming you that someone else touched in the
#           last 24 hours, via halbarad-jira.sh's read-only `window` verb (it
#           never moves /halbarad's cursor); the channel lists the top five
#   mail  — written only by --from-json (see below); no fetch path here, the
#           Outlook connector needs a model in the loop
#
# --clear removes the surface's channel and regenerates the manifest — the
# guard against a stale channel outliving a source that has gone dark (a dead
# mail connector most of all): unlink and re-manifest, idempotent.
#
# A FAILED FETCH IS A SUCCESSFUL WRITE. Auth failure, a dead token, a network
# miss — none of these are grounds to skip the write or exit non-zero. Each
# writes count:null / verdict:"unknown" and exits 0, so `board.sh refresh`'s
# `|| echo "… (skipped)"` guard never fires for a fetch failure — only for a
# write that genuinely could not happen (bad args, unwritable dir). Silently
# keeping yesterday's count would be the one lie this file exists to avoid.
#
# Test seam: BOARD_ATTENTION_FIXTURE_DIR points at a folder holding
# <surface>.out / <surface>.rc pairs, so the real fetch+parse runs offline —
# same shape as board-ticket.sh's BOARD_TICKET_ISSUE_FILE.

set -euo pipefail
export LC_ALL=C.UTF-8

BOARD_DIR="${BOARD_DIR:-$HOME/.skadi/board}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECRET="$HOME/.claude/hooks/secret.sh"

# mrs-check.sh (per_page) and prs-check.sh (--limit) each cap a single fetch
# at this many results per category —
# a count sitting exactly on the cap may be hiding more, so it's reported as
# such rather than read as an exact number.
ATTENTION_PAGE_CAP=50

surface="${1:-}"
[[ $# -gt 0 ]] && shift
clear_flag=""
from_json=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clear) clear_flag=1 ;;
    --from-json)
      if [[ $# -lt 2 ]]; then
        echo "board-attention: --from-json needs a file argument" >&2
        exit 1
      fi
      from_json="$2"
      shift
      ;;
    *) echo "board-attention: unknown arg \"$1\"" >&2; exit 1 ;;
  esac
  shift
done

usage() {
  echo "usage: board-attention.sh <mrs|prs|jira> [--clear] | board-attention.sh mail [--clear | --from-json <file>]" >&2
}

case "$surface" in
  mrs|prs|jira|mail) ;;
  "") usage; exit 1 ;;
  *) echo "board-attention: unknown surface \"$surface\"" >&2; exit 1 ;;
esac

if [[ -n "$clear_flag" ]]; then
  mkdir -p "$BOARD_DIR"
  rm -f "$BOARD_DIR/attention-$surface.json"
  python3 "$SCRIPT_DIR/board-manifest.py" "$BOARD_DIR"
  echo "cleared attention-$surface"
  exit 0
fi

# scheme://authority from a URL, or "" when it doesn't parse as one. Takes the
# host from the payload rather than a hardcoded gitlab.com/github.com, since
# mrs-check.sh resolves GITLAB_HOST at runtime and a self-hosted instance would
# otherwise get the wrong door.
url_host() {
  [[ "$1" =~ ^(https?://[^/]+) ]] && printf '%s' "${BASH_REMATCH[1]}" || printf ''
}

# https-only, and none of the characters that would break out of href="…" —
# the page's esc() escapes & < > but not the double quote (board-index.html).
# Matters most for a door built from payload data, not a literal.
validate_url() {
  case "$1" in
    https://*)
      case "$1" in
        *'"'*|*"'"*|*'<'*|*'>'*|*[[:space:]]*) printf '' ;;
        *) printf '%s' "$1" ;;
      esac
      ;;
    *) printf '' ;;
  esac
}

url_encode() { jq -rn --arg s "$1" '$s | @uri'; }

# ── shared: tally a mrs-check.sh / prs-check.sh line stream ──
# Both emit "category|repo|number|title|url|isDraft|pipeline" — same shape,
# different tools. Sets f_count, f_detail, f_first_url.
tally_forge() {
  local review=0 mine=0 failed=0
  f_first_url=""
  while IFS='|' read -r cat _repo _num _title url _draft status; do
    [[ -z "$cat" ]] && continue
    [[ -z "$f_first_url" ]] && f_first_url="$url"
    case "$cat" in
      review) review=$((review + 1)) ;;
      mine)   mine=$((mine + 1)) ;;
    esac
    [[ "$status" == "failed" ]] && failed=$((failed + 1))
  done <<<"$out"
  f_count=$((review + mine))
  local parts=()
  [[ $review -gt 0 ]] && parts+=("$review to review")
  [[ $mine -gt 0 ]] && parts+=("$mine mine")
  [[ $failed -gt 0 ]] && parts+=("$failed CI failed")
  f_detail=""
  # `+` guards the empty case: bash 3.2 (macOS /bin/bash) calls a bare
  # "${parts[@]}" an unbound variable under `set -u` when nothing was found.
  for p in ${parts[@]+"${parts[@]}"}; do
    if [[ -z "$f_detail" ]]; then f_detail="$p"; else f_detail="$f_detail · $p"; fi
  done
  if [[ -z "$f_detail" ]]; then f_detail="—"; fi
  # Each category is fetched separately and capped on its own — a category
  # sitting exactly on the cap may be hiding more of itself.
  if [[ $review -eq $ATTENTION_PAGE_CAP || $mine -eq $ATTENTION_PAGE_CAP ]]; then
    f_detail="$f_detail (capped)"
  fi
  return 0
}

# ── shaper: write the channel, then regenerate the manifest ──
write_channel() {
  local surf="$1" label="$2" count="$3" detail="$4" verdict="$5" url="$6" source="$7" items="${8:-}"
  mkdir -p "$BOARD_DIR"
  python3 - "$BOARD_DIR" "$surf" "$label" "$count" "$detail" "$verdict" "$url" "$source" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$items" <<'PY'
import json, os, sys
board, surf, label, count, detail, verdict, url, source, now, items = sys.argv[1:11]
out = {
    "channel": "attention",
    "id": "attention-%s" % surf,
    "surface": surf,
    "label": label,
    "count": (int(count) if count not in ("", "null") else None),
    "detail": detail,
    "verdict": verdict,
    "url": (url or None),
    "source": source,
    "updated": now,
}
if items:
    out["items"] = json.loads(items)
with open(os.path.join(board, "attention-%s.json" % surf), "w", encoding="utf-8") as fh:
    json.dump(out, fh, ensure_ascii=False, indent=2)
PY
  python3 "$SCRIPT_DIR/board-manifest.py" "$BOARD_DIR"
}

# ── mrs: open GitLab merge requests via mrs-check.sh ──
fetch_mrs() {
  if [[ -n "${BOARD_ATTENTION_FIXTURE_DIR:-}" ]]; then
    out="$(cat "$BOARD_ATTENTION_FIXTURE_DIR/mrs.out" 2>/dev/null || true)"
    rc=0
    if [[ -f "$BOARD_ATTENTION_FIXTURE_DIR/mrs.rc" ]]; then
      rc="$(cat "$BOARD_ATTENTION_FIXTURE_DIR/mrs.rc")"
    fi
    return 0
  fi
  if out="$("$SCRIPT_DIR/mrs-check.sh" 2>/dev/null)"; then rc=0; else rc=$?; fi
}

# ── prs: open GitHub PRs via prs-check.sh ──
# Unlike mrs-check.sh, prs-check.sh never checks gh auth itself — an expired
# token yields empty output, indistinguishable from "nothing awaits". The
# pre-check here is what turns that into an honest "unknown" instead of a
# false "quiet".
fetch_prs() {
  if [[ -n "${BOARD_ATTENTION_FIXTURE_DIR:-}" ]]; then
    out="$(cat "$BOARD_ATTENTION_FIXTURE_DIR/prs.out" 2>/dev/null || true)"
    rc=0
    if [[ -f "$BOARD_ATTENTION_FIXTURE_DIR/prs.rc" ]]; then
      rc="$(cat "$BOARD_ATTENTION_FIXTURE_DIR/prs.rc")"
    fi
    return 0
  fi
  if ! gh auth status >/dev/null 2>&1; then
    out=""
    rc=1
    return 0
  fi
  if out="$("$SCRIPT_DIR/prs-check.sh" 2>/dev/null)"; then rc=0; else rc=$?; fi
}

# ── jira: tickets assigned to you or naming you, touched by someone else ──
# All statuses on purpose — this reports MOVEMENT, not outstanding work, so a
# ticket that reached Done in the last day is exactly what belongs here. Do
# not "fix" this into statusCategory != Done. The door's JQL is the wide net
# (assigned or mentioned, updated in the last day); the listed tickets are the
# narrower ones another person actually touched.
JIRA_JQL="updated >= -1d AND (assignee = currentUser() OR comment ~ currentUser()) ORDER BY updated DESC"
JIRA_WINDOW_HOURS=24

fetch_jira() {
  if [[ -n "${BOARD_ATTENTION_FIXTURE_DIR:-}" ]]; then
    out="$(cat "$BOARD_ATTENTION_FIXTURE_DIR/jira.out" 2>/dev/null || true)"
    rc=0
    if [[ -f "$BOARD_ATTENTION_FIXTURE_DIR/jira.rc" ]]; then
      rc="$(cat "$BOARD_ATTENTION_FIXTURE_DIR/jira.rc")"
    fi
    return 0
  fi
  # `window` is read-only: it moves no cursor and keeps no list, so a board
  # refresh can never take from what /halbarad has yet to report. Exit 2 (not
  # configured) and 4 (Jira failed) both land in rc and read as "unknown".
  if out="$("$SCRIPT_DIR/halbarad-jira.sh" window "$JIRA_WINDOW_HOURS" 2>/dev/null)"; then rc=0; else rc=$?; fi
}

case "$surface" in
  mrs)
    fetch_mrs
    if [[ "$rc" -ne 0 ]]; then
      write_channel mrs "GitLab MRs" "" "—" "unknown" "" "glab"
    else
      tally_forge
      door=""
      [[ -n "$f_first_url" ]] && door="$(validate_url "$(url_host "$f_first_url")/dashboard/merge_requests")"
      verdict="quiet"
      [[ "$f_count" -gt 0 ]] && verdict="stirred"
      write_channel mrs "GitLab MRs" "$f_count" "$f_detail" "$verdict" "$door" "glab"
    fi
    ;;
  prs)
    fetch_prs
    if [[ "$rc" -ne 0 ]]; then
      write_channel prs "GitHub PRs" "" "—" "unknown" "" "gh"
    else
      tally_forge
      door=""
      [[ -n "$f_first_url" ]] && door="$(validate_url "$(url_host "$f_first_url")/pulls")"
      verdict="quiet"
      [[ "$f_count" -gt 0 ]] && verdict="stirred"
      write_channel prs "GitHub PRs" "$f_count" "$f_detail" "$verdict" "$door" "gh"
    fi
    ;;
  jira)
    fetch_jira
    jira_base="$("$SECRET" jira uri 2>/dev/null || true)"
    door=""
    if [[ -n "$jira_base" ]]; then
      door="$(validate_url "${jira_base%/}/issues/?jql=$(url_encode "$JIRA_JQL")")"
    fi
    if [[ "$rc" -ne 0 ]] || ! shaped="$(printf '%s' "$out" | python3 "$SCRIPT_DIR/board-jira-items.py")"; then
      write_channel jira "Jira movement" "" "—" "unknown" "" "jira"
    else
      count="$(printf '%s' "$shaped" | jq -r '.count')"
      detail="$(printf '%s' "$shaped" | jq -r '.detail')"
      # An item's url reaches an href, so it passes the same https-only check as a door.
      items="$(printf '%s' "$shaped" | jq -c '.items')"
      checked="[]"
      while IFS= read -r url; do
        checked="$(printf '%s' "$checked" | jq -c --arg u "$(validate_url "$url")" '. + [$u]')"
      done < <(printf '%s' "$items" | jq -r '.[] | .url // ""')
      items="$(jq -nc --argjson i "$items" --argjson u "$checked" \
        '[range(0; $i | length) as $n | $i[$n] + {url: (if $u[$n] == "" then null else $u[$n] end)}]')"
      verdict="quiet"
      [[ "$count" -gt 0 ]] && verdict="stirred"
      write_channel jira "Jira movement" "$count" "$detail" "$verdict" "$door" "jira" "$items"
    fi
    ;;
  mail)
    # No fetch here — the Outlook connector needs a model in the loop. The
    # model runs the search itself (see SKILL.md), then hands the result in.
    if [[ -z "$from_json" ]]; then
      echo "board-attention: mail needs --from-json <file> (no fetch path)" >&2
      exit 1
    fi
    [[ -f "$from_json" ]] || { echo "board-attention: no such file $from_json" >&2; exit 1; }
    mail_count="$(jq -r '.count' "$from_json" 2>/dev/null || true)"
    if ! [[ "$mail_count" =~ ^[0-9]+$ ]]; then
      echo "board-attention: mail payload's .count must be a non-negative integer" >&2
      exit 1
    fi
    mail_detail="$(jq -r '.detail // "—"' "$from_json")"
    mail_url="$(validate_url "$(jq -r '.url // empty' "$from_json")")"
    verdict="quiet"
    [[ "$mail_count" -gt 0 ]] && verdict="stirred"
    write_channel mail "Unread mail" "$mail_count" "$mail_detail" "$verdict" "$mail_url" "outlook"
    ;;
esac

echo "wrote $BOARD_DIR/attention-$surface.json"
