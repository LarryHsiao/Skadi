#!/bin/bash
# PreToolUse hook: Log cwd and block Bash commands or file-tool paths outside the project directory

# Capture stdin immediately (hook input JSON)
INPUT=$(cat)

# Canonical paths (resolve symlinks, normalize slashes)
CWD=$(cd "$PWD" 2>/dev/null && pwd -W 2>/dev/null || pwd -P 2>/dev/null || echo "$PWD")
HOME_DIR=$(cd "$HOME" 2>/dev/null && pwd -W 2>/dev/null || pwd -P 2>/dev/null || echo "$HOME")
PROJECT_DIR=$(cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -W 2>/dev/null || pwd -P 2>/dev/null || echo "$CLAUDE_PROJECT_DIR")
# TMPDIR_RAW keeps the unresolved form (e.g. macOS's /var/folders/... before
# its /private/var symlink is followed) — callers like skadi-worktree.sh build
# paths from $TMPDIR directly, without resolving through pwd -P, so both the
# raw and resolved forms must be admitted (mirrors the /tmp vs /private/tmp
# pair already handled below).
TMPDIR_RAW="${TMPDIR:-/tmp}"
TMPDIR_DIR=$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -W 2>/dev/null || pwd -P 2>/dev/null || echo "${TMPDIR:-/tmp}")

# Normalize: lowercase everything, forward slashes, strip trailing slash
normalize() {
  local p="$1"
  # Convert backslashes to forward slashes, strip trailing slash
  p="${p//\\//}"
  p="${p%/}"
  # Preserve root "/" (stripping trailing slash from "/" yields "")
  [ -z "$p" ] && p="/"
  # Convert C:/... to /c/...
  if [[ "$p" =~ ^([A-Za-z]):(/.*) ]]; then
    p="/${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  fi
  # Convert /mnt/c/... to /c/... (WSL/Git Bash on Windows)
  if [[ "$p" =~ ^/mnt/([a-zA-Z])(/.*)$ ]]; then
    p="/${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  fi
  # Lowercase everything for case-insensitive comparison on Windows.
  # Use tr, not ${p,,} — the latter is bash 4+ and macOS ships bash 3.2.
  printf '%s\n' "$p" | tr '[:upper:]' '[:lower:]'
}

CWD=$(normalize "$CWD")
HOME_DIR=$(normalize "$HOME_DIR")
PROJECT_DIR=$(normalize "$PROJECT_DIR")
TMPDIR_RAW=$(normalize "$TMPDIR_RAW")
TMPDIR_DIR=$(normalize "$TMPDIR_DIR")

# User dev directories — colon-separated, set via CLAUDE_DEV_DIRS env var
# e.g. export CLAUDE_DEV_DIRS="~/phantom:~/work"
IFS=: read -ra _RAW_DEV_DIRS <<< "${CLAUDE_DEV_DIRS:-}"
DEV_DIRS=()
for _d in "${_RAW_DEV_DIRS[@]}"; do
  _d="${_d/#\~/$HOME}"  # expand leading ~
  DEV_DIRS+=("$(normalize "$_d")")
done

# Directories admitted whole — the root itself, or anything beneath it. Every
# entry obeys the same two-pattern rule, so they share one loop below rather
# than each spelling its own `X|X/*` case arm; the CLAUDE_DEV_DIRS entries join
# the list for the same reason, having always been matched by exactly that loop.
# Adding a root is a line here, with no second pattern to get right.
ALLOWED_ROOTS=(
  "$PROJECT_DIR"
  "$HOME_DIR/.claude"
  "$HOME_DIR/.claude-personal"
  "$HOME_DIR/.claude-work"
  # skadi's runtime data root — the handoff mailbox, the moria mend list, the
  # board channels, the repo-watch file. Shared across every profile and never
  # touched by /install, so it belongs beside the config roots rather than
  # inside one: skills read and amend those files by absolute path.
  "$HOME_DIR/.skadi"
  /tmp
  /private/tmp
  "$TMPDIR_DIR"
  "$TMPDIR_RAW"
  "${DEV_DIRS[@]}"
)

