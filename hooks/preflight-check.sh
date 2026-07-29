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

# --- daily ---
daily_state="$HOME/.claude/.daily-last-run"
today=$(date +%Y-%m-%d)
if [ -f "$daily_state" ]; then
  last=$(cat "$daily_state" 2>/dev/null || echo "")
  if [[ "$last" =~ ^[0-9]+$ ]]; then
    last_date=$(date -r "$last" +%Y-%m-%d 2>/dev/null || echo "")
    if [ "$last_date" = "$today" ]; then
      echo "daily|done today|last run ${last_date}|"
    else
      echo "daily|not run today|last run ${last_date}|warn"
    fi
  else
    echo "daily|unreadable|state file corrupt|warn"
  fi
else
  echo "daily|never|no record|warn"
fi

# --- triage ---
triage_state="$HOME/.claude/.triage-last-run"
if [ -f "$triage_state" ]; then
  last=$(cat "$triage_state" 2>/dev/null || echo "")
  if [[ "$last" =~ ^[0-9]+$ ]]; then
    last_date=$(date -r "$last" +%Y-%m-%d 2>/dev/null || echo "")
    if [ "$last_date" = "$today" ]; then
      echo "triage|done today|last run ${last_date}|"
    else
      echo "triage|not run today|last run ${last_date}|warn"
    fi
  else
    echo "triage|unreadable|state file corrupt|warn"
  fi
else
  echo "triage|never|no record|warn"
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

# --- haldir ---
haldir_repos_file="$HOME/.skadi/repo-watch/repos.md"
haldir_repos=()
while IFS= read -r line; do
  haldir_repos+=("$line")
done < <(grep -oE '^- (/.*)$' "$haldir_repos_file" 2>/dev/null | sed 's/^- //')

if [ "${#haldir_repos[@]}" -eq 0 ]; then
  haldir_repos=("$HOME/skadi")
fi

haldir_agents_json="$(claude agents --json 2>/dev/null || echo '[]')"
haldir_missing=()
for haldir_repo in "${haldir_repos[@]}"; do
  haldir_name=$(basename "$haldir_repo")
  haldir_running=$(printf '%s\n' "$haldir_agents_json" | jq -r --arg n "$haldir_name" '[.[] | select(.kind == "background" and .name == $n)] | length')
  [ "$haldir_running" -eq 0 ] && haldir_missing+=("$haldir_name")
done

if [ "${#haldir_missing[@]}" -gt 0 ]; then
  haldir_missing_str=$(IFS=,; echo "${haldir_missing[*]}")
  echo "haldir|${#haldir_missing[@]}/${#haldir_repos[@]} down|missing session(s): ${haldir_missing_str}|warn"
else
  echo "haldir|${#haldir_repos[@]}/${#haldir_repos[@]} running|all watched repos have an active session|"
fi

# --- palantir ---
palantir_prs_check="$HOME/.claude/hooks/prs-check.sh"
palantir_prs_act="$HOME/.claude/hooks/prs-activity.sh"
palantir_mrs_check="$HOME/.claude/hooks/mrs-check.sh"
palantir_mrs_act="$HOME/.claude/hooks/mrs-activity.sh"

if [ -x "$palantir_prs_act" ] && [ -x "$palantir_mrs_act" ]; then
  p_prs_check_out="$("$palantir_prs_check" 2>/dev/null || true)"
  p_prs_act_out="$("$palantir_prs_act" 2>/dev/null || true)"
  p_mrs_check_out="$("$palantir_mrs_check" 2>/dev/null || true)"
  p_mrs_act_out="$("$palantir_mrs_act" 2>/dev/null || true)"

  palantir_flagged=0

  if [ -n "$p_prs_check_out" ] && [ -n "$p_prs_act_out" ]; then
    while IFS='|' read -r _ p_repo p_num _; do
      [ -z "${p_repo:-}" ] && continue
      if printf '%s\n' "$p_prs_act_out" | grep -Fxq "$p_repo|$p_num"; then
        palantir_flagged=$((palantir_flagged + 1))
      fi
    done <<< "$p_prs_check_out"
  fi

  if [ -n "$p_mrs_check_out" ] && [ -n "$p_mrs_act_out" ]; then
    while IFS='|' read -r _ p_proj p_iid _; do
      [ -z "${p_proj:-}" ] && continue
      if printf '%s\n' "$p_mrs_act_out" | grep -Fxq "$p_proj|$p_iid"; then
        palantir_flagged=$((palantir_flagged + 1))
      fi
    done <<< "$p_mrs_check_out"
  fi

  if [ "$palantir_flagged" -gt 0 ]; then
    echo "palantir|${palantir_flagged} flagged|new comments on your PRs/MRs|warn"
  else
    echo "palantir|clear|no new comments to chase|"
  fi
fi
