# Protected-Repo Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Block direct edits to skadi and Minerva from any other repo's session, and give the blocked session a working next step: `/handoff send <channel> <your change>`.

**Architecture:** A new PreToolUse hook, `hooks/protected-repo-guard.sh`, registered on both the `Bash` matcher and the `Write|Edit|MultiEdit|NotebookEdit` matcher, reads a global (not per-project-memory) flat list of protected repos and denies any mutating call whose target resolves inside one — unless the session is already rooted there. `/remember` gains a root check so it redirects to `/handoff` instead of attempting a doomed write when run outside Minerva.

**Tech Stack:** Bash (3.2-compatible), `jq`, `python3` (for shlex tokenizing, matching `dir-guard.sh`'s existing approach), Claude Code hooks/skills.

## Global Constraints

- Every hook script must run clean under macOS bash 3.2 — no `${var,,}`, `declare -A`, `mapfile` (same trap `dir-guard.sh` and `handoff.sh` already navigate).
- PreToolUse hooks are harness-fired, not model-invoked via Bash — **no `permissions.allow` entry** is needed (confirmed: neither `dir-guard.sh` nor `worktree-guard.sh` appears in `permissions.allow` today).
- The protected-repo list lives at `~/.skadi/protected_repos.md` — a **global** flat file, never under any per-project auto-memory directory (auto-memory is scoped per project dir and would be invisible to a session rooted elsewhere) and **never propagated by `/install`** (same as `~/.skadi/handoff/` and `~/.skadi/moria/mend_repos.md`).
- No `CLAUDE_DEV_DIRS` escape hatch for protected repos — the guard check ignores it entirely.
- Missing or unparseable `~/.skadi/protected_repos.md` → fail open (hook exits 0, no protection), never a hard error that blocks unrelated work.
- The spec of record is `docs/superpowers/specs/2026-07-01-protected-repo-handoff-design.md`.

---

### Task 1: Bootstrap the global protected-repos list

**Files:**
- Create (untracked, global — not part of the skadi git repo): `~/.skadi/protected_repos.md`

**Interfaces:**
- Produces: a flat file, one line per protected repo, format `- <absolute-repo-root> → <channel-name>`. Consumed by Task 2's hook (`PROTECTED_REPOS_FILE` env override / `$HOME/.skadi/protected_repos.md` default) and referenced by Task 4's `/remember` update (informationally — `/remember` hardcodes the `minerva` channel name, it doesn't parse this file).

- [ ] **Step 1: Create the directory and seed file**

```bash
mkdir -p ~/.skadi
printf -- '- %s \xe2\x86\x92 skadi\n- %s \xe2\x86\x92 minerva\n' \
  "$HOME/skadi" "$HOME/phantom/Minerva" > ~/.skadi/protected_repos.md
```

- [ ] **Step 2: Verify the file's content**

Run: `cat ~/.skadi/protected_repos.md`

Expected output (two lines, using your actual skadi checkout path and Minerva root):

```
- /Users/larryhsiao/skadi → skadi
- /Users/larryhsiao/phantom/Minerva → minerva
```

If your skadi checkout isn't at `$HOME/skadi`, edit the file by hand to the correct path before continuing — Task 2's tests use a temp file and don't depend on this, but Task 5's end-to-end verification does.

No commit for this step — the file lives outside the skadi git repo by design.

---

### Task 2: Write `protected-repo-guard.sh` with its test suite

**Files:**
- Create: `hooks/protected-repo-guard.sh`
- Create: `hooks/protected-repo-guard.test.sh`

**Interfaces:**
- Consumes: `~/.skadi/protected_repos.md` format from Task 1 (or `$PROTECTED_REPOS_FILE` override for tests); `$CLAUDE_PROJECT_DIR` env var (same one `dir-guard.sh` reads) to identify the session's own root; PreToolUse hook JSON on stdin (`.tool_input.file_path`, `.tool_input.notebook_path`, `.tool_input.command`).
- Produces: a PreToolUse hook script at `hooks/protected-repo-guard.sh`, invoked directly by the test suite in this task and later registered in `settings.json` in Task 3. Denial JSON shape: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: <channel> is protected -- run \`/handoff send <channel> <your change>\` instead."}}`. Allow path: empty stdout, exit 0.

- [ ] **Step 1: Write the failing test suite**

Create `hooks/protected-repo-guard.test.sh`:

```bash
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

decision() {
  printf '%s' "$1" | grep -o '"permissionDecision":"[a-z]*"' | head -1
}

# 1. Edit inside the protected repo, session rooted there — allowed.
out=$(edit_payload "$PROTECTED/CLAUDE.md" | CLAUDE_PROJECT_DIR="$PROTECTED" "$HOOK")
check "self-edit allowed" "" "$(decision "$out")"

# 2. Edit inside the protected repo, session rooted outside — denied, names the channel.
out=$(edit_payload "$PROTECTED/CLAUDE.md" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "cross-repo edit denied" '"permissionDecision":"deny"' "$(decision "$out")"
check "denial names channel" "1" "$(printf '%s' "$out" | grep -c 'mychan')"

# 3. Edit inside an unrelated dir, session rooted outside — allowed.
out=$(edit_payload "$OUTSIDE/foo.md" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "unrelated edit allowed" "" "$(decision "$out")"

# 4. Bash command referencing the protected repo, session rooted outside — denied.
out=$(bash_payload "cat $PROTECTED/CLAUDE.md" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "cross-repo bash denied" '"permissionDecision":"deny"' "$(decision "$out")"

# 5. CLAUDE_DEV_DIRS listing the protected repo's parent does NOT exempt it.
out=$(bash_payload "cat $PROTECTED/CLAUDE.md" | CLAUDE_PROJECT_DIR="$OUTSIDE" CLAUDE_DEV_DIRS="$TMP" "$HOOK")
check "CLAUDE_DEV_DIRS does not exempt" '"permissionDecision":"deny"' "$(decision "$out")"

# 6. Missing list file — fails open, everything allowed.
out=$(edit_payload "$PROTECTED/CLAUDE.md" | PROTECTED_REPOS_FILE="$TMP/no-such-file.md" CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "missing list fails open" "" "$(decision "$out")"

# 7. Session rooted in a nested subdirectory of the protected repo — self-edit allowed.
out=$(edit_payload "$PROTECTED/sub/deep.md" | CLAUDE_PROJECT_DIR="$PROTECTED/sub" "$HOOK")
check "nested self-edit allowed" "" "$(decision "$out")"

if [ "$fail" -eq 0 ]; then
  echo "--- all green ---"
else
  echo "--- failures above ---"
  exit 1
fi
```

```bash
chmod +x hooks/protected-repo-guard.test.sh
```

- [ ] **Step 2: Run the test suite to verify it fails**

Run: `hooks/protected-repo-guard.test.sh`

Expected: fails immediately — `hooks/protected-repo-guard.sh` does not exist yet (`No such file or directory` / `command not found`).

- [ ] **Step 3: Write the minimal implementation**

Create `hooks/protected-repo-guard.sh`:

```bash
#!/bin/bash
# PreToolUse hook (Bash, Write|Edit|MultiEdit|NotebookEdit):
# Block a session rooted OUTSIDE a protected repo from mutating files inside
# it. Complements dir-guard.sh (home/project bounds) and worktree-guard.sh
# (same-repo cross-worktree) — this hook's one concern: "this repo is
# someone else's business unless you're already standing in it."
#
# Protected repos come from a global flat file, NOT auto-memory — auto-memory
# is scoped per project directory and would be invisible to a session rooted
# elsewhere (the same problem /moria solved for mend_repos.md).
# No CLAUDE_DEV_DIRS escape hatch: protected means protected.

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
PROJECT_DIR=$(cd "$RAW_PROJECT_DIR" 2>/dev/null && pwd -P || echo "$RAW_PROJECT_DIR")
PROJECT_DIR=$(normalize "$PROJECT_DIR")

REPOS=()
CHANNELS=()
while IFS= read -r line; do
  line="${line#- }"
  [ -z "$line" ] && continue
  repo="${line%%→*}"
  chan="${line#*→}"
  repo="$(printf '%s' "$repo" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  chan="$(printf '%s' "$chan" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -z "$repo" ] && continue
  REPOS+=("$(normalize "$repo")")
  CHANNELS+=("$chan")
done < "$LIST"

under() {
  case "$2" in
    "$1"|"$1"/*) return 0 ;;
  esac
  return 1
}

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: %s is protected -- run `/handoff send %s <your change>` instead."}}' "$1" "$1"
  exit 0
}

check_path() {
  local target
  target=$(normalize "$1")
  local i=0
  while [ "$i" -lt "${#REPOS[@]}" ]; do
    local repo="${REPOS[$i]}" chan="${CHANNELS[$i]}"
    if under "$repo" "$target" && ! under "$repo" "$PROJECT_DIR"; then
      deny "$chan"
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
    case "$TOKEN" in
      ~*|--*|-*|"") continue ;;
    esac
    if [[ "$TOKEN" =~ ^/[a-zA-Z] ]] || [[ "$TOKEN" =~ ^[A-Za-z]:\\ ]]; then
      check_path "$TOKEN"
    fi
  done <<< "$TOKENS"
fi

exit 0
```

```bash
chmod +x hooks/protected-repo-guard.sh
```

- [ ] **Step 4: Run the test suite to verify it passes**

Run: `hooks/protected-repo-guard.test.sh`

Expected: all 7 checks print `ok`, final line `--- all green ---`.

- [ ] **Step 5: Commit**

```bash
rtk git add hooks/protected-repo-guard.sh hooks/protected-repo-guard.test.sh
rtk git commit -m "feat(hooks): add protected-repo-guard.sh blocking cross-repo edits"
```

---

### Task 3: Wire the hook into `settings.json`

**Files:**
- Modify: `settings.json` (the `PreToolUse` → `Bash` matcher group, and the `PreToolUse` → `Write|Edit|MultiEdit|NotebookEdit` matcher group)

**Interfaces:**
- Consumes: `hooks/protected-repo-guard.sh` from Task 2 (invoked at `~/.claude/hooks/protected-repo-guard.sh` post-`/install`, matching how `dir-guard.sh` and `worktree-guard.sh` are already referenced).
- Produces: nothing new consumed by later tasks — this is the deployment wiring.

- [ ] **Step 1: Add the hook to the `Bash` matcher group**

In `settings.json`, find the `PreToolUse` → `Bash` matcher block (currently `dir-guard.sh` then `pre-commit-guard.sh`). Add a `protected-repo-guard.sh` entry between them:

```json
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "rtk hook claude" },
          {
            "type": "command",
            "command": "~/.claude/hooks/dir-guard.sh",
            "statusMessage": "Checking directory..."
          },
          {
            "type": "command",
            "command": "~/.claude/hooks/protected-repo-guard.sh",
            "statusMessage": "Checking protected repos..."
          },
          {
            "type": "command",
            "command": "~/.claude/hooks/pre-commit-guard.sh"
          }
        ]
      },
```

- [ ] **Step 2: Add the hook to the `Write|Edit|MultiEdit|NotebookEdit` matcher group**

Immediately below, find the `Write|Edit|MultiEdit|NotebookEdit` matcher block (currently only `worktree-guard.sh`). Add `protected-repo-guard.sh` alongside it:

```json
      {
        "matcher": "Write|Edit|MultiEdit|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/worktree-guard.sh",
            "statusMessage": "Checking worktree..."
          },
          {
            "type": "command",
            "command": "~/.claude/hooks/protected-repo-guard.sh",
            "statusMessage": "Checking protected repos..."
          }
        ]
      }
```

Do **not** add anything to `permissions.allow` — confirmed in the Global Constraints above, neither sibling hook needs an entry there.

- [ ] **Step 3: Verify `settings.json` is still valid JSON**

Run: `python3 -m json.tool settings.json > /dev/null && echo VALID`

Expected: `VALID`

- [ ] **Step 4: Verify both matcher groups reference the new hook**

Run: `grep -c "protected-repo-guard.sh" settings.json`

Expected: `2`

- [ ] **Step 5: Commit**

```bash
rtk git add settings.json
rtk git commit -m "feat(hooks): register protected-repo-guard.sh in settings.json"
```

---

### Task 4: Redirect `/remember` through `/handoff` when outside Minerva

**Files:**
- Modify: `skills/remember/SKILL.md` (Step 0)

**Interfaces:**
- Consumes: `~/.claude/hooks/handoff.sh send minerva` (the existing `handoff.sh` hook, unmodified — see `skills/handoff/SKILL.md`'s documented `send` verb, which reads the message body from stdin).
- Produces: no new interface — this task only changes when Steps 1/4/5 of `/remember` run versus when the new Step 0b runs instead.

- [ ] **Step 1: Edit Step 0 to add the root check**

In `skills/remember/SKILL.md`, replace the existing `### Step 0: Resolve the Minerva root` section:

````markdown
### Step 0: Resolve the Minerva root

Before anything else, resolve the absolute path to the Minerva repo and use it for
every file and git operation in the steps that follow:

```bash
MINERVA_ROOT="${MINERVA_ROOT:-$HOME/phantom/Minerva}"
```

The `MINERVA_ROOT` env var is the override; the `~/phantom/Minerva` fallback is the
default when it is unset. Confirm the path exists (`test -d "$MINERVA_ROOT"`); if it
does not, tell the user plainly and stop — do not write the note into the cwd.

All paths named below (`work/…`, `personal/…`) are **relative to `$MINERVA_ROOT`**.
Read, write, and commit against the absolute path; never against the working
directory the session happens to sit in.
````

with:

````markdown
### Step 0: Resolve the Minerva root, and check whether this session is rooted there

Before anything else, resolve the absolute path to the Minerva repo:

```bash
MINERVA_ROOT="${MINERVA_ROOT:-$HOME/phantom/Minerva}"
```

The `MINERVA_ROOT` env var is the override; the `~/phantom/Minerva` fallback is the
default when it is unset. Confirm the path exists (`test -d "$MINERVA_ROOT"`); if it
does not, tell the user plainly and stop — do not write the note into the cwd.

**Then check the session's own root against it:**

```bash
SESSION_ROOT=$(cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null && pwd -P)
```

- **If `$SESSION_ROOT` is `$MINERVA_ROOT` or nested under it** — proceed with Steps
  1–5 below exactly as written; every file and git operation targets `$MINERVA_ROOT`.
- **Otherwise** — this session is rooted outside Minerva, and a direct write would
  be blocked by `protected-repo-guard.sh` anyway. Skip straight to **Step 0b**
  below instead of Steps 1, 4, and 5.

All paths named below (`work/…`, `personal/…`) are **relative to `$MINERVA_ROOT`**.
Read, write, and commit against the absolute path; never against the working
directory the session happens to sit in.

### Step 0b: Redirect through /handoff (only when outside Minerva)

Still run **Step 2 (category)** and **Step 3 (sub-category)** below to shape the
note correctly — that judgment doesn't need Minerva's tree, only the user's input.
Skip **Step 1** (duplicate check — it greps the live Minerva tree, unreachable from
here) and **Steps 4–5** (the direct write/commit/push).

Compose the note body exactly as Step 4 describes (title, company blockquote if
under `work/`, content, date line) but prefix it with the intended path as a
heading, so the receiving session knows where to file it:

```markdown
# Intended path: <category>/<sub-folder>/<filename>.md

<the note content, per Step 4>
```

Send it:

```bash
printf '%s' "<composed note>" | ~/.claude/hooks/handoff.sh send minerva
```

Tell the user plainly: *"Not rooted in Minerva — queued this note on the `minerva`
handoff channel instead of writing directly. Open a Minerva session and run
`/handoff read minerva` to file it."* Do not proceed to Steps 4–5.
````

- [ ] **Step 2: Verify the edit**

Run: `grep -c "Step 0b" skills/remember/SKILL.md`

Expected: `3` (the heading, plus two references to it from the new Step 0 text).

- [ ] **Step 3: Manual verification (no automated test — SKILL.md is model-read instructions, not executable code)**

From a Claude Code session rooted in a directory that is *not* Minerva, run
`/remember "test note about nothing in particular"`.

Expected:
- No file is created anywhere under `$HOME/phantom/Minerva`.
- The session reports the note was queued on the `minerva` handoff channel.
- `~/.claude/hooks/handoff.sh read minerva` shows the queued note, headed
  `# Intended path: ...`.

- [ ] **Step 4: Commit**

```bash
rtk git add skills/remember/SKILL.md
rtk git commit -m "feat(remember): redirect through /handoff when outside Minerva"
```

---

### Task 5: Propagate and run end-to-end verification

**Files:** none (deployment + manual verification only)

**Interfaces:**
- Consumes: everything from Tasks 1–4.

- [ ] **Step 1: Propagate via `/install`**

Invoke the `/install` skill (or, if working outside a live Claude Code session,
run `./install.sh ~/.claude` and repeat for every other configured root — see
`claude_config_roots.md`). Confirm its output lists `hooks/protected-repo-guard.sh`
and `skills/remember/SKILL.md` as installed/up to date for each root.

- [ ] **Step 2: Verify acceptance criterion 1 — blocked skadi edit names the channel**

From a Claude Code session rooted in some *other* project, attempt to edit a file
under your skadi checkout (e.g. `Edit` on `<skadi-root>/CLAUDE.md`).

Expected: the edit is denied, and the denial reads
`Blocked: skadi is protected -- run \`/handoff send skadi <your change>\` instead.`

- [ ] **Step 3: Verify acceptance criterion 2 — `/remember` redirects outside Minerva**

Already covered by Task 4 Step 3 — re-run it now that the hook is live via `/install`
(previously it only ran against the repo-local `hooks/` copy through direct script
invocation in Task 2's tests) to confirm the *installed* `~/.claude/hooks/` copy
behaves the same way.

- [ ] **Step 4: Verify acceptance criteria 3–4 — self-edits and self-`/remember` are unaffected**

From a session rooted *inside* skadi, edit a skadi file — expect no denial, no
change from prior behavior. From a session rooted *inside* Minerva, run
`/remember "test note"` — expect it still writes, commits, and pushes directly.

- [ ] **Step 5: Verify acceptance criterion 5 — no `CLAUDE_DEV_DIRS` escape hatch**

Already covered by Task 2's automated test ("CLAUDE_DEV_DIRS does not exempt").
No additional manual step needed — note this in the final report as
test-covered rather than re-run by hand.

- [ ] **Step 6: Verify acceptance criterion 6 — `/handoff read` surfaces both channels**

Run `/handoff read skadi` and `/handoff read minerva` from any session. Expect
both to print whatever messages were queued during Steps 2–3 above.

- [ ] **Step 7: Verify acceptance criterion 7 — bash 3.2 compatibility**

Run: `/bin/bash hooks/protected-repo-guard.test.sh`

Expected: same `--- all green ---` result as Task 2 Step 4, now specifically
under `/bin/bash` (bash 3.2 on macOS) rather than whatever `#!/usr/bin/env bash`
resolved to.

No commit for this task — verification only.
