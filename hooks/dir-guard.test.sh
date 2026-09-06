#!/bin/bash
# Offline tests for the cwd/path guard. Run from anywhere: bash dir-guard.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/dir-guard.sh"
REPO="$(cd "$HERE/.." && pwd)"
# The hook's own shebang (#!/bin/bash) is what actually runs it in
# production on macOS — the ancient system bash 3.2, not whatever newer
# bash a dev machine's PATH prefers. The two parse some constructs (a
# heredoc nested inside $(...), notably) differently: a hook that broke
# bash 3.2's parser once shipped clean here because this suite invoked
# the bare `bash` word, which resolved through PATH to a newer bash that
# had no trouble with it. Pinning to /bin/bash directly is what makes
# this suite test the same interpreter production actually uses.
HOOK_BASH="/bin/bash"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# Runs the hook from inside the repo (a known-allowed cwd) with the given
# command, and reports whether the result denies.
run_cmd() { # command
  local decision
  decision=$(cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" \
    printf '{"tool_input":{"command":%s}}' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" \
    | CLAUDE_PROJECT_DIR="$REPO" "$HOOK_BASH" "$HOOK" \
    | python3 -c "
import json, sys
raw = sys.stdin.read()
# Silence is the allow signal: with no permissionDecision the harness runs the
# call normally, and on that path the hook prints nothing at all.
if not raw.strip():
    print('allow')
else:
    d = json.loads(raw)['hookSpecificOutput']
    print('deny' if d.get('permissionDecision') == 'deny' else 'allow')
")
  printf '%s' "$decision"
}

# ── the allow path says nothing at all ──
# A PreToolUse hook reaches the model only through documented fields, and the
# one this line used to print — `message` — is not among them, so it travelled
# nowhere while firing on every allowed call. Silence is the correct allow
# signal; this pins it so the dead field cannot creep back.
allow_raw=$(cd "$REPO" && printf '{"tool_input":{"command":"ls"}}' \
  | CLAUDE_PROJECT_DIR="$REPO" "$HOOK_BASH" "$HOOK")
check "the allow path emits nothing at all" "" "$allow_raw"

# ── the four dev sinks are allowed, even though they're absolute paths outside the project ──
for sink in /dev/null /dev/stdout /dev/stderr /dev/tty; do
  check "command referencing $sink is allowed" "allow" "$(run_cmd "cat foo 2>$sink")"
done

# ── a redirect target glued to the next shell operator is still just a path ──
# shlex hands back "/dev/null;" as one word when no space precedes the
# separator. Only the general argument branch stripped that punctuation, so
# whether a command was allowed turned on whether a space happened to be
# typed — the same redirect read as allowed with one and denied without.
check "redirect target followed by ; is allowed" "allow" "$(run_cmd 'ls *.md 2>/dev/null; echo hi')"
check "redirect target followed by | is allowed" "allow" "$(run_cmd 'ls *.md 2>/dev/null| head')"
check "separated redirect target followed by ; is allowed" "allow" "$(run_cmd 'ls *.md 2> /dev/null; echo hi')"

# ── stripping that punctuation must reveal paths, never excuse them ──
# The strip runs before the path check, so a denied target must stay denied
# with the operator glued on; otherwise the fix above would be a bypass.
check "glued-operator redirect to an outside path is still denied" "deny" "$(run_cmd 'cat foo >/etc/passwd; echo hi')"
check "separated redirect to an outside path is still denied" "deny" "$(run_cmd 'cat foo > /etc/passwd| tee x')"

# ── a genuinely disallowed absolute path is still denied — no regression ──
check "command referencing a real outside path is still denied" "deny" "$(run_cmd "cat /etc/passwd")"

# ── a path under $TMPDIR is allowed in both its raw form (what callers like
# skadi-worktree.sh build paths from directly) and its symlink-resolved form
# (e.g. macOS's /var/folders/... vs /private/var/folders/...) — not just the
# literal /tmp and /private/tmp aliases ──
TMPDIR_RAW="${TMPDIR:-/tmp}"
TMPDIR_RAW="${TMPDIR_RAW%/}"
check "command referencing a path under raw \$TMPDIR is allowed" "allow" "$(run_cmd "cat $TMPDIR_RAW/scratch-file")"
TMPDIR_RESOLVED=$(cd "${TMPDIR:-/tmp}" && pwd -P)
check "command referencing a path under resolved \$TMPDIR is allowed" "allow" "$(run_cmd "cat $TMPDIR_RESOLVED/scratch-file")"

# ── ~/.skadi is skadi's own runtime data root (the handoff mailbox, the mend
# list, the board channels, the repo-watch file) — skills read and amend those
# by absolute path, so it is admitted alongside the config roots. The prefix
# match is anchored: a sibling that merely starts with the same characters is
# not the same directory and stays denied ──
check "command referencing a path under ~/.skadi is allowed" "allow" "$(run_cmd "cat $HOME/.skadi/handoff/skadi/msg.md")"
check "command referencing ~/.skadi itself is allowed" "allow" "$(run_cmd "ls $HOME/.skadi")"
check "a sibling of ~/.skadi sharing its prefix is still denied" "deny" "$(run_cmd "cat $HOME/.skadi-other/secrets")"

# ── ~/Downloads and ~/Documents are standard OS user folders — a downloaded
# file or a drag-and-dropped document lives there regardless of which project
# is the session's cwd, so they're admitted like ~/.skadi above rather than
# left to the per-user CLAUDE_DEV_DIRS opt-in. Same anchored-prefix discipline
# applies: a sibling sharing the prefix is not the same directory ──
check "command referencing a path under ~/Downloads is allowed" "allow" "$(run_cmd "cat $HOME/Downloads/report.pdf")"
check "command referencing ~/Downloads itself is allowed" "allow" "$(run_cmd "ls $HOME/Downloads")"
check "a sibling of ~/Downloads sharing its prefix is still denied" "deny" "$(run_cmd "cat $HOME/Downloads-old/secrets")"
check "command referencing a path under ~/Documents is allowed" "allow" "$(run_cmd "cat $HOME/Documents/notes.md")"
check "command referencing ~/Documents itself is allowed" "allow" "$(run_cmd "ls $HOME/Documents")"
check "a sibling of ~/Documents sharing its prefix is still denied" "deny" "$(run_cmd "cat $HOME/Documents-old/secrets")"

# ── an allowed path glued to a trailing shell operator (no space) is still allowed —
# shlex.split doesn't treat these as separators, so a naive check would see
# ".claude-work;" and miss the exact/glob match against ".claude-work" ──
for op in ";" "&&" "||" "|" ")" ">"; do
  check "allowed path glued to trailing '$op' is still allowed" "allow" "$(run_cmd "echo $HOME/.claude-work$op echo done")"
done

# ── a disallowed path glued to a trailing operator is still denied, not smuggled through ──
check "disallowed path glued to trailing ';' is still denied" "deny" "$(run_cmd "cat /etc/passwd; echo done")"

# ── a forward-slash Windows path (C:/..., what Git Bash users actually type) is
# caught by the same check that already catches the backslash form (C:\...) ──
check "forward-slash Windows path is denied like its backslash form" "deny" "$(run_cmd 'cat C:/Windows/System32/config')"

# ── a command's own executable path outside the project is exempt — locating
# a binary isn't a sandbox escape the way an out-of-project file argument is ──
check "command's own absolute path is allowed" "allow" "$(run_cmd "/opt/homebrew/bin/git status")"
check "command's own absolute path is allowed in every chain slot" "allow" "$(run_cmd "echo hi && /opt/homebrew/bin/git status")"

# ── an outside path used as an *argument*, not the command being run, is
# still denied in general — the executable-slot exemption above covers only
# the command position ──
check "outside path used as an argument is still denied" "deny" "$(run_cmd "cat /etc/hosts")"

# ── redirection operators do not create a new executable slot. Their target
# is an argument path and must be checked whether separated from the operator,
# glued to it, fd-prefixed, or placed before the command itself ──
check "space-separated redirect target outside project is denied" "deny" "$(run_cmd "cat foo > /etc/passwd")"
check "glued redirect target outside project is denied" "deny" "$(run_cmd "cat foo >/etc/passwd")"
check "fd-prefixed redirect target outside project is denied" "deny" "$(run_cmd "cat foo 2>>/etc/passwd")"
check "fd-prefixed redirect with separated target is denied" "deny" "$(run_cmd "cat foo 2>> /etc/passwd")"
check "command-prefix redirect target outside project is denied" "deny" "$(run_cmd "> /etc/passwd echo foo")"
check "allowed command-prefix redirect preserves executable slot" "allow" "$(run_cmd "2> /tmp/stderr /outside/tool")"

# ── invalid shell quoting must fail closed. Previously shlex raised
# ValueError and the fallback silently returned no tokens, skipping every
# command-path check ──
check "unmatched quote cannot bypass path checks" "deny" "$(run_cmd "cat /etc/passwd '")"
check "trailing escape cannot bypass path checks" "deny" "$(run_cmd 'cat /etc/passwd \')"

# ── a well-known system/toolchain bin dir used as an *argument* is allowed —
# referencing where a system binary lives (an existence check, `ls`, `file`)
# is a read, not a sandbox escape, so it doesn't need the executable-slot
# exemption above to pass ──
for sysdir in /opt/homebrew/bin/glab /usr/local/bin/foo /usr/bin/env /bin/ls; do
  check "system bin path ($sysdir) used as an argument is allowed" "allow" "$(run_cmd "ls -la $sysdir")"
done

# ── a heredoc body (e.g. a git commit -m "$(cat <<'EOF' ... EOF)" message) is
# not shell-tokenized at all by a real shell, but shlex doesn't know heredoc
# syntax and happily splits its prose into words. An apostrophe inside that
# prose (an English contraction) used to read as an unmatched open-quote,
# silently swallowing everything up to the *next* apostrophe — including any
# path-looking substring in between — into one bogus "argument" token ──
HEREDOC_APOSTROPHE_CMD='git commit -m "$(cat <<'"'"'EOF'"'"'
this binary'"'"'s path and it didn'"'"'t work, see /opt/homebrew/bin/git
EOF
)"'
check "apostrophes inside a heredoc commit message no longer misfire" "allow" "$(run_cmd "$HEREDOC_APOSTROPHE_CMD")"

