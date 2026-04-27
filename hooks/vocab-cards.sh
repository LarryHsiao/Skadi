#!/bin/bash
# Emit every vocab card with its SRS state as TSV.
# Columns: word \t ease \t interval \t last_reviewed \t due_in_days
#   due_in_days < 0  → overdue (the magnitude is how late)
#   due_in_days == 0 → due today
#   due_in_days > 0  → not yet due
#
# Card files live under $VOCAB_DIR (default $HOME/.skadi/vocab) as
# <word>.md with YAML-ish frontmatter holding ease/interval/last_reviewed.

set -euo pipefail

VOCAB_DIR="${VOCAB_DIR:-$HOME/.skadi/vocab}"
mkdir -p "$VOCAB_DIR"

today_epoch=$(date +%s)
day=86400

shopt -s nullglob
for f in "$VOCAB_DIR"/*.md; do
    word=$(basename "$f" .md)

    ease=$(grep -m1 '^ease:' "$f" | awk '{print $2}')
    interval=$(grep -m1 '^interval:' "$f" | awk '{print $2}')
    last=$(grep -m1 '^last_reviewed:' "$f" | awk '{print $2}')

    [ -z "${ease:-}" ] && ease="2.5"
    [ -z "${interval:-}" ] && interval="1"
    [ -z "${last:-}" ] && last=$(date +%Y-%m-%d)

    # Parse last_reviewed (YYYY-MM-DD) → epoch. BSD date on darwin first,
    # GNU date as fallback for portability.
    last_epoch=$(date -j -f "%Y-%m-%d" "$last" "+%s" 2>/dev/null \
        || date -d "$last" "+%s" 2>/dev/null \
        || echo "$today_epoch")

    # Round interval to int for arithmetic (in case someone wrote a float).
    interval_int=${interval%.*}
    [ -z "$interval_int" ] && interval_int=1

    due_epoch=$(( last_epoch + interval_int * day ))
    due_in_days=$(( (due_epoch - today_epoch) / day ))

    printf '%s\t%s\t%s\t%s\t%s\n' "$word" "$ease" "$interval" "$last" "$due_in_days"
done
