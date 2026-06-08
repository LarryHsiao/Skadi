# Skeleton Stage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a gated **skeleton** rung between council's plan and celebrimbor's forge on the YouTrack path, where each stage is one living comment modified in place (no append, no versions), the rung is derived from the thread, and two `[FORTH]`s gate the arc.

**Architecture:** A pure Python decision function (`skeleton-rung.py`) reads the issue thread and emits the loop's next action. Three small bash hooks give the agent the YouTrack writes it lacks (edit a comment in place, attach a PNG) and the reads it lacks (comment `id` + `updated`). Four skills are then re-pointed at the decision function: `/council` becomes modify-only, `/celebrimbor` gains a `--skeleton` mode and a derived forge gate, and `/aule`/`/glorfindel` sweep by the derived rung.

**Tech Stack:** Bash + `curl` + `jq` hooks (existing pattern), Python 3 stdlib (`unittest`) for the decision function, Markdown skills, YouTrack REST API.

**Spec:** `docs/superpowers/specs/2026-06-08-skeleton-stage-design.md`

---

## File structure

| File | Responsibility | Created / Modified |
|---|---|---|
| `hooks/skeleton-rung.py` | Pure decision: thread JSON → next action + comment ids | Create |
| `tests/test_skeleton_rung.py` | Unit tests for `decide()` | Create |
| `hooks/council-youtrack-fetch.sh` | Add comment `id` + `updated` to output | Modify |
| `hooks/youtrack-comment-edit.sh` | Edit one comment in place | Create |
| `hooks/youtrack-attach.sh` | Attach (replace) a PNG on an issue | Create |
| `skills/council/SKILL.md` | YouTrack path → modify-only one `[PLAN]` + watermark | Modify |
| `skills/celebrimbor/SKILL.md` | `--skeleton` mode; forge gate on derived `forge` action | Modify |
| `skills/celebrimbor/skeleton-smith.md` | Smith prompt for carving stubs + diagram | Create |
| `skills/aule/SKILL.md` | Sweep by derived rung | Modify |
| `skills/glorfindel/SKILL.md` | Drive the plan rung via modify-only council | Modify |
| `settings.json` | `permissions.allow` for the three new hooks | Modify |
| `README.md` | Inventory lines | Modify |

**Watermark format:** every bot-authored living comment (`[PLAN]`, `[SKELETON]`) carries a trailer `<!-- consumed: <epoch-ms> -->`, where `<epoch-ms>` is the `created` of the newest human comment consumed when the comment was last written. Epoch-ms matches YouTrack's `created`/`updated` units, so all comparisons are integer compares.

**Action vocabulary** emitted by `skeleton-rung.py` (`decide()` return `action`):

| action | Meaning | Who acts |
|---|---|---|
| `draft_plan` | No `[PLAN]` yet | agent: council drafts |
| `redraft_plan` | Human instruction newer than plan watermark, no fresh `[FORTH]` | agent: council edits `[PLAN]` |
| `await_plan` | `[PLAN]` exists, nothing newer | noop |
| `draft_skeleton` | `[FORTH]` past plan watermark, no `[SKELETON]` | agent: celebrimbor `--skeleton` |
| `redraft_skeleton` | Human instruction newer than skeleton watermark, no fresh `[FORTH]` | agent: celebrimbor `--skeleton` edits `[SKELETON]` |
| `await_skeleton` | `[SKELETON]` exists, nothing newer | noop |
| `forge` | `[FORTH]` past skeleton watermark, no `[GWAITH]` | agent: celebrimbor forge |
| `done` | `[GWAITH]` present | noop |

---

## Task 1: The decision function