# ── a genuinely outside path still denies when it sits outside any heredoc,
# proving the heredoc stripper only excises heredoc bodies, not the real
# command line around them ──
HEREDOC_REAL_PATH_CMD='cat <<'"'"'EOF'"'"'
just data, nothing special
EOF
cat /etc/hosts'
check "an outside path after a heredoc is still denied" "deny" "$(run_cmd "$HEREDOC_REAL_PATH_CMD")"

# ── the <<- form allows a tab-indented closing delimiter line — the body
# must still be found and stripped (an apostrophe inside it must not
# misfire), and the command after it must still be scanned normally ──
HEREDOC_DASH_CMD='cat <<-'"'"'EOF'"'"'
	an indented body that didn'"'"'t break the closing delimiter search
	EOF
cat /etc/hosts'
check "an outside path after a <<- (dash-indented) heredoc is still denied" "deny" "$(run_cmd "$HEREDOC_DASH_CMD")"

# ── a stray "<<word" that is NOT a real heredoc — just `<<` appearing inside
# ordinary quoted prose, with no line matching "word" anywhere after — must
# not be treated as a heredoc opener. A first cut of this fix matched `<<`
# anywhere and, finding no closing line, dropped everything from that point
# to the end of the string as an "unterminated heredoc" — silently hiding
# the real /etc/passwd argument that follows. Heredoc detection must only
# fire in a genuinely unquoted shell position ──
STRAY_HEREDOC_CMD='git commit -m "note about <<indent tricks" && cat /etc/passwd'
check "a stray << inside quoted prose does not hide a later outside path" "deny" "$(run_cmd "$STRAY_HEREDOC_CMD")"

