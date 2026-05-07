#!/bin/bash
# Usage: outlook-classify.sh <from> <subject> [account]
# Reads ~/.skadi/outlook[/<account>]/classify.json and prints the user's
# override verdict for the given sender + subject: worth | routine | default.
#
# Schema (case-insensitive matching on both fields):
#   {
#     "demote_to_routine": [{"from": "<addr>", "subject": "<substr>"}, ...],
#     "promote_to_worth":  [{"from": "<addr>", "subject": "<substr>"}, ...]
#   }
#
# - `from` is required and matched case-insensitively, exact equality.
# - `subject` is optional; when present, the rule matches if the message subject
#   contains that substring (case-insensitive). When omitted, the rule matches
#   any subject from that sender.
# - Promote wins over demote when both match.
# - account names the per-account rules dir; empty falls back to the legacy
#   flat path (single-account compat).

set -u

FROM="${1:-}"
SUBJECT="${2:-}"
ACCOUNT="${3:-}"

if [[ -n "$ACCOUNT" ]]; then
  RULES_FILE="$HOME/.skadi/outlook/$ACCOUNT/classify.json"
else
  RULES_FILE="$HOME/.skadi/outlook/classify.json"
fi

if [[ -z "$FROM" ]]; then
  echo "outlook-classify: from address required (arg 1)" >&2
  exit 1
fi

if [[ ! -f "$RULES_FILE" ]]; then
  echo "default"
  exit 0
fi

jq -r \
  --arg from "$FROM" \
  --arg subject "$SUBJECT" \
  '
  def m(rules):
    rules // []
    | any(
        ((.from // "") | ascii_downcase) == ($from | ascii_downcase)
        and (
          ((.subject // "") | ascii_downcase) as $rs
          | $rs == "" or (($subject | ascii_downcase) | contains($rs))
        )
      );
  if m(.promote_to_worth) then "worth"
  elif m(.demote_to_routine) then "routine"
  else "default" end
  ' "$RULES_FILE"
