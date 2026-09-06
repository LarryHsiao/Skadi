#!/bin/bash
# PreToolUse hook (Bash, Write|Edit|MultiEdit|NotebookEdit):
# Notice when a session rooted OUTSIDE a protected repo reaches into it, and
# name the workflow that owns that repo along with the handoff channel to
# route the change through. It advises; it does not bar.
#
# The barring is dir-guard.sh's job (home/project bounds), and worktree-guard.sh
# covers same-repo cross-worktree. Neither carries the one thing this hook
# knows: which repo answers to which channel. A session opened at an ancestor
# of these repos, or one whose CLAUDE_DEV_DIRS admits them, has declared that
# scope on purpose — refusing it there would overrule the user's own explicit
# choice, so the note stands in place of the refusal.
#
# Protected repos come from a global flat file, NOT auto-memory — auto-memory
# is scoped per project directory and would be invisible to a session rooted
# elsewhere (the same problem /moria solved for mend_repos.md).

LIST="${PROTECTED_REPOS_FILE:-$HOME/.skadi/protected_repos.md}"
[ -f "$LIST" ] || exit 0

INPUT=$(cat)

normalize() {
  local p="$1"
  p="${p//\\//}"
  p="${p%/}"
  [ -z "$p" ] && p="/"
  if [[ "$p" =~ ^([A-Za-z]):(/.*) ]]; then
    p="/${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  fi
  if [[ "$p" =~ ^/mnt/([a-zA-Z])(/.*)$ ]]; then
    p="/${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  fi
  printf '%s\n' "$p" | tr '[:upper:]' '[:lower:]'
}

RAW_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
# Logical pwd (no -P): REPOS entries and the target file path below are never
# symlink-resolved (the target may not even exist yet), so PROJECT_DIR must
# stay in the same raw form or a symlinked tmp/dev dir (e.g. macOS's
# /var -> /private/var) silently breaks the self-edit comparison.
PROJECT_DIR=$(cd "$RAW_PROJECT_DIR" 2>/dev/null && pwd || echo "$RAW_PROJECT_DIR")
PROJECT_DIR=$(normalize "$PROJECT_DIR")

# Raw invoking-shell cwd (not CLAUDE_PROJECT_DIR — a session may have cd'd
# within its own project). Same logical-pwd reasoning as PROJECT_DIR above:
# plain pwd, no -P, to stay in the same unresolved namespace as REPOS.
CWD=$(cd "$PWD" 2>/dev/null && pwd || echo "$PWD")

REPOS=()
CHANNELS=()
while IFS= read -r line; do
  line="${line#- }"
  [ -z "$line" ] && continue
  case "$line" in
    *"→"*) ;;
    *) continue ;;
  esac
  repo="${line%%→*}"
  chan="${line#*→}"
  repo="$(printf '%s' "$repo" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  chan="$(printf '%s' "$chan" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -z "$repo" ] || [ -z "$chan" ] && continue
  REPOS+=("$(normalize "$repo")")
  CHANNELS+=("$chan")
done < "$LIST"