# ── arithmetic expansion's << is a bit-shift operator, never a heredoc —
# $((1<<2)) must not be mistaken for a heredoc opener, which would again
# trigger the unterminated-heredoc fallback and hide the real path after it ──
check "arithmetic expansion's << is not mistaken for a heredoc" "deny" "$(run_cmd 'echo $((1<<2)) && cat /etc/passwd')"

# ── <<< is the here-string operator, a different token that happens to share
# its first two characters with the heredoc operator — it must not be
# mistaken for one either ──
check "<<< here-string is not mistaken for a heredoc" "deny" "$(run_cmd 'cat <<<hello && cat /etc/passwd')"

# ── a real shell doesn't strip a heredoc body the instant it sees the
# opener — it finishes parsing the REST of that line first (a pipe, a
# second heredoc operator), and only reads the queued body once the line's
# newline is reached. Stripping immediately at the opener swallowed
# whatever else shared that line into the "body" — these two prove it
# no longer does ──
check "content after a heredoc opener on the same line is not swallowed" "deny" \
  "$(run_cmd 'cat <<EOF | tee /some/other/path
data
EOF')"
check "a second heredoc on the same line is still recognized as its own opener" "deny" \
  "$(run_cmd 'diff <<A <<B
first
A
second
B
cat /etc/passwd')"

