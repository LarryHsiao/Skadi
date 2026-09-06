#!/usr/bin/env bash
# Test for protected-repo-guard.sh — exercises the guard against a temp
# protected-repo list and simulated session roots.
# Run by hand: hooks/protected-repo-guard.test.sh (also runs under /bin/bash 3.2)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/protected-repo-guard.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PROTECTED="$TMP/protected-repo"
OUTSIDE="$TMP/outside-repo"
mkdir -p "$PROTECTED" "$OUTSIDE" "$PROTECTED/sub"

export PROTECTED_REPOS_FILE="$TMP/protected_repos.md"
printf -- '- %s \xe2\x86\x92 mychan\n' "$PROTECTED" > "$PROTECTED_REPOS_FILE"

fail=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    echo "       expected: [$expected]"
    echo "       actual:   [$actual]"
    fail=1
  fi
}

edit_payload() {
  printf '{"tool_input":{"file_path":"%s"}}' "$1"
}

bash_payload() {
  printf '{"tool_input":{"command":"%s"}}' "$1"
}

notebook_payload() {
  printf '{"tool_input":{"notebook_path":"%s"}}' "$1"
}

# The guard advises rather than denies: it returns no permissionDecision at
# all, so the normal permission flow proceeds untouched, and attaches an
# `additionalContext` note naming the repo's handoff channel. What every case
# below asserts is therefore whether the guard SPOKE about this call, not what
# verdict it returned — dir-guard remains the lock on the ordinary cross-repo
# path, and this hook's job is to carry the knowledge, not to bar the door.
caught() {
  printf '%s' "$1" | grep -o '"additionalContext"' | head -1
}

# 1. Edit inside the protected repo, session rooted there — allowed.
out=$(edit_payload "$PROTECTED/CLAUDE.md" | CLAUDE_PROJECT_DIR="$PROTECTED" "$HOOK")
check "self-edit allowed" "" "$(caught "$out")"