under() {
  case "$2" in
    "$1"|"$1"/*) return 0 ;;
  esac
  return 1
}

# Advise, do not bar. A session opened at an ancestor of these repos has
# declared that scope deliberately, and a guard that overrules its own user's
# explicit choice is friction, not safety. dir-guard remains the lock on the
# ordinary case — a session rooted in one repo still cannot reach another —
# so what is left for this hook is the knowledge dir-guard does not carry:
# which workflow owns this repo, and the channel to route a change through.
#
# No `permissionDecision` is emitted, deliberately. `allow` would auto-approve
# the write and bypass the normal permission prompt, which is stronger than
# not blocking; omitting the field leaves that flow exactly as it was and adds
# only the note. `additionalContext` is the documented field that reaches the
# model (`message`, which a sibling hook emits, is not one at all).
advise() {
  # The format string must be single-quoted — printf, not the shell, does the
  # substituting — and its backticks are literal text the reading model sees
  # as a code span, never command substitution. SC2016 reads them as an
  # expansion that will not expand; here that is exactly the intent.
  # shellcheck disable=SC2016
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"This path belongs to a repo owned by another workflow. Prefer `/handoff send %s <your change>` over editing it from here, so the owning session applies it under its own rules."}}' "$1"
  exit 0
}

check_path() {
  local target
  target=$(normalize "$1")
  local i=0
  while [ "$i" -lt "${#REPOS[@]}" ]; do
    local repo="${REPOS[$i]}" chan="${CHANNELS[$i]}"
    if under "$repo" "$target" && ! under "$repo" "$PROJECT_DIR"; then
      advise "$chan"
    fi
    i=$((i+1))
  done
}

FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
if [ -n "$FILE" ]; then
  check_path "$FILE"
  exit 0
fi

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
if [ -n "$CMD" ]; then
  TOKENS=$(python3 - "$CMD" 2>/dev/null <<'PYEOF'
import sys, shlex
try:
    for token in shlex.split(sys.argv[1]):
        print(token)
except ValueError:
    pass
PYEOF
)
  while IFS= read -r TOKEN; do
    # Strip a leading redirection operator (>, >>, <, <<, or an fd-prefixed
    # form like 2>, 2>>) glued to its target with no space -- e.g.
    # `echo x >../protected-repo/f.md` tokenizes via shlex as one token.
    # Without this, dirname on the glued string isn't a real directory and
    # resolution silently aborts, letting the write through unchecked. The
    # space-separated form (`echo x > ../protected-repo/f.md`) already
    # falls through to the classification below unchanged.
    if [[ "$TOKEN" =~ ^[0-9]*(\>{1,2}|\<{1,2}) ]]; then
      TOKEN="${TOKEN:${#BASH_REMATCH[0]}}"
    fi
    # Strip a leading `key=` or `--flag=`/`-f=` prefix glued to its path
    # value with no space -- e.g. `dd of=../protected-repo/f.md` or
    # `cp x --target-directory=../protected-repo`. Must run before the
    # flag-skip case arm below, or `--target-directory=...` gets skipped
    # outright as "just a flag" before its value is ever examined.
    if [[ "$TOKEN" =~ ^-{0,2}[A-Za-z_][A-Za-z0-9_.-]*= ]]; then
      TOKEN="${TOKEN:${#BASH_REMATCH[0]}}"
    fi
    case "$TOKEN" in
      --*|-*|"") continue ;;
    esac
    # Expand a literal leading ~ (not ~user/... forms, which stay
    # unhandled and skipped) the same narrow way dir-guard.sh's own
    # DEV_DIRS parsing does.
    # The quoted tildes below are case *patterns* matched against a token that
    # literally begins with "~"; expanding them would break the match. The
    # directive sits here rather than on the branch itself — shellcheck accepts
    # one only in front of a complete command, never inside a case body.
    # shellcheck disable=SC2088
    case "$TOKEN" in
      "~"|"~/"*) TOKEN="${TOKEN/#\~/$HOME}" ;;
      "~"*) continue ;;
    esac
    if [[ "$TOKEN" =~ ^/[a-zA-Z] ]] || [[ "$TOKEN" =~ ^[A-Za-z]:\\ ]]; then
      check_path "$TOKEN"
    else
      # Bare-relative, ./-relative, and ../-relative tokens all escape the
      # absolute-path check above (e.g. `cat skadi/CLAUDE.md`,
      # `cat ./skadi/CLAUDE.md`, `cat ../protected-repo/CLAUDE.md`) when a
      # protected repo is reachable as a descendant of the invoking shell's
      # actual cwd, expressed without a leading `/`. Resolve against CWD
      # (the invoking shell's actual cwd) and check the rejoined result too.
      # Known, accepted limitations (deliberately not chased further):
      # 1. If an intermediate directory in the resolved path doesn't exist
      #    yet on disk, cd fails and the token is silently skipped --
      #    dir-guard.sh's equivalent check carries the same limitation,
      #    unaddressed there too.
      # 2. A symlinked intermediate directory in a relative path (not CWD
      #    or PROJECT_DIR themselves, which are already handled correctly
      #    via logical pwd -- a symlink *between* cwd and the protected
      #    repo) can resolve to the symlink's own location rather than its
      #    target, missing a match. Contrived: needs a pre-existing symlink
      #    aimed into the protected tree.
      # 3. `~otheruser/...` forms stay unhandled (see the tilde-expand case
      #    arm above) -- only a literal leading `~` or `~/` is expanded,
      #    matching dir-guard.sh's own existing convention.
      RESOLVED_DIR=$(cd "$CWD" 2>/dev/null && cd "$(dirname "$TOKEN")" 2>/dev/null && pwd)
      if [ -n "$RESOLVED_DIR" ]; then
        check_path "$RESOLVED_DIR/$(basename "$TOKEN")"
      fi
    fi
  done <<< "$TOKENS"
fi

exit 0
