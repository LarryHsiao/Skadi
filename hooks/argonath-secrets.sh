#!/usr/bin/env bash
# argonath-secrets.sh — scan for secrets in either the branch's diff or the project tree.
#
# Default (no flag): `argonath-secrets.sh [<target>]` scans the added lines
# (those starting with `+`, ignoring `+++` headers) of the first range that
# applies:
#   1. `<merge-base target HEAD>..HEAD` — everything the branch brings to its
#      merge target, whether pushed or not. Used when <target> resolves and
#      HEAD has moved past it.
#   2. `@{upstream}..HEAD` — the range about to be pushed. Covers standing on
#      the target itself, and a missing or unresolvable <target>.
#   3. `<empty tree>..HEAD` — no baseline at all, so everything HEAD carries.
#      Wide, but never blind: an empty range would answer "clean" unread.
#
# `--project`: scans every tracked file in the repo for the same patterns.
# Untracked / `.gitignore`d paths stay out. Binary files are skipped.
#
# Output: single-line JSON
#   { "ok": bool, "count": int, "hits": [string], "note": string }
#
# Patterns covered (ERE):
#   - AWS access keys                                        AKIA[0-9A-Z]{16}
#   - GitHub PATs / OAuth / user / server / refresh tokens   gh[pousr]_[A-Za-z0-9]{36,}
#   - Slack tokens                                           xox[abprs]-…
#   - Stripe live/test secrets                               sk|pk_live|test_…
#   - PEM private keys                                       -----BEGIN … PRIVATE KEY-----
#   - K/V assignments with a non-trivial value               (API_KEY|TOKEN|…)=value
#
# Exit 0 when a scan ran — the caller reads `ok`. Exit 1 with `ok=false,count=0`
# when nothing could be scanned (root unenterable, `git diff` failed); the note
# says which. A repo with no commits, or a cwd outside any repo, exits 0 with
# a note saying so.
set -u

mode="diff"
if [ "${1:-}" = "--project" ]; then
  mode="project"
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  jq -nc '{ok:true,count:0,hits:[],note:"not a git repo"}'
  exit 0
fi
# A root that cannot be entered leaves nothing scanned. Reporting ok:true here
# would be the worst answer this hook can give: the caller reads it as "no
# secrets in the diff" when what happened is that no diff was ever read. An
# unverified tree and a verified clean one are different findings, and only one
# of them is safe to push on.
if ! cd "$REPO_ROOT"; then
  jq -nc '{ok:false,count:0,hits:[],note:"repo root could not be entered — nothing scanned"}'
  exit 1
fi

# The empty tree's id — a baseline that holds nothing, so diffing HEAD against
# it yields every line HEAD carries.
EMPTY_TREE="$(git hash-object -t tree /dev/null)"

# scan_range [<target>] — print the range to scan; see the header for the order.
scan_range() {
  local target="$1" base upstream
  if [ -n "$target" ] && git rev-parse --verify --quiet "$target" >/dev/null; then
    base="$(git merge-base "$target" HEAD 2>/dev/null || true)"
    if [ -n "$base" ] && [ "$base" != "$(git rev-parse HEAD)" ]; then
      echo "${base}..HEAD"
      return
    fi
  fi
  if upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
    echo "${upstream}..HEAD"
    return
  fi
  echo "${EMPTY_TREE}..HEAD"
}

re='AKIA[0-9A-Z]{16}'
re+='|gh[pousr]_[A-Za-z0-9]{36,}'
re+='|xox[abprs]-[A-Za-z0-9-]+'
re+='|(sk|pk)_(live|test)_[A-Za-z0-9]{20,}'
re+='|-----BEGIN [A-Z ]*PRIVATE KEY-----'
re+='|(API_KEY|API_TOKEN|SECRET|PASSWORD|TOKEN|PRIVATE_KEY)[[:space:]]*=[[:space:]]*["'"'"'`]?[A-Za-z0-9_./+=-]{12,}'

if [ "$mode" = "project" ]; then
  scope_note="project tree (tracked files)"
  hits="$(git ls-files -z 2>/dev/null \
    | xargs -0 grep -IEHni "$re" 2>/dev/null \
    || true)"
else
  # An unborn HEAD has no history to leak — say so, rather than let the diff
  # error below fall through to the same "clean" a real scan would earn.
  if ! git rev-parse --verify --quiet HEAD >/dev/null; then
    jq -nc '{ok:true,count:0,hits:[],note:"no commits yet — nothing to scan"}'
    exit 0
  fi
  range="$(scan_range "${1:-}")"
  scope_note="diff range: $range"
  # The diff is read whole before the grep, so its own failure is seen: an
  # unreadable range and a clean one are different findings (see the root guard).
  if ! diff_text="$(git diff -U0 "$range" 2>/dev/null)"; then
    jq -nc --arg note "git diff failed on $range — nothing scanned" \
      '{ok:false,count:0,hits:[],note:$note}'
    exit 1
  fi
  hits="$(printf '%s\n' "$diff_text" \
    | grep -E '^\+[^+]' \
    | grep -E -i "$re" \
    || true)"
fi

if [ -z "$hits" ]; then
  jq -nc --arg note "$scope_note" '{ok:true,count:0,hits:[],note:$note}'
  exit 0
fi

hits_json="$(printf '%s\n' "$hits" | jq -R -s 'split("\n") | map(select(length>0))')"
count="$(printf '%s' "$hits_json" | jq 'length')"

jq -nc --argjson hits "$hits_json" --arg note "$scope_note" --argjson count "$count" \
  '{ok:false,count:$count,hits:$hits,note:$note}'