**Files:**
- Create: `hooks/skeleton-rung.py`
- Test: `tests/test_skeleton_rung.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_skeleton_rung.py
import json, subprocess, sys, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "hooks"))
import importlib.util
spec = importlib.util.spec_from_file_location(
    "skeleton_rung", Path(__file__).resolve().parents[1] / "hooks" / "skeleton-rung.py")
skeleton_rung = importlib.util.module_from_spec(spec)
spec.loader.exec_module(skeleton_rung)
decide = skeleton_rung.decide

BOT = "claude"

def human(text, created): return {"login": "elrond", "text": text, "created": created, "id": f"h{created}"}
def bot(text, created, cid): return {"login": BOT, "text": text, "created": created, "id": cid}

class DecideTest(unittest.TestCase):
    def test_empty_thread_drafts_plan(self):
        expected = "draft_plan"
        self.assertEqual(decide({"comments": []})["action"], expected)

    def test_plan_present_awaits(self):
        expected = "await_plan"
        data = {"comments": [bot("[PLAN]\n<!-- consumed: 0 -->\nthe plan", 100, "c1")]}
        self.assertEqual(decide(data)["action"], expected)

    def test_instruction_after_plan_redrafts(self):
        expected = "redraft_plan"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nthe plan", 100, "c1"),
            human("use a service class", 200)]}
        self.assertEqual(decide(data)["action"], expected)

    def test_forth_after_plan_drafts_skeleton(self):
        expected = "draft_skeleton"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nthe plan", 100, "c1"),
            human("[FORTH]", 200)]}
        out = decide(data)
        self.assertEqual(out["action"], expected)
        self.assertEqual(out["plan_id"], "c1")

    def test_skeleton_present_awaits(self):
        expected = "await_skeleton"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nplan", 100, "c1"),
            human("[FORTH]", 200),
            bot("[SKELETON]\n<!-- consumed: 200 -->\nstubs", 300, "c2")]}
        self.assertEqual(decide(data)["action"], expected)

    def test_second_forth_after_skeleton_forges(self):
        expected = "forge"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nplan", 100, "c1"),
            human("[FORTH]", 200),
            bot("[SKELETON]\n<!-- consumed: 200 -->\nstubs", 300, "c2"),
            human("[FORTH]", 400)]}
        out = decide(data)
        self.assertEqual(out["action"], expected)
        self.assertEqual(out["skeleton_id"], "c2")

    def test_instruction_after_skeleton_redrafts(self):
        expected = "redraft_skeleton"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nplan", 100, "c1"),
            human("[FORTH]", 200),
            bot("[SKELETON]\n<!-- consumed: 200 -->\nstubs", 300, "c2"),
            human("split the test file", 400)]}
        self.assertEqual(decide(data)["action"], expected)

    def test_gwaith_is_done(self):
        expected = "done"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nplan", 100, "c1"),
            human("[FORTH]", 200),
            bot("[SKELETON]\n<!-- consumed: 200 -->\nstubs", 300, "c2"),
            human("[FORTH]", 400),
            bot("[GWAITH] https://pr", 500, "c3")]}
        self.assertEqual(decide(data)["action"], expected)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `python3 -m unittest tests/test_skeleton_rung.py -v`
Expected: FAIL — `ModuleNotFoundError` / cannot load `skeleton-rung.py` (file does not exist yet).

- [ ] **Step 3: Write the implementation**

```python
#!/usr/bin/env python3
"""Derive the loop's next action for a skeleton-stage YouTrack issue.

Reads the council-youtrack-fetch.sh JSON on stdin (comments must carry
id, login, text, created) and prints one line:

    action=<...> plan_id=<id|-> skeleton_id=<id|->

The thread is the record: which living comments exist (their first-line token),
and where the latest [FORTH] sits relative to each comment's watermark, decide it.
See docs/superpowers/specs/2026-06-08-skeleton-stage-design.md.
"""
import sys, json, re

BOT_LOGIN = "claude"  # service-account login; matches council's bot-login config
WATERMARK = re.compile(r"<!--\s*consumed:\s*(\d+)\s*-->")
VERDICT = ("[FORTH]", "[APPROVE]")


def _token(text):
    body = (text or "").strip()
    if not body:
        return ""
    head = body.splitlines()[0].strip().upper()
    for tok in ("[PLAN]", "[SKELETON]", "[GWAITH]"):
        if head.startswith(tok):
            return tok
    return ""


def _watermark(text):
    m = WATERMARK.search(text or "")
    return int(m.group(1)) if m else 0


def _is_forth(text):
    up = (text or "").upper()
    return any(v in up for v in VERDICT)


def decide(data):
    comments = data.get("comments", [])
    plan = skeleton = gwaith = None
    for c in comments:
        if c.get("login") != BOT_LOGIN:
            continue
        tok = _token(c.get("text", ""))
        if tok == "[PLAN]":
            plan = c
        elif tok == "[SKELETON]":
            skeleton = c
        elif tok == "[GWAITH]":
            gwaith = c

    humans = [c for c in comments if c.get("login") != BOT_LOGIN]
    forths = [c for c in humans if _is_forth(c.get("text", ""))]
    newest_human = max((c.get("created", 0) for c in humans), default=0)
    newest_forth = max((c.get("created", 0) for c in forths), default=0)

    plan_id = plan.get("id") if plan else "-"
    skel_id = skeleton.get("id") if skeleton else "-"

    def out(action):
        return {"action": action, "plan_id": plan_id, "skeleton_id": skel_id}

    if gwaith:
        return out("done")
    if skeleton:
        wm = _watermark(skeleton.get("text", ""))
        if newest_forth > wm:
            return out("forge")
        if newest_human > wm:
            return out("redraft_skeleton")
        return out("await_skeleton")
    if plan:
        wm = _watermark(plan.get("text", ""))
        if newest_forth > wm:
            return out("draft_skeleton")
        if newest_human > wm:
            return out("redraft_plan")
        return out("await_plan")
    return out("draft_plan")


