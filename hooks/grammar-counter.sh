#!/bin/bash
# Stop hook: count grammar corrections in Claude's response and persist to log

INPUT=$(cat)
GRAMMAR_LOG="$HOME/.claude/.grammar_log"
TODAY=$(date +%Y-%m-%d)

# Extract last assistant message text from transcript
last_text=$(echo "$INPUT" | jq -r '
  [ .transcript[]? | select(.role == "assistant") ] | last
  | if (.content | type) == "array"
    then [ .content[]? | select(.type == "text") | .text ] | join("\n")
    else .content // ""
    end
' 2>/dev/null | tr -d '\r')

# Count **Grammar:** occurrences (one per correction line)
count=$(echo "$last_text" | grep -c '> \*\*Grammar:\*\*' 2>/dev/null | tr -d '\r\n ')
count=${count:-0}

if [ "$count" -gt 0 ]; then
    for _ in $(seq 1 "$count"); do
        printf '%s\n' "$TODAY" >> "$GRAMMAR_LOG"
    done
fi

exit 0
