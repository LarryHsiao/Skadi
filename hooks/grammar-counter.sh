#!/bin/bash
# Stop hook: count grammar corrections in Claude's response and persist to log

INPUT=$(cat)
GRAMMAR_LOG="$HOME/.skadi/grammar_log"
TODAY=$(date +%Y-%m-%d)

mkdir -p "$HOME/.skadi"

# Reset if log is from a previous day
if [ -f "$GRAMMAR_LOG" ]; then
    last_date=$(head -1 "$GRAMMAR_LOG" | tr -d '\r\n ')
    if [ "$last_date" != "$TODAY" ]; then
        : > "$GRAMMAR_LOG"
    fi
fi

# Extract last assistant message from stop hook input
last_text=$(echo "$INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null | tr -d '\r')

# Count **Grammar:** occurrences (one per correction line)
count=$(echo "$last_text" | grep -c '> \*\*Grammar:\*\*' 2>/dev/null | tr -d '\r\n ')
count=${count:-0}

if [ "$count" -gt 0 ]; then
    for _ in $(seq 1 "$count"); do
        printf '%s\n' "$TODAY" >> "$GRAMMAR_LOG"
    done
fi

exit 0