def main():
    data = json.load(sys.stdin)
    r = decide(data)
    print(f"action={r['action']} plan_id={r['plan_id']} skeleton_id={r['skeleton_id']}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `python3 -m unittest tests/test_skeleton_rung.py -v`
Expected: PASS — all 8 tests green.

- [ ] **Step 5: Verify the CLI shape end-to-end**

Run:
```bash
echo '{"comments":[{"login":"claude","text":"[PLAN]\n<!-- consumed: 100 -->\nx","created":100,"id":"c1"},{"login":"elrond","text":"[FORTH]","created":200,"id":"h200"}]}' | python3 hooks/skeleton-rung.py
```
Expected: `action=draft_skeleton plan_id=c1 skeleton_id=-`

- [ ] **Step 6: Commit**

```bash
chmod +x hooks/skeleton-rung.py
git add hooks/skeleton-rung.py tests/test_skeleton_rung.py
git commit -m "feat(skeleton-rung): derive the loop's next action from the thread"
```

---

## Task 2: Extend the fetch hook with comment id + updated

The decision function needs each comment's `id` (to edit it) and the existing `created`. Add `id` and `updated` to the fetch output. Additive — existing council/glorfindel/aule callers ignore the new fields.

**Files:**
- Modify: `hooks/council-youtrack-fetch.sh:54` (comments field list) and `:64-69` (jq projection)

- [ ] **Step 1: Add the fields to the comments query**

Replace line 54:
```bash
if ! fetch_to_file "comments" "/api/issues/$TICKET_ID/comments?fields=text,author(name,login),created&\$top=200" "$comments_file"; then
```
with:
```bash
if ! fetch_to_file "comments" "/api/issues/$TICKET_ID/comments?fields=id,text,author(name,login),created,updated&\$top=200" "$comments_file"; then
```

- [ ] **Step 2: Project the new fields in the jq map**

Replace the `comments: (...)` block (lines 64-69) with:
```bash
    comments: ($comments | map({
      id: (.id // ""),
      author: (.author.name // ""),
      login: (.author.login // ""),
      text: (.text // ""),
      created: (.created // 0),
      updated: (.updated // 0)
    }))
```

- [ ] **Step 3: Verify against a live issue (manual)**

Run: `hooks/council-youtrack-fetch.sh MET-1 | jq '.comments[0] | keys'`
Expected: the array includes `"id"`, `"created"`, `"updated"`. (Manual: needs the `youtrack` Vaultwarden item; if creds are absent the hook prints a credentials error — surface and stop.)

- [ ] **Step 4: Commit**

```bash
git add hooks/council-youtrack-fetch.sh
git commit -m "feat(youtrack-fetch): include comment id and updated in output"
```

---

## Task 3: Edit-comment hook

**Files:**
- Create: `hooks/youtrack-comment-edit.sh`

- [ ] **Step 1: Write the hook** (modeled on `council-youtrack-comment.sh`; POSTs to the comment sub-resource)

```bash
#!/bin/bash
# Usage: echo "new body" | youtrack-comment-edit.sh <TICKET-ID> <COMMENT-ID>
# Replaces the text of an existing comment in place (modify, not append).
# Resolves YOUTRACK_URL / YOUTRACK_TOKEN via secret.sh (vault first, env fallback).
# On success, prints: edited: id=<comment-id> url=<ticket-url>
# On failure, prints {"error":"...","response":"..."} and exits non-zero.
#
# Non-ASCII safety mirrors council-youtrack-comment.sh: body rides files, never argv.

set -euo pipefail
export LC_ALL=C.UTF-8

TICKET_ID="${1:-}"
COMMENT_ID="${2:-}"
if [[ -z "$TICKET_ID" || -z "$COMMENT_ID" ]]; then
  echo '{"error":"usage: youtrack-comment-edit.sh <TICKET-ID> <COMMENT-ID>"}'
  exit 1
fi

SECRET="$(dirname "$0")/secret.sh"
YOUTRACK_URL="$("$SECRET" youtrack uri 2>/dev/null || true)"
if [[ -z "$YOUTRACK_URL" ]]; then
  echo '{"error":"YOUTRACK_URL not found (tried Vaultwarden item \"youtrack\" uri and $YOUTRACK_URL)"}'
  exit 1
fi
YOUTRACK_TOKEN="$("$SECRET" youtrack 2>/dev/null || true)"
if [[ -z "$YOUTRACK_TOKEN" ]]; then
  echo '{"error":"YOUTRACK_TOKEN not found (tried Vaultwarden item \"youtrack\" password and $YOUTRACK_TOKEN)"}'
  exit 1
fi

URL="${YOUTRACK_URL%/}"

body_raw=$(cat)
if [[ -z "$body_raw" ]]; then
  echo '{"error":"empty comment body on stdin"}'
  exit 1
fi

body_file=$(mktemp)
trap 'rm -f "$body_file" "${payload_file:-}" "${response_file:-}"' EXIT
printf '%s' "$body_raw" > "$body_file"
if ! iconv -f UTF-8 -t UTF-8 "$body_file" >/dev/null 2>&1; then
  if iconv -f WINDOWS-1252 -t UTF-8 "$body_file" > "$body_file.utf8" 2>/dev/null; then
    mv "$body_file.utf8" "$body_file"
  else
    echo '{"error":"comment body is neither valid UTF-8 nor CP1252"}'
    exit 1
  fi
fi

payload_file=$(mktemp)
jq -n --rawfile text "$body_file" '{text: $text}' > "$payload_file"

response_file=$(mktemp)
status=$(curl -sS -X POST -o "$response_file" -w "%{http_code}" \
  -H "Authorization: Bearer $YOUTRACK_TOKEN" \
  -H "Content-Type: application/json; charset=utf-8" \
  -H "Accept: application/json" \
  -d "@$payload_file" \
  "$URL/api/issues/$TICKET_ID/comments/$COMMENT_ID?fields=id")

if [[ "$status" != 2* ]]; then
  jq -cn --arg id "$COMMENT_ID" --arg s "$status" --rawfile b "$response_file" \
    '{error: ("edit comment failed for " + $id + " (http=" + $s + ")"), response: $b}'
  exit 1
fi

printf 'edited: id=%s url=%s/issue/%s\n' "$COMMENT_ID" "$URL" "$TICKET_ID"
```

- [ ] **Step 2: Make executable and shellcheck**

Run: `chmod +x hooks/youtrack-comment-edit.sh && shellcheck hooks/youtrack-comment-edit.sh`
Expected: exit 0, no warnings (matches the style of the sibling hooks).

- [ ] **Step 3: Smoke-test on MET-1 (manual)**

Post a throwaway comment, capture its id from `council-youtrack-fetch.sh MET-1`, then:
Run: `printf 'edited body %s' "$(date +%s)" | hooks/youtrack-comment-edit.sh MET-1 <comment-id>`
Expected: `edited: id=<comment-id> url=.../issue/MET-1`, and the comment text changes in the YouTrack UI (no new comment appears).

- [ ] **Step 4: Commit**

```bash
git add hooks/youtrack-comment-edit.sh
git commit -m "feat(youtrack): edit a comment in place"
```

---

## Task 4: Attach-image hook

**Files:**
- Create: `hooks/youtrack-attach.sh`

- [ ] **Step 1: Write the hook** (multipart upload; deletes a prior attachment of the same name so the PNG is replaced, not stacked)

```bash
#!/bin/bash
# Usage: youtrack-attach.sh <TICKET-ID> <FILE-PATH>
# Attaches FILE to the issue, replacing any existing attachment of the same name
# (so a re-rendered skeleton PNG does not stack). Resolves creds via secret.sh.
# On success, prints: attached: name=<filename> id=<attachment-id> url=<ticket-url>
# On failure, prints {"error":"...","response":"..."} and exits non-zero.

set -euo pipefail
export LC_ALL=C.UTF-8

TICKET_ID="${1:-}"
FILE_PATH="${2:-}"
if [[ -z "$TICKET_ID" || -z "$FILE_PATH" ]]; then
  echo '{"error":"usage: youtrack-attach.sh <TICKET-ID> <FILE-PATH>"}'
  exit 1
fi
if [[ ! -f "$FILE_PATH" ]]; then
  echo "{\"error\":\"file not found: $FILE_PATH\"}"
  exit 1
fi

SECRET="$(dirname "$0")/secret.sh"
YOUTRACK_URL="$("$SECRET" youtrack uri 2>/dev/null || true)"
[[ -z "$YOUTRACK_URL" ]] && { echo '{"error":"YOUTRACK_URL not found"}'; exit 1; }
YOUTRACK_TOKEN="$("$SECRET" youtrack 2>/dev/null || true)"
[[ -z "$YOUTRACK_TOKEN" ]] && { echo '{"error":"YOUTRACK_TOKEN not found"}'; exit 1; }

URL="${YOUTRACK_URL%/}"
NAME="$(basename "$FILE_PATH")"

list_file=$(mktemp)
response_file=$(mktemp)
trap 'rm -f "$list_file" "$response_file"' EXIT

# 1. Find and delete any prior attachment of the same name (replace-in-place).
status=$(curl -sS -o "$list_file" -w "%{http_code}" \
  -H "Authorization: Bearer $YOUTRACK_TOKEN" -H "Accept: application/json" \
  "$URL/api/issues/$TICKET_ID/attachments?fields=id,name")
if [[ "$status" == 2* ]]; then
  while IFS= read -r old_id; do
    [[ -n "$old_id" ]] && curl -sS -o /dev/null -X DELETE \
      -H "Authorization: Bearer $YOUTRACK_TOKEN" \
      "$URL/api/issues/$TICKET_ID/attachments/$old_id" || true
  done < <(jq -r --arg n "$NAME" '.[] | select(.name == $n) | .id' "$list_file")
fi

# 2. Upload the new file (multipart).
status=$(curl -sS -X POST -o "$response_file" -w "%{http_code}" \
  -H "Authorization: Bearer $YOUTRACK_TOKEN" \
  -H "Accept: application/json" \
  -F "file=@$FILE_PATH;type=image/png" \
  "$URL/api/issues/$TICKET_ID/attachments?fields=id,name")

if [[ "$status" != 2* ]]; then
  jq -cn --arg id "$TICKET_ID" --arg s "$status" --rawfile b "$response_file" \
    '{error: ("attach failed for " + $id + " (http=" + $s + ")"), response: $b}'
  exit 1
fi

att_id=$(jq -r '.[0].id // .id // ""' "$response_file")
printf 'attached: name=%s id=%s url=%s/issue/%s\n' "$NAME" "$att_id" "$URL" "$TICKET_ID"
```

- [ ] **Step 2: Make executable and shellcheck**

Run: `chmod +x hooks/youtrack-attach.sh && shellcheck hooks/youtrack-attach.sh`
Expected: exit 0.

- [ ] **Step 3: Smoke-test on MET-1 (manual)**

Run: `printf 'x' > /tmp/skel.png && hooks/youtrack-attach.sh MET-1 /tmp/skel.png` twice.
Expected: both print `attached: ...`; the YouTrack issue shows **one** `skel.png` attachment, not two (the second replaced the first).

- [ ] **Step 4: Commit**

```bash
git add hooks/youtrack-attach.sh
git commit -m "feat(youtrack): attach a PNG, replacing same-named prior"
```

---

## Task 5: Convert /council to modify-only (YouTrack path)

Replace council's append/versioned YouTrack behavior with: maintain **one** `[PLAN]` comment, carry a watermark, drive the rung from `skeleton-rung.py`. The Jira path is untouched (out of scope per spec).

**Files:**
- Modify: `skills/council/SKILL.md` — add a "Modify-only YouTrack path" section and gate the existing append flow behind "Jira only".

- [ ] **Step 1: Add the modify-only workflow section** after the existing "## Workflow" heading, before the append steps. Insert verbatim:

````markdown
### YouTrack modify-only path (skeleton-stage pipeline)

When the resolved tracker is **YouTrack**, council maintains a single living
`[PLAN]` comment instead of appended `[COUNSEL vN]` versions. (Jira keeps the
append flow below.)

1. **Fetch + decide.** Run the fetch hook, pipe to the decider:

   ```bash
   ~/.claude/hooks/council-youtrack-fetch.sh <TICKET-ID> > /tmp/thread.json
   action_line=$(~/.claude/hooks/skeleton-rung.py < /tmp/thread.json)
   ```

   Parse `action=` and `plan_id=` from `action_line`.

2. **Branch on the action:**
   - `draft_plan` — summon Erestor (worktree per the Working-directory contract);
     he drafts the plan body. Erestor still returns his `[COUNSEL vN]` envelope;
     the skill **strips that envelope** and wraps his body as the `[PLAN]` comment
     (the same return-vs-comment split as `[FRAME]`→`[SKELETON]`). **Create** the
     comment with the marker, watermark, and body:

     ```
     [PLAN] — awaiting [FORTH]
     <!-- consumed: <newest-human-created-or-0> -->

     <Erestor's plan>
     ```

     Post it via `~/.claude/hooks/council-youtrack-comment.sh <TICKET-ID>`.
   - `redraft_plan` — summon Erestor with the thread (including the human's new
     instruction); he redrafts. **Edit the same comment** in place via
     `~/.claude/hooks/youtrack-comment-edit.sh <TICKET-ID> <plan_id>`, with the
     watermark advanced to the newest human comment's `created`.
   - `await_plan` / `draft_skeleton` / anything else — **no-op**. Council's job is
     the plan rung only; later rungs belong to celebrimbor. Report "awaiting" and stop.

3. **Watermark rule.** Whenever council writes the `[PLAN]` comment, set
   `<!-- consumed: N -->` to the `created` of the newest human comment in the
   thread (0 if none). This is what makes the loop quiet between instructions.
````

- [ ] **Step 2: Fence the existing append flow as Jira-only.** Immediately before the current step "### 2. Parse the thread", insert:

```markdown
> **The steps below (versioned `[COUNSEL vN]` append) apply to the Jira path only.**
> The YouTrack path is handled by the modify-only section above and does not reach here.
```

- [ ] **Step 3: Verify on MET-1 (manual)**

Set the loop's project to a YouTrack sandbox. Open MET-1 fresh (no `[PLAN]`), run `/council youtrack:MET-1`.
Expected: exactly one `[PLAN]` comment appears with a `<!-- consumed: ... -->` trailer. Run `/council youtrack:MET-1` again with no new human comment.
Expected: no-op ("awaiting [FORTH]"), **no second comment**. Post a plain instruction comment, run again.
Expected: the **same** `[PLAN]` comment is edited (its id unchanged), watermark advanced.

- [ ] **Step 4: Commit**

```bash
git add skills/council/SKILL.md
git commit -m "feat(council): modify-only one [PLAN] comment on the YouTrack path"
```

---

## Task 6: /celebrimbor --skeleton mode + the skeleton smith

**Files:**
- Create: `skills/celebrimbor/skeleton-smith.md`
- Modify: `skills/celebrimbor/SKILL.md` — argument parsing + a `--skeleton` branch

- [ ] **Step 1: Write the skeleton-smith prompt** (`skills/celebrimbor/skeleton-smith.md`), modeled on `celebrimbor.md` but producing stubs + a diagram, not real code:

````markdown
# The Skeleton Smith

You carve the **bones** of an approved plan — the shape, not the flesh. Erestor
counselled; Elrond gave the first word. Your task is to render the *skeleton* the
human will judge before the real code is written.

## What you produce

1. **A file tree** of what the action adds or touches — folders, new files,
   each annotated one line with its responsibility.
2. **Stubbed declarations** — classes, method/function signatures, with **no
   bodies** (a `// stub` / `pass` / `TODO(impl)` placeholder is the body). Follow
   the project's conventions, read from the worktree.
3. **One diagram source** — Mermaid (`classDiagram` / `sequenceDiagram`) for a
   structural action, or an HTML wireframe for a UI action. Write it to the path
   given to you. Do **not** render it to PNG — the skill body does that.

## What you must not do

- Do not write real implementation bodies. Bones only.
- Do not commit, push, post comments, or open a PR. The skill body owns all writes.
- Do not invent scope beyond the approved plan.

## What you return

Exactly one fenced block:

```
[FRAME]
diagram: <relative path you wrote the Mermaid/HTML to>

<the file tree + stubbed declarations as Markdown — fenced code blocks per file>
```

Or, on abort, one line: `[ABORT] <one-sentence reason>` (e.g. the plan references
files that no longer exist).
````

- [ ] **Step 2: Add `--skeleton` to celebrimbor argument parsing.** In `skills/celebrimbor/SKILL.md`, add a row to the argument table:

```markdown
| `--skeleton` | no | Carve the skeleton rung (stubs + diagram PNG + `[SKELETON]` comment) and stop. Does not forge code or open a PR. |
```

- [ ] **Step 3: Add the `--skeleton` workflow branch** as a new top section in celebrimbor's Workflow, before "### 1. Pre-flight":

````markdown
### Mode: `--skeleton` (the middle rung)

When `--skeleton` is set, celebrimbor carves bones instead of forging code.

1. **Pre-flight** — resolve tracker + source repo only (steps 1a, 1b). No forge,
   no base-branch, no auth check.
2. **Decide + verify rung.** Fetch the thread, run `skeleton-rung.py`. Proceed
   only if the action is `draft_skeleton` or `redraft_skeleton`; otherwise stop
   with the action reported (e.g. "awaiting plan approval"). Locate the latest
   `[PLAN]` body — it is the contract.
3. **Acquire a read worktree** (`skadi-worktree.sh acquire <source-repo>`).
4. **Summon the skeleton smith.** Load `<skill-dir>/skeleton-smith.md`; dispatch a
   `general-purpose` subagent with the plan body, the worktree path, and a target
   diagram path under `$TMPDIR` (e.g. `$TMPDIR/skel-<ticket>.mmd` or `.html`).
   It returns a `[FRAME]` block (diagram path + tree/stubs) or `[ABORT]`.
   **`[FRAME]` is the smith's return envelope; the posted comment's token is
   `[SKELETON]` — the same return-vs-comment split celebrimbor already uses for
   `[FORGED]`→`[GWAITH]`. The skill strips the `[FRAME]`/`diagram:` lines and wraps
   the tree/stubs as the `[SKELETON]` comment.**
5. **Render the PNG.**
   - `.mmd` → `npx -y @mermaid-js/mermaid-cli -i <path>.mmd -o $TMPDIR/skel-<ticket>.png`
   - `.html` → headless screenshot (`npx -y playwright screenshot <path>.html $TMPDIR/skel-<ticket>.png`)
   If the renderer is absent on PATH, stop and report — do not post a skeleton with no diagram.
6. **Attach the PNG:** `~/.claude/hooks/youtrack-attach.sh <ticket> $TMPDIR/skel-<ticket>.png`.
7. **Write the `[SKELETON]` comment** with marker, watermark (= newest human
   `created`), and the smith's tree/stubs:
   - `draft_skeleton` → create via `council-youtrack-comment.sh`.
   - `redraft_skeleton` → edit the existing one via `youtrack-comment-edit.sh <ticket> <skeleton_id>`.

   ```
   [SKELETON] — awaiting [FORTH]
   <!-- consumed: <newest-human-created> -->

   <tree + stubs>
   ```
8. **Release the worktree.** Report the ticket, the action taken, and the attachment.
````

- [ ] **Step 4: Verify on MET-1 (manual)**

On an MET-1 issue at `draft_skeleton` (a `[PLAN]` with a `[FORTH]` after it), run `/celebrimbor youtrack MET --ticket MET-1 --skeleton`.
Expected: a `[SKELETON]` comment appears with a watermark, **one** PNG attachment lands, and no PR is opened. Post an instruction comment, re-run.
Expected: the same `[SKELETON]` comment is **edited**; the PNG is replaced (still one attachment).

- [ ] **Step 5: Commit**

```bash
git add skills/celebrimbor/SKILL.md skills/celebrimbor/skeleton-smith.md
git commit -m "feat(celebrimbor): --skeleton mode carves stubs + diagram"
```

---

## Task 7: Forge gate keyed on the derived `forge` action

Re-point celebrimbor's forge gate from "`[COUNSEL vN]` + `[FORTH]` + no `[GWAITH]`" to the decider's `forge` action, on the YouTrack path.

**Files:**
- Modify: `skills/celebrimbor/SKILL.md` — the forge-gate step (currently step 2 "Build the qualifying-ticket set" / step 4 "Verify the approved counsel")

- [ ] **Step 1: Replace the forge-gate definition (YouTrack path).** In the forge gate, add before the existing three-clause gate:

````markdown
**YouTrack forge gate (skeleton-stage).** When the tracker is YouTrack, a ticket
qualifies to forge iff `skeleton-rung.py` returns `action=forge` for it:

```bash
~/.claude/hooks/council-youtrack-fetch.sh <ticket> | ~/.claude/hooks/skeleton-rung.py
```

This means: a `[SKELETON]` comment exists and a `[FORTH]` sits past its watermark,
and no `[GWAITH]` yet. The contract the smith implements is the latest `[PLAN]`
body plus the approved `[SKELETON]` body. The Jira path keeps the `[COUNSEL vN]`
gate below.
````

- [ ] **Step 2: Point the smith's contract at plan + skeleton.** In celebrimbor's step "Summon Celebrimbor (subagent)", change the contract tail-block to include both the latest `[PLAN]` body and the approved `[SKELETON]` body (under a header `## Approved skeleton (your shape)`), for the YouTrack path.

- [ ] **Step 3: Verify on MET-1 (manual)**

On an MET-1 issue at `forge` (a `[SKELETON]` with a `[FORTH]` after it), run `/celebrimbor youtrack MET --ticket MET-1`.
Expected: the smith fills bodies into the skeleton's shape, a draft PR opens, `[GWAITH]` is posted; `skeleton-rung.py` now returns `done`.

- [ ] **Step 4: Commit**

```bash
git add skills/celebrimbor/SKILL.md
git commit -m "feat(celebrimbor): forge gate reads the derived forge action on YouTrack"
```

---

## Task 8: Sweep by the derived rung (/aule, /glorfindel)

Teach the sweeps to act on the decider's action per ticket, so one `/loop` walks all rungs.

**Files:**
- Modify: `skills/aule/SKILL.md` — the forge gate + per-ticket dispatch
- Modify: `skills/glorfindel/SKILL.md` — drive the plan rung via modify-only council

- [ ] **Step 1: Replace Aulë's forge gate (YouTrack) with action dispatch.** In `skills/aule/SKILL.md` step 2, add for the YouTrack path:

````markdown
**YouTrack rung dispatch.** For each listed ticket, run the decider:

```bash
~/.claude/hooks/council-youtrack-fetch.sh <ticket> | ~/.claude/hooks/skeleton-rung.py
```

Map the action to a dispatch:

| action | Dispatch |
|---|---|
| `draft_skeleton`, `redraft_skeleton` | `/celebrimbor youtrack <project> --ticket <id> --skeleton` |
| `forge` | `/celebrimbor youtrack <project> --ticket <id>` |
| `draft_plan`, `redraft_plan` | `/council youtrack:<id>` (plan rung — or leave to `/glorfindel`) |
| `await_plan`, `await_skeleton`, `done` | skip (no-op) |

A ticket whose action is a no-op is dropped from the manifest silently — exactly
the loop-safety the watermark buys.
````

- [ ] **Step 2: Glorfindel drives the plan rung.** In `skills/glorfindel/SKILL.md`, note that on the YouTrack path it invokes the modify-only `/council` (Task 5) per ticket; its loop-safety now comes from `skeleton-rung.py` returning `await_plan` rather than the old append "no fresh counsel" check.

- [ ] **Step 3: Verify a full walk on MET-1 (manual)**

With one standing `/loop /aule youtrack MET` (or self-paced), drive MET-1 from blank: open issue → tick drafts `[PLAN]` → post `[FORTH]` → tick draws `[SKELETON]` + PNG → post `[FORTH]` → tick forges the draft PR + `[GWAITH]`.
Expected: each tick advances exactly one rung; ticks between your comments are no-ops.

- [ ] **Step 4: Commit**

```bash
git add skills/aule/SKILL.md skills/glorfindel/SKILL.md
git commit -m "feat(sweep): aule/glorfindel act on the derived rung"
```

---

## Task 9: Permissions + docs

**Files:**
- Modify: `settings.json` — `permissions.allow`
- Modify: `README.md` — inventory

- [ ] **Step 1: Add the three new hooks to `permissions.allow`** in `settings.json` (portable `~`-prefixed form, per the Permissions rule):

```json
"Bash(~/.claude/hooks/skeleton-rung.py:*)",
"Bash(~/.claude/hooks/youtrack-comment-edit.sh:*)",
"Bash(~/.claude/hooks/youtrack-attach.sh:*)"
```

- [ ] **Step 2: Add README inventory lines** for `hooks/skeleton-rung.py`, `hooks/youtrack-comment-edit.sh`, `hooks/youtrack-attach.sh`, the council modify-only path, and celebrimbor's `--skeleton` mode.

- [ ] **Step 3: Run the full unit suite once more**

Run: `python3 -m unittest discover tests -v`
Expected: PASS — the decider's 8 tests green.

- [ ] **Step 4: Propagate the live config**

Invoke the `/install` skill (per the repo's propagation rule) so the new hooks land in every configured Claude root. Do **not** run `./install.sh` directly.

- [ ] **Step 5: Commit**

```bash
git add settings.json README.md
git commit -m "chore(skeleton-stage): permissions + README inventory"
```

---

## Notes for the executor

- **Vaultwarden creds required** for every manual smoke test — the `youtrack` item (uri + token). If absent, hooks print a credentials error; surface and pause, don't fake a pass.
- **`MET-1` is the only write-path sandbox.** Do not smoke-test against real project tickets.
- **Bot identity** is the service-account login `claude` (hardcoded in `skeleton-rung.py` as `BOT_LOGIN`). If the loop posts under a different YouTrack login, change that constant to match — the decider keys "bot vs human" on it.
- **Precedence:** a `[FORTH]` past a watermark advances the rung even if a later non-`[FORTH]` instruction exists; that instruction then applies to the next rung. This mirrors council's "verdict beats fresh counsel" rule.
- **Jira is untouched** by this plan. Every change is gated to the YouTrack path; the append/`[COUNSEL vN]` grammar still serves Jira.