# Returns 0 if path is under project dir, .claude dir, .skadi, /tmp, or any dev dir
in_allowed_dir() {
  local p="$1"
  local _root
  for _root in "${ALLOWED_ROOTS[@]}"; do
    case "$p" in
      "$_root"|"$_root"/*) return 0 ;;
    esac
  done
  # The dev sinks are files, not roots: matched exactly and never as a prefix,
  # so a path merely beginning with one of their names is not admitted.
  case "$p" in
    /dev/null|/dev/stdout|/dev/stderr|/dev/tty) return 0 ;;
  esac
  return 1
}

# Returns 0 if path is under a well-known system/toolchain install directory
# (Homebrew, /usr/local, the base OS bin dirs). Deliberately narrower than
# in_allowed_dir and used only for the Bash argument-path check below — a
# command referencing where a system binary lives (e.g. `ls /opt/homebrew/bin/
# glab` to confirm it exists) is a read, not a sandbox escape. Never used for
# the Write/Edit/NotebookEdit file_path check: writing into a toolchain shared
# by every project on the machine stays blocked regardless of this list.
in_system_bin_dir() {
  local p="$1"
  case "$p" in
    /opt/homebrew|/opt/homebrew/*) return 0 ;;
    /usr/local|/usr/local/*) return 0 ;;
    /usr/bin|/usr/bin/*) return 0 ;;
    /usr/sbin|/usr/sbin/*) return 0 ;;
    /bin|/bin/*) return 0 ;;
    /sbin|/sbin/*) return 0 ;;
  esac
  return 1
}

# Check if at disk root (/, /c, /d, etc.)
if echo "$CWD" | grep -qE '^/$|^/[a-z]$'; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: running at disk root (%s) is not allowed"}}' "$CWD"
  exit 0
fi

# Check if outside user home. On the Claude Code remote container ($HOME
# may be /root while the project lives under /home/user/...), the project
# dir and dev dirs are admitted even though they fall outside HOME — the
# downstream in_allowed_dir check still enforces project / .claude / /tmp /
# dev. On local machines the strict home check stays in place.
case "$CWD" in
  "$HOME_DIR"|"$HOME_DIR"/*)
    ;; # ok, under home
  *)
    if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && in_allowed_dir "$CWD"; then
      :  # ok — remote container, cwd is project/dev/.claude/tmp
    else
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: cwd (%s) is outside home directory (%s)"}}' "$CWD" "$HOME_DIR"
      exit 0
    fi
    ;;
esac

# Check if outside project dir and dev dirs
if ! in_allowed_dir "$CWD"; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: cwd (%s) is outside project and dev directories"}}' "$CWD"
  exit 0
fi

# Check command arguments for absolute paths outside the project.
# Uses Python's shlex for quote-aware tokenization so paths inside
# quoted strings (e.g. commit messages, echo args) are not flagged.
# Each token is tagged CMD (the executable being invoked — its own
# location, not a file it reads/writes) or ARG (everything else). A CMD
# token is exempt from the path-escape checks below: referencing where a
# binary lives (e.g. /opt/homebrew/bin/git) isn't a sandbox escape the way
# an out-of-project file argument is. Every command's own executable slot
# in a chain gets this — not just the first word of the whole string — so
# `cmd1 && /opt/homebrew/bin/git status` is covered too.
CMD=$(echo "$INPUT" | jq -r '.tool_input.command' 2>/dev/null)
if [ -n "$CMD" ]; then
  # Keep the heredoc outside command substitution itself. Bash 3.2 parses
  # `$()` bodies before honoring a quoted heredoc delimiter, so Python text
  # containing quote and `$(` examples can make the whole hook fail syntax
  # validation even though newer Bash versions accept it.
  tokenize_command() {
    python3 - "$CMD" 2>/dev/null <<'PYEOF'
import re, sys, shlex

# shlex.split() knows shell quoting ('...', "...") but nothing about heredoc
# syntax (<<'EOF' ... EOF) — a heredoc body is literal text a real shell
# never re-tokenizes, but shlex has no way to know that and happily splits
# it into words like any other unquoted text. A single apostrophe inside
# that prose (an English contraction in a commit message, say) then reads
# as an unmatched open-quote, silently swallowing everything up to the
# *next* apostrophe anywhere later in the string into one giant "word" —
# which can smuggle an unrelated path-looking substring into a token, or
# just misfire the check on prose that was never a command argument at
# all. Heredoc bodies carry no command-argument paths to check (they're
# data — a commit message, a script piped to an interpreter), so they're
# excised before shlex ever sees them, rather than patched around after.
#
# A naive "find <<DELIM anywhere" pass over-fires: `<<` shows up inside
# ordinary quoted prose too (a commit message that happens to mention
# `<<` syntax), and when no line matching that "delimiter" follows, the
# stripper's unterminated-heredoc fallback drops everything from that
# point on — silently hiding a real path argument later in the same
# command, which is worse than never stripping at all. So heredoc
# detection only fires in a genuinely unquoted shell position: tracked via
# a small quote/paren stack, since a real shell only treats `<<` as a
# redirection there. `$(...)` gets special handling because command
# substitution parses its contents fresh even when the whole `$(...)` sits
# inside an outer double-quoted string — exactly the
# `git commit -m "$(cat <<'EOF' ... EOF)"` shape this fix exists for.
#
# Two more unquoted-but-not-a-heredoc shapes share that same `<<` prefix
# and need their own guards, or they reopen the exact bug this exists to
# close: `$((1<<2))` arithmetic expansion, where `<<` is a bit-shift
# operator (handled by consuming the whole balanced `$((...))` span
# without ever running heredoc detection inside it — arithmetic has no
# quoting of its own to track), and `<<<word` here-strings, which share
# their first two characters with a real heredoc operator (handled by
# refusing to treat `<<` as an opener when it's immediately preceded by
# another `<`, i.e. when it's actually the middle of a longer run).
HEREDOC_RE = re.compile(r"<<(-?)\s*(['\"]?)(\w+)\2")

def _scan_arith(text, i, n):
    """From a '$((' opener at i, the index just past its matching '))'.
    Arithmetic expansion balances on parens alone, so its span is
    consumed whole rather than character-scanned for quotes or heredocs."""
    depth = 0
    j = i
    while j < n:
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return n  # unterminated — consume to end, same posture as an unterminated heredoc

def strip_heredocs(text):
    out = []
    i = 0
    n = len(text)
    stack = []  # top of stack: "'" or '"' (inside a quote), "(" (inside
                # $(...) or a bare subshell), or the stack is empty (bare
                # top level) — heredocs are only real outside a quote.
    # A real shell doesn't strip a heredoc's body the instant it sees the
    # opener — it keeps parsing the REST of that line first (a redirect,
    # a pipe, even a second `<<` operator can follow on the same line),
    # and only once that line's newline is reached does it read the
    # queued body/bodies, in the order their openers appeared. Stripping
    # immediately at the opener — the first version of this function —
    # swallowed whatever else shared that line (e.g. `<<EOF > /etc/passwd`
    # lost the `> /etc/passwd` redirect target into the "body"), hiding a
    # real path argument from the scanner. `pending_stack` mirrors that
    # queue — one list per open $(...) nesting level (index 0 is the bare
    # top level), because an inner $(...) must finish resolving its own
    # queued heredocs on its own internal newlines before the outer line
    # can resume: `cat <<A $(cat <<B ... B) ... A` opens A before B in
    # source order, but B's body — being still inside the unclosed $(...)
    # — is read first, on the newline that ends $(...)'s own first line.
    # A single flat queue would try to close A with B's terminator line
    # instead, corrupting both.
    pending_stack = [[]]

    def consume_pending(pos):
        pending = pending_stack[-1]
        for dash, delim in pending:
            leading = r"[ \t]*" if dash else ""
            end_pat = re.compile(r"(?m)^" + leading + re.escape(delim) + r"[ \t]*$")
            end = end_pat.search(text, pos)
            # Unterminated heredoc: drop the rest rather than re-emit an
            # unclosed body shlex would just mis-tokenize the same way.
            pos = end.end() if end else n
            if end is None:
                break
        pending_stack[-1] = []
        return pos

    while i < n:
        top = stack[-1] if stack else None
        c = text[i]

        if top == "'":
            out.append(c)
            i += 1
            if c == "'":
                stack.pop()
            continue

        if top == '"':
            if c == '"':
                stack.pop()
                out.append(c)
                i += 1
            elif c == "\\" and i + 1 < n:
                out.append(text[i:i + 2])
                i += 2
            elif text[i:i + 3] == "$((":
                end = _scan_arith(text, i, n)
                out.append(text[i:end])
                i = end
            elif text[i:i + 2] == "$(":
                stack.append("(")
                pending_stack.append([])
                out.append("$(")
                i += 2
            else:
                out.append(c)
                i += 1
            continue

        # A newline ends the current shell line — consume any heredoc
        # bodies queued during it, in order, before resuming. (A newline
        # inside a quote never reaches here — the quote branches above
        # handle their own characters, including embedded newlines,
        # without touching `pending_stack`.) Only the current nesting
        # level's queue is consumed — an outer level's still-pending
        # heredocs wait for a newline at that level, once its $(...) closes.
        if c == "\n":
            out.append(c)
            i += 1
            if pending_stack[-1]:
                i = consume_pending(i)
            continue

        # Unquoted position (bare top level, or inside an open $(...)):
        # quotes and command substitution nest normally, and a bare `<<`
        # here is a genuine heredoc redirection.
        if c == "\\" and i + 1 < n:
            out.append(text[i:i + 2])
            i += 2
            continue
        if text[i:i + 3] == "$((":
            end = _scan_arith(text, i, n)
            out.append(text[i:end])
            i = end
            continue
        if c in ("'", '"'):
            stack.append(c)
            out.append(c)
            i += 1
            continue
        if text[i:i + 2] == "$(":
            stack.append("(")
            pending_stack.append([])
            out.append("$(")
            i += 2
            continue
        if c == "(":
            stack.append("(")
            pending_stack.append([])
            out.append(c)
            i += 1
            continue
        if c == ")" and top == "(":
            stack.pop()
            # Any heredocs still pending at this nesting level when its
            # closing paren arrives (no newline inside it ever saw them
            # off) are dropped along with the level itself — same posture
            # as an unterminated heredoc, not leaked into the outer level.
            pending_stack.pop()
            out.append(c)
            i += 1
            continue
        # Exactly two '<' — not the tail of a longer run like the '<<<'
        # here-string operator, which shares this prefix but must never
        # be treated as a heredoc opener.
        if text[i:i + 2] == "<<" and (i == 0 or text[i - 1] != "<"):
            m = HEREDOC_RE.match(text, i)
            if m:
                out.append(text[i:m.end()])
                pending_stack[-1].append((m.group(1), m.group(3)))
                i = m.end()
                continue
        out.append(c)
        i += 1
    return "".join(out)

try:
    raw_tokens = shlex.split(strip_heredocs(sys.argv[1]))
except ValueError:
    # A malformed command (unmatched quote, trailing escape, etc.) must not
    # turn a tokenizer failure into a path-check bypass. The shell loop below
    # treats this marker as a denial.
    print("ERROR:command could not be parsed safely")
    sys.exit(0)

def unglued(tok):
    """Drop shell control operators glued to a token's tail.

    shlex understands words and quoting, not control operators, so a `;`,
    `|`, `&`, `)` or redirection written with no space before it rides along
    as part of the preceding word (`2>/dev/null;` arrives as one token).
    Every token is cleaned through here before the path check, so a path is
    judged on what it names and not on whether a space happened to follow it.
    """
    return re.sub(r'[;&|()<>]+$', '', tok)


expect_cmd = True
expect_redirect_target = False
for raw in raw_tokens:
    # A token made entirely of shell operator characters is either a command
    # separator or a redirection. Separators reset command position;
    # redirections make the next word an ARG while preserving the current
    # command position. Treating `>` as a separator used to tag its target as
    # CMD, exempting `cat foo > /etc/passwd` from path checks.
    if raw and all(c in ';&|()<>' for c in raw):
        if '<' in raw or '>' in raw:
            expect_redirect_target = True
        else:
            expect_cmd = True
        continue

    # An fd-prefixed redirection with a separated target (`2> /path`) is
    # returned by shlex as `2>` and `/path`, rather than as an operator-only
    # token. It has the same state transition as `> /path`.
    if re.match(r'^\d+(?:<<<|<<|>>|<|>)$', raw):
        expect_redirect_target = True
        continue

    # shlex does not split a redirection glued to its destination. Handle
    # `>/path`, `2>>/path`, `<file`, and their here-string/heredoc-shaped
    # counterparts as argument paths, not command words.
    redirect = re.match(r'^\d*(?:<<<|<<|>>|<|>)(.+)$', raw)
    if redirect:
        print('ARG:' + unglued(redirect.group(1)))
        expect_redirect_target = False
        continue

    if expect_redirect_target:
        print('ARG:' + unglued(raw))
        expect_redirect_target = False
        continue

    print(('CMD:' if expect_cmd else 'ARG:') + unglued(raw))
    expect_cmd = False
PYEOF
  }
  TOKENS=$(tokenize_command)
  while IFS= read -r LINE; do
    TAG="${LINE%%:*}"
    TOKEN="${LINE#*:}"
    if [ "$TAG" = "ERROR" ]; then
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: command could not be parsed safely"}}'
      exit 0
    fi
    case "$TOKEN" in
      ~*|--*|-*|"") continue ;;
    esac
    if [ "$TAG" = "CMD" ]; then
      continue
    fi
    # Check for absolute paths (/c/..., /usr/..., C:\..., C:/... — the
    # forward-slash form is what Git Bash users actually type on Windows).
    if [[ "$TOKEN" =~ ^/[a-zA-Z] ]] || [[ "$TOKEN" =~ ^[A-Za-z]:\\ ]] || [[ "$TOKEN" =~ ^[A-Za-z]:/ ]]; then
      NORM=$(normalize "$TOKEN")
      if ! in_allowed_dir "$NORM" && ! in_system_bin_dir "$NORM"; then
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: command references path (%s) outside project and dev directories"}}' "$NORM"
        exit 0
      fi
    fi
    # Check for relative paths with ../ that escape the project
    if [[ "$TOKEN" =~ \.\. ]]; then
      RESOLVED=$(cd "$CWD" 2>/dev/null && cd "$(dirname "$TOKEN")" 2>/dev/null && pwd -W 2>/dev/null || pwd -P 2>/dev/null)
      if [ -n "$RESOLVED" ]; then
        RESOLVED=$(normalize "$RESOLVED/$(basename "$TOKEN")")
        case "$RESOLVED" in
          "$PROJECT_DIR"|"$PROJECT_DIR"/*)
            ;; # ok, resolves inside project
          *)
            printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: relative path (%s) resolves to (%s) outside project directory (%s)"}}' "$TOKEN" "$RESOLVED" "$PROJECT_DIR"
            exit 0
            ;;
        esac
      fi
    fi
  done <<< "$TOKENS"
fi

# Check the target path for Write/Edit/MultiEdit/NotebookEdit tools. These
# tools always receive an absolute path, so — unlike the Bash ARG check above
# — no relative-path resolution is needed.
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
if [ -n "$FILE_PATH" ]; then
  NORM=$(normalize "$FILE_PATH")
  if ! in_allowed_dir "$NORM"; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: file path (%s) is outside project and dev directories"}}' "$NORM"
    exit 0
  fi
fi

# All checks passed — log cwd as informational message
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","message":"cwd: %s"}}' "$CWD"