# ── a heredoc opened on the outer line but nested inside a same-line
# $(...) must resolve in the ORDER A REAL SHELL RESOLVES IT — the inner
# one first, since command substitution finishes parsing (including its
# own queued heredocs) before the outer line's newline can be reached —
# not in source (textual) order. A single flat pending queue tried to
# close the outer opener with the inner one's terminator line instead,
# corrupting both and leaking the rest of the string past what shlex
# ever saw ──
check "a heredoc nested in a same-line \$(...) resolves before the outer one" "deny" \
  "$(run_cmd 'cat <<A $(cat <<B
x
B
)
y
A
cat /etc/passwd')"

# Runs the hook from inside the repo (a known-allowed cwd) as a Write/Edit-style
# call — tool_input carries file_path instead of command — and reports whether
# the result denies. An optional third arg sets CLAUDE_DEV_DIRS for the call.
run_write() { # file_path [dev_dirs]
  local decision
  decision=$(cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" CLAUDE_DEV_DIRS="${2:-}" \
    printf '{"tool_input":{"file_path":%s}}' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" \
    | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_DEV_DIRS="${2:-}" "$HOOK_BASH" "$HOOK" \
    | python3 -c "
import json, sys
raw = sys.stdin.read()
# Silence is the allow signal: with no permissionDecision the harness runs the
# call normally, and on that path the hook prints nothing at all.
if not raw.strip():
    print('allow')
else:
    d = json.loads(raw)['hookSpecificOutput']
    print('deny' if d.get('permissionDecision') == 'deny' else 'allow')
")
  printf '%s' "$decision"
}

# ── Write/Edit/NotebookEdit tools carry file_path, not command — the guard
# must gate that field too, not just Bash's command string ──
check "Write file_path inside project is allowed" "allow" "$(run_write "$REPO/hooks/dir-guard.sh")"
check "Write file_path outside project is denied" "deny" "$(run_write "/etc/passwd")"
check "Write file_path under .claude-personal is allowed" "allow" "$(run_write "$HOME/.claude-personal/hooks/foo.sh")"
check "Write file_path under .skadi is allowed" "allow" "$(run_write "$HOME/.skadi/moria/mend_repos.md")"
check "Write file_path under ~/Downloads is allowed" "allow" "$(run_write "$HOME/Downloads/report.pdf")"
check "Write file_path under ~/Documents is allowed" "allow" "$(run_write "$HOME/Documents/notes.md")"

# ── the CLAUDE_DEV_DIRS whitelist governs file_path exactly as it governs
# Bash command args — same in_allowed_dir check, same allowance ──
OUTSIDE_PATH="$HOME/some-other-project/file.txt"
check "Write file_path outside project with no dev-dir whitelist is denied" "deny" "$(run_write "$OUTSIDE_PATH")"
check "Write file_path inside CLAUDE_DEV_DIRS whitelist is allowed" "allow" "$(run_write "$OUTSIDE_PATH" "$HOME/some-other-project")"

# ── in_system_bin_dir governs the Bash argument-path check only — Write/Edit
# still uses in_allowed_dir alone, so a system/toolchain bin dir stays exactly
# as write-protected as any other outside path. Widening what a command may
# *reference* must never widen what a tool may *overwrite* ──
check "Write file_path under a system bin dir is still denied" "deny" "$(run_write "/opt/homebrew/bin/glab")"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
