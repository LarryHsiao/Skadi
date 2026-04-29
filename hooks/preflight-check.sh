#!/usr/bin/env bash
# Preflight check — reports periodic maintenance status.
# Output: pipe-delimited `check|status|detail|flag`
#   flag = `warn` when a row should be highlighted.

set -euo pipefail

now=$(date +%s)

# --- cleanup-dev ---
cleanup_state="$HOME/.claude/.cleanup-dev-last-run"
if [ -f "$cleanup_state" ]; then
  last=$(cat "$cleanup_state" 2>/dev/null || echo "")
  if [[ "$last" =~ ^[0-9]+$ ]]; then
    days=$(( (now - last) / 86400 ))
    date_str=$(date -r "$last" +%Y-%m-%d 2>/dev/null || echo "unknown")
    flag=""
    [ "$days" -gt 30 ] && flag="warn"
    echo "cleanup-dev|${days} days ago|last run ${date_str}|${flag}"
  else
    echo "cleanup-dev|unreadable|state file corrupt|warn"
  fi
else
  echo "cleanup-dev|never|no record|warn"
fi

# --- vocab ---
vocab_hook="$HOME/.claude/hooks/vocab-cards.sh"
if [ -x "$vocab_hook" ]; then
  vocab_total=0
  vocab_due=0
  vocab_oldest_overdue=0
  vocab_next_due=0
  vocab_next_seen=0
  while IFS=$'\t' read -r v_word v_ease v_interval v_last v_due_in; do
    [ -z "${v_word:-}" ] && continue
    vocab_total=$((vocab_total + 1))
    if [ "$v_due_in" -le 0 ]; then
      vocab_due=$((vocab_due + 1))
      if [ "$v_due_in" -lt "$vocab_oldest_overdue" ]; then
        vocab_oldest_overdue=$v_due_in
      fi
    else
      if [ "$vocab_next_seen" -eq 0 ] || [ "$v_due_in" -lt "$vocab_next_due" ]; then
        vocab_next_due=$v_due_in
        vocab_next_seen=1
      fi
    fi
  done < <("$vocab_hook" 2>/dev/null)

  if [ "$vocab_total" -eq 0 ]; then
    echo "vocab|empty|no cards yet — seed with /vocab <word>|"
  elif [ "$vocab_due" -gt 0 ]; then
    if [ "$vocab_oldest_overdue" -lt 0 ]; then
      v_detail="oldest overdue by $(( -vocab_oldest_overdue )) day(s)"
    else
      v_detail="due today"
    fi
    echo "vocab|${vocab_due} due|${v_detail}|warn"
  else
    echo "vocab|all caught up|next due in ${vocab_next_due} day(s)|"
  fi
fi

# --- nazgul-checks ---
nazgul_checks_dir=""
for candidate in \
    "$HOME/.claude/skills/nazgul/checks" \
    "$HOME/.claude-personal/skills/nazgul/checks" \
    "$HOME/.claude-work/skills/nazgul/checks"; do
  if [ -d "$candidate" ]; then
    nazgul_checks_dir="$candidate"
    break
  fi
done

if [ -n "$nazgul_checks_dir" ]; then
  nazgul_count=$(find "$nazgul_checks_dir" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
  nazgul_state="$HOME/.claude/.nazgul-checks-last-review"
  if [ -f "$nazgul_state" ]; then
    n_last=$(cat "$nazgul_state" 2>/dev/null || echo "")
    if [[ "$n_last" =~ ^[0-9]+$ ]]; then
      n_days=$(( (now - n_last) / 86400 ))
      n_date_str=$(date -r "$n_last" +%Y-%m-%d 2>/dev/null || echo "unknown")
      n_flag=""
      [ "$n_days" -gt 30 ] && n_flag="warn"
      echo "nazgul-checks|${n_days} days ago|${nazgul_count} rubric(s); last review ${n_date_str}|${n_flag}"
    else
      echo "nazgul-checks|unreadable|state file corrupt|warn"
    fi
  else
    echo "nazgul-checks|never|${nazgul_count} rubric(s); no review on record|warn"
  fi
fi