# 2. Edit inside the protected repo, session rooted outside — advised, names the channel.
out=$(edit_payload "$PROTECTED/CLAUDE.md" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "cross-repo edit advised" '"additionalContext"' "$(caught "$out")"
check "advice names channel" "1" "$(printf '%s' "$out" | grep -c 'mychan')"

# 3. Edit inside an unrelated dir, session rooted outside — allowed.
out=$(edit_payload "$OUTSIDE/foo.md" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "unrelated edit allowed" "" "$(caught "$out")"

# 4. Bash command referencing the protected repo, session rooted outside — advised.
out=$(bash_payload "cat $PROTECTED/CLAUDE.md" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "cross-repo bash advised" '"additionalContext"' "$(caught "$out")"

# 5. CLAUDE_DEV_DIRS listing the protected repo's parent does not silence the
#    advice. Note what this no longer proves: whether the WRITE is barred is
#    now dir-guard's answer alone, and CLAUDE_DEV_DIRS does exempt it there.
#    This case pins only that the note still reaches the model.
out=$(bash_payload "cat $PROTECTED/CLAUDE.md" | CLAUDE_PROJECT_DIR="$OUTSIDE" CLAUDE_DEV_DIRS="$TMP" "$HOOK")
check "CLAUDE_DEV_DIRS does not silence the advice" '"additionalContext"' "$(caught "$out")"

# 6. Missing list file — fails open, everything allowed.
out=$(edit_payload "$PROTECTED/CLAUDE.md" | PROTECTED_REPOS_FILE="$TMP/no-such-file.md" CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "missing list fails open" "" "$(caught "$out")"

# 7. Session rooted in a nested subdirectory of the protected repo — self-edit allowed.
out=$(edit_payload "$PROTECTED/sub/deep.md" | CLAUDE_PROJECT_DIR="$PROTECTED/sub" "$HOOK")
check "nested self-edit allowed" "" "$(caught "$out")"

# 8. Bash command with a relative ../ path, session's actual shell cwd
#    (not just CLAUDE_PROJECT_DIR) sitting outside the protected repo —
#    the tokenizer's absolute-path regex misses this token entirely, so
#    only the ../ resolution branch can catch it.
out=$(cd "$OUTSIDE" && bash_payload "cat ../$(basename "$PROTECTED")/CLAUDE.md" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "relative ../ path bash advised" '"additionalContext"' "$(caught "$out")"

# 9. protected_repos.md line with no → separator at all (bare path, no
#    channel) — pre-fix, ${line%%→*} and ${line#*→} both return the whole
#    line unchanged, so repo == chan == the path, and the line matches and
#    emitted a garbled `/handoff send <path> ...` channel. Fixed: the
#    line is skipped outright — silent, not advising-with-garbage.
MALFORMED_LIST="$TMP/protected_repos_malformed.md"
printf -- '- %s\n' "$PROTECTED" > "$MALFORMED_LIST"
out=$(edit_payload "$PROTECTED/CLAUDE.md" | PROTECTED_REPOS_FILE="$MALFORMED_LIST" CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "malformed line (no arrow) skipped" "" "$(caught "$out")"

# 10. notebook_path (not file_path) inside the protected repo, session
#     rooted outside — advised.
out=$(notebook_payload "$PROTECTED/notebook.ipynb" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "notebook_path cross-repo advised" '"additionalContext"' "$(caught "$out")"

# 11. Bash command with a bare-relative path (no ./ or ../ prefix at all),
#     cwd is the protected repo's parent — the tokenizer's absolute-path
#     check misses this token entirely (no leading /), and pre-fix the
#     ../-only branch missed it too (no ".." substring). Only the unified
#     relative-resolution branch can catch it.
out=$(cd "$TMP" && bash_payload "cat $(basename "$PROTECTED")/CLAUDE.md" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "bare-relative descendant bash advised" '"additionalContext"' "$(caught "$out")"

# 12. Bash command with a ./-relative path, same cwd — advised.
out=$(cd "$TMP" && bash_payload "cat ./$(basename "$PROTECTED")/CLAUDE.md" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "./-relative descendant bash advised" '"additionalContext"' "$(caught "$out")"

# 13. Bash command with a literal-tilde path (~/protected-repo/CLAUDE.md) —
#     advised. HOME is overridden to $TMP for just this invocation so ~
#     expands to a path the test controls (not the real $HOME), landing on
#     the same $PROTECTED path already registered in the list file. Pre-fix,
#     the tokenizer's `~*` case arm skipped any tilde-leading token outright
#     before it could ever be checked.
out=$(bash_payload "cat ~/$(basename "$PROTECTED")/CLAUDE.md" | HOME="$TMP" CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "literal-tilde path bash advised" '"additionalContext"' "$(caught "$out")"

# 14. protected_repos.md line with an arrow but an empty channel (nothing
#     after the →) — pre-fix, `[ -z "$repo" ] && continue` only checked
#     repo, so the line still matched and emitted a garbled
#     `/handoff send  <your change>` (double space, no channel). Fixed: the
#     line is skipped outright — silent, not advising-with-garbage.
EMPTY_CHAN_LIST="$TMP/protected_repos_emptychan.md"
printf -- '- %s \xe2\x86\x92\n' "$PROTECTED" > "$EMPTY_CHAN_LIST"
out=$(edit_payload "$PROTECTED/CLAUDE.md" | PROTECTED_REPOS_FILE="$EMPTY_CHAN_LIST" CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "empty-channel line skipped" "" "$(caught "$out")"

# 15. No-space redirect glued to its target (echo x >../protected-repo/f.md)
#     -- shlex tokenizes ">../protected-repo/f.md" as a single token. Without
#     the redirect-strip, dirname on the glued string isn't a real directory,
#     resolution silently aborts, and the write goes through unchecked.
out=$(cd "$OUTSIDE" && bash_payload "echo x >../$(basename "$PROTECTED")/f.md" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "no-space redirect bash advised" '"additionalContext"' "$(caught "$out")"

# 16. No-space append redirect (echo x >>../protected-repo/f.md) -- same
#     glued-token failure mode as #15, with the two-char >> operator.
out=$(cd "$OUTSIDE" && bash_payload "echo x >>../$(basename "$PROTECTED")/f.md" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "no-space append-redirect bash advised" '"additionalContext"' "$(caught "$out")"

# 17. Glued key=value path argument (dd of=../protected-repo/f.md) -- no
#     space between the key and its value, so dirname on the glued string
#     isn't a real directory unless the key=value prefix is stripped first.
out=$(cd "$OUTSIDE" && bash_payload "dd of=../$(basename "$PROTECTED")/f.md" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "glued key=value bash advised" '"additionalContext"' "$(caught "$out")"

# 18. Glued --flag=value path argument (cp x --target-directory=../protected-repo)
#     -- pre-fix, the flag-skip case arm (--*|-*) discarded this token
#     outright before its value could ever be examined.
out=$(cd "$OUTSIDE" && bash_payload "cp x --target-directory=../$(basename "$PROTECTED")" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "glued --flag=value bash advised" '"additionalContext"' "$(caught "$out")"

# 19. An unbalanced quote must not silence the guard. shlex knows nothing of
#     heredoc syntax, so an apostrophe inside a heredoc body reads as an
#     unterminated quote and raises ValueError; swallowing that left the token
#     list empty and the hook mute for a command that plainly reaches into the
#     repo -- the advice went missing exactly where the command was knottiest.
#     bash_payload interpolates raw and cannot carry a newline inside a JSON
#     string, so this case builds its payload with json.dumps.
json_bash_payload() { # command
  python3 -c 'import json,sys; sys.stdout.write(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1"
}
APOSTROPHE_HEREDOC=$(printf "cat <<'EOF'\ndidn't work\nEOF\ncat %s/CLAUDE.md" "$PROTECTED")
out=$(json_bash_payload "$APOSTROPHE_HEREDOC" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "an unbalanced quote still advises" '"additionalContext"' "$(caught "$out")"
check "the fallback still names the channel" "1" "$(printf '%s' "$out" | grep -c 'mychan')"

# 20. The fallback is a substring scan, so it must not fire on a command that
#     never mentions a protected repo at all -- silence is still correct there.
UNRELATED_UNPARSABLE=$(printf "cat <<'EOF'\ndidn't work\nEOF\ncat %s/elsewhere.md" "$OUTSIDE")
out=$(json_bash_payload "$UNRELATED_UNPARSABLE" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "an unbalanced quote touching no protected repo stays silent" "" "$(caught "$out")"

# 21. The fallback must catch a RELATIVE reference too. A command that says
#     ../protected-repo/f.md never contains the repo's absolute path, so
#     matching only that missed the very shape these commands most often take
#     -- the token walk resolves relatives against the cwd, and the fallback,
#     having no tokens, has nothing to resolve. Matching the repo's basename
#     between separators covers it.
REL_UNPARSABLE=$(printf "cat <<'EOF'\ndidn't work\nEOF\ncat ../%s/CLAUDE.md" "$(basename "$PROTECTED")")
out=$(cd "$OUTSIDE" && json_bash_payload "$REL_UNPARSABLE" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "an unparsable relative reference still advises" '"additionalContext"' "$(caught "$out")"

if [ "$fail" -eq 0 ]; then
  echo "--- all green ---"
else
  echo "--- failures above ---"
  exit 1
fi
