# Council Plan Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `/council` a Henneth HTML mirror of every plan round, and render any `` ```diagram ``/`` ```wireframe `` fenced ASCII block Erestor writes as a real image, embedded inline in the Jira/YouTrack comment instead of raw box-drawing text.

**Architecture:** A new pure-Python module (`hooks/council-plan-html.py`) detects a fenced diagram/wireframe block, renders the full plan and the diagram separately to themed HTML, and swaps the fence for a placeholder the tracker-specific hooks turn into a real image reference. A new `hooks/jira-attach.sh` gives Jira the same attach-and-replace capability YouTrack already has (`youtrack-attach.sh`). `hooks/council-jira-comment.sh` and `hooks/jira-comment-edit.sh` gain a small sentinel → ADF `mediaSingle` translation. `skills/council/erestor.md` and `skills/council/SKILL.md` are updated to actually use all of this.

**Tech Stack:** Bash (existing hook style), Python 3 stdlib only (no new dependencies), `npx -y playwright screenshot` (already a skadi dependency via `/celebrimbor --skeleton`), `jq`, `curl`.

## Global Constraints

- No new comment-grammar token — this is a rendering side-effect of the existing `[COUNSEL vN]`/`[PLAN]` tokens, not new state (spec: *Files touched*).
- Never post test/diagnostic comments or attachments to a real Jira ticket during development — every Jira-touching hook respects `COUNCIL_DRY_RUN=1`; use YouTrack `MET-1` for write-path smoke tests (`skills/council/SKILL.md`'s existing Jira read-only rule).
- Fail soft: if the screenshot or either attach hook fails, fall back to posting the original fenced block as raw ASCII text — never block the comment post on the decorative pipeline (spec: *Failure handling*).
- At most one diagram/wireframe block is handled per round; a second is left as raw ASCII, not an error (spec: *Out of scope*).
- Match the existing hook conventions exactly: bash scripts read secrets via `secret.sh`, never echo credentials, use `set -euo pipefail`, and print either a one-line success message or a `{"error":...}` JSON object on failure.

---

## File Structure

| File | Responsibility |
|---|---|
| `hooks/council-plan-html.py` | **New.** Pure functions to find/replace a fenced diagram/wireframe block, and to render the full plan or a lone diagram to themed HTML. CLI wrapper (`detect` / `render-plan` / `render-diagram` / `replace`) for use from bash. |
| `hooks/test_council_plan_html.py` | **New.** Unit tests for the module above (imported via `importlib`, matching `hooks/test_jira_adf.py`'s pattern). |
| `hooks/jira-attach.sh` | **New.** Uploads a file to a Jira issue, replacing any same-named prior attachment — Jira's counterpart to `hooks/youtrack-attach.sh`. |
| `hooks/council-jira-comment.sh` | **Modify.** Its markdown→ADF paragraph builder gains one branch: a paragraph reading exactly `[[PLAN-PREVIEW]]`, with `JIRA_ATTACHMENT_ID` set, becomes a `mediaSingle` node. |
| `hooks/council-jira-comment.test.sh` | **New.** Dry-run test for the branch above (matches `hooks/protected-repo-guard.test.sh`'s style — no framework, a `check()` helper, run by hand). |
| `hooks/jira-comment-edit.sh` | **Modify.** Same sentinel branch as `council-jira-comment.sh` (this script already duplicates that paragraph builder verbatim; this plan keeps the duplication rather than introducing a shared module neither script currently uses — see *Task 4* note). |
| `hooks/jira-comment-edit.test.sh` | **New.** Same style as `council-jira-comment.test.sh`. |
| `skills/council/erestor.md` | **Modify.** One new instruction: fence a diagram/wireframe with `` ```diagram `` / `` ```wireframe `` when one genuinely helps. |
| `skills/council/SKILL.md` | **Modify.** New workflow steps wiring everything above into the existing draft/redraft/post flow. |

---

## Task 1: `hooks/council-plan-html.py` — detect, replace, render

**Files:**
- Create: `hooks/council-plan-html.py`
- Test: `hooks/test_council_plan_html.py`

**Interfaces:**
- Consumes: nothing (first task; stdlib only — `html`, `re`, `sys`).
- Produces (importable via `importlib.util.spec_from_file_location`, and as a CLI):
  - `find_diagram_block(markdown_text: str) -> dict | None` — `{"tag": "diagram"|"wireframe", "body": str, "start": int, "end": int}` for the first fenced `` ```diagram `` or `` ```wireframe `` block, matching the fence's span in the original text (`start`/`end` are string offsets covering the whole fence including the backticks). `None` if no such block exists.
  - `replace_diagram_block(markdown_text: str, replacement_text: str) -> str` — splices `replacement_text` in place of the first diagram/wireframe fence. Raises `ValueError("no diagram/wireframe block found")` if none exists.
  - `render_plan_html(markdown_text: str, ticket_id: str) -> str` — a themed Henneth HTML page (full string) wrapping the raw plan markdown in a `.panel.full` / `<pre>` block, linking `skadi-theme.css`. HTML-escapes the plan text.
  - `render_diagram_html(diagram_body: str, ticket_id: str) -> str` — a small themed HTML page wrapping just the diagram/wireframe ASCII in a `.prec` block, linking `skadi-theme.css`. HTML-escapes the body.
  - CLI subcommands (argv-driven, documented below).

- [ ] **Step 1: Write the failing tests for `find_diagram_block`**

Create `hooks/test_council_plan_html.py`:

```python
#!/usr/bin/env python3
"""Tests for the council plan-preview HTML renderer."""

import importlib.util
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("council_plan_html", HERE / "council-plan-html.py")
cph = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cph)


class FindDiagramBlockTest(unittest.TestCase):
    def test_no_fence_returns_none(self):
        expected = None
        result = cph.find_diagram_block("# Intent\n\nJust prose, no diagram here.\n")
        self.assertEqual(expected, result)

    def test_diagram_fence_is_found(self):
        text = "before\n\n```diagram\nA -> B\n```\n\nafter"
        result = cph.find_diagram_block(text)
        self.assertEqual("diagram", result["tag"])
        self.assertEqual("A -> B", result["body"])
        self.assertEqual(text[result["start"]:result["end"]], "```diagram\nA -> B\n```")

    def test_wireframe_fence_is_found(self):
        text = "before\n\n```wireframe\n[Box]\n```\n\nafter"
        result = cph.find_diagram_block(text)
        self.assertEqual("wireframe", result["tag"])
        self.assertEqual("[Box]", result["body"])

    def test_only_first_fence_is_returned(self):
        text = "```diagram\nfirst\n```\n\n```wireframe\nsecond\n```"
        result = cph.find_diagram_block(text)
        self.assertEqual("diagram", result["tag"])
        self.assertEqual("first", result["body"])

    def test_bare_fence_without_tag_is_ignored(self):
        expected = None
        result = cph.find_diagram_block("```\nplain code, not a diagram\n```")
        self.assertEqual(expected, result)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 hooks/test_council_plan_html.py`
Expected: `FileNotFoundError` (or `ModuleNotFoundError`/`AttributeError`) — `hooks/council-plan-html.py` does not exist yet.

- [ ] **Step 3: Write `hooks/council-plan-html.py` with `find_diagram_block`**

Create `hooks/council-plan-html.py`:

```python
#!/usr/bin/env python3
"""Council plan preview — Henneth HTML mirror + diagram/wireframe extraction.

Usage:
  council-plan-html.py detect                          < markdown on stdin
  council-plan-html.py render-plan <ticket-id> <out>    < markdown on stdin
  council-plan-html.py render-diagram <ticket-id> <out> < diagram body on stdin
  council-plan-html.py replace <replacement-file>       < markdown on stdin, writes stdout

`detect` prints "FOUND tag=<diagram|wireframe>" followed by the raw block
body and exits 0, or prints "NONE" and exits 1 if no block is present.
`replace` splices the contents of <replacement-file> in place of the first
diagram/wireframe fence and writes the result to stdout.
"""

import html
import re
import sys

_FENCE_RE = re.compile(r"```(diagram|wireframe)\n(.*?)\n```", re.DOTALL)


def find_diagram_block(markdown_text):
    match = _FENCE_RE.search(markdown_text)
    if not match:
        return None
    return {
        "tag": match.group(1),
        "body": match.group(2),
        "start": match.start(),
        "end": match.end(),
    }


def replace_diagram_block(markdown_text, replacement_text):
    block = find_diagram_block(markdown_text)
    if block is None:
        raise ValueError("no diagram/wireframe block found")
    return markdown_text[: block["start"]] + replacement_text + markdown_text[block["end"] :]
```

No `if __name__` guard yet — `main` does not exist until Step 8, and a
guard calling an undefined name has no place in a committed file, even one
that's never executed by the tests. Step 8 adds the guard together with
`main`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 hooks/test_council_plan_html.py`
Expected: `OK` (5 tests, all passing).

- [ ] **Step 5: Commit**

```bash
git add hooks/council-plan-html.py hooks/test_council_plan_html.py
git commit -m "feat(council): add diagram/wireframe fence detection"
```

- [ ] **Step 6: Write the failing tests for `replace_diagram_block`, `render_plan_html`, `render_diagram_html`**

Append to `hooks/test_council_plan_html.py` (before the `if __name__ == "__main__":` line):

```python
class ReplaceDiagramBlockTest(unittest.TestCase):
    def test_replaces_fence_with_given_text(self):
        text = "before\n\n```diagram\nA -> B\n```\n\nafter"
        expected = "before\n\n![diagram](x.png)\n\nafter"
        result = cph.replace_diagram_block(text, "![diagram](x.png)")
        self.assertEqual(expected, result)

    def test_raises_when_no_block_present(self):
        with self.assertRaises(ValueError):
            cph.replace_diagram_block("no fence here", "x")


class RenderPlanHtmlTest(unittest.TestCase):
    def test_output_contains_escaped_ticket_and_body(self):
        html_out = cph.render_plan_html("Intent: <script>alert(1)</script>", "MET-1")
        self.assertIn("MET-1", html_out)
        self.assertIn("&lt;script&gt;", html_out)
        self.assertNotIn("<script>alert(1)</script>", html_out)
        self.assertIn('href="skadi-theme.css"', html_out)


class RenderDiagramHtmlTest(unittest.TestCase):
    def test_output_preserves_ascii_box_drawing(self):
        body = "┌───┐\n│ A │\n└───┘"
        html_out = cph.render_diagram_html(body, "MET-1")
        self.assertIn("┌───┐", html_out)
        self.assertIn('href="skadi-theme.css"', html_out)
```

- [ ] **Step 7: Run the tests to verify they fail**

Run: `python3 hooks/test_council_plan_html.py`
Expected: `AttributeError: module 'council_plan_html' has no attribute 'render_plan_html'` (and similar for `render_diagram_html`).

- [ ] **Step 8: Implement `render_plan_html`, `render_diagram_html`, and the CLI**

Append the following to the end of `hooks/council-plan-html.py`:

```python
PLAN_TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Plan Preview — {ticket_id}</title>
<link rel="stylesheet" href="skadi-theme.css">
<style>
  main {{ max-width: 900px; margin: 0 auto; padding: 2rem 1.5rem 4rem; }}
  pre.plan {{ white-space: pre-wrap; font-family: "Iowan Old Style", Georgia, serif; font-size: 1rem; line-height: 1.6; }}
</style>
</head>
<body>
<main>
  <h1>Plan Preview — {ticket_id}</h1>
  <div class="panel full"><pre class="plan">{body}</pre></div>
</main>
</body>
</html>
"""

DIAGRAM_TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Diagram — {ticket_id}</title>
<link rel="stylesheet" href="skadi-theme.css">
</head>
<body>
<main style="max-width: 700px; margin: 2rem auto;">
  <div class="prec">{body}</div>
</main>
</body>
</html>
"""


def render_plan_html(markdown_text, ticket_id):
    return PLAN_TEMPLATE.format(ticket_id=html.escape(ticket_id), body=html.escape(markdown_text))


def render_diagram_html(diagram_body, ticket_id):
    return DIAGRAM_TEMPLATE.format(ticket_id=html.escape(ticket_id), body=html.escape(diagram_body))


def _cmd_detect():
    text = sys.stdin.read()
    block = find_diagram_block(text)
    if block is None:
        print("NONE")
        return 1
    print(f"FOUND tag={block['tag']}")
    sys.stdout.write(block["body"])
    return 0


def _cmd_render_plan(ticket_id, out_path):
    text = sys.stdin.read()
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(render_plan_html(text, ticket_id))
    return 0


def _cmd_render_diagram(ticket_id, out_path):
    text = sys.stdin.read()
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(render_diagram_html(text, ticket_id))
    return 0


def _cmd_replace(replacement_file):
    text = sys.stdin.read()
    with open(replacement_file, "r", encoding="utf-8") as f:
        replacement = f.read()
    sys.stdout.write(replace_diagram_block(text, replacement))
    return 0


def main(argv):
    if not argv:
        print('{"error":"usage: council-plan-html.py <detect|render-plan|render-diagram|replace> [args...]"}')
        return 1
    cmd = argv[0]
    try:
        if cmd == "detect":
            return _cmd_detect()
        if cmd == "render-plan":
            return _cmd_render_plan(argv[1], argv[2])
        if cmd == "render-diagram":
            return _cmd_render_diagram(argv[1], argv[2])
        if cmd == "replace":
            return _cmd_replace(argv[1])
    except (IndexError, ValueError) as exc:
        print(f'{{"error":"{exc}"}}')
        return 1
    print(f'{{"error":"unknown command: {cmd}"}}')
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `python3 hooks/test_council_plan_html.py`
Expected: `OK` (9 tests, all passing).

- [ ] **Step 10: Smoke-test the CLI by hand**

```bash
chmod +x hooks/council-plan-html.py
printf 'before\n\n```diagram\nA -> B\n```\n\nafter\n' | python3 hooks/council-plan-html.py detect
```

Expected output:
```
FOUND tag=diagram
A -> B
```

```bash
printf 'before\n\n```diagram\nA -> B\n```\n\nafter\n' | python3 hooks/council-plan-html.py render-plan MET-1 /tmp/plan-MET-1.html
grep -c 'MET-1' /tmp/plan-MET-1.html
```

Expected: prints a number ≥ 1 (no error).

- [ ] **Step 11: Commit**

```bash
git add hooks/council-plan-html.py hooks/test_council_plan_html.py
git commit -m "feat(council): render plan/diagram HTML and wire the CLI"
```

---

## Task 2: `hooks/jira-attach.sh`

**Files:**
- Create: `hooks/jira-attach.sh`

**Interfaces:**
- Consumes: `hooks/secret.sh` (existing — resolves `jira uri` / `jira username` / `jira password JIRA_API_TOKEN`, same as `hooks/council-jira-comment.sh`).
- Produces: `jira-attach.sh <ISSUE-KEY> <FILE-PATH>` → on success, stdout `attached: name=<filename> id=<attachment-id> url=<issue-url>`, exit 0. On failure, stdout `{"error":"...","response":"..."}`, exit 1. With `COUNCIL_DRY_RUN=1`, stdout `DRY-RUN would attach <filename> to <ISSUE-KEY>`, exit 0, no network call.

This hook makes real HTTP calls against a live Jira instance and has no local unit-test harness (its sibling `hooks/youtrack-attach.sh` has none either, for the same reason — see `skills/council/SKILL.md`'s Jira read-only rule). Its dry-run path is exercised by hand in Step 3 below; the real upload/delete path is exercised once, deliberately, in Task 7's live verification.

- [ ] **Step 1: Write the script**

Create `hooks/jira-attach.sh`:

```bash
#!/bin/bash
# Usage: jira-attach.sh <ISSUE-KEY> <FILE-PATH>
# Attaches FILE to the issue, replacing any existing attachment of the same name
# (so a re-rendered diagram PNG does not stack). Resolves creds via secret.sh.
# On success, prints: attached: name=<filename> id=<attachment-id> url=<issue-url>
# On failure, prints {"error":"...","response":"..."} and exits non-zero.
#
# Env: COUNCIL_DRY_RUN=1 skips the delete+upload and prints
# "DRY-RUN would attach <filename> to <ISSUE-KEY>" instead. Use this for shape
# verification without writing to Jira — Jira tickets are real work.

set -euo pipefail
export LC_ALL=C.UTF-8

ISSUE_KEY="${1:-}"
FILE_PATH="${2:-}"
if [[ -z "$ISSUE_KEY" || -z "$FILE_PATH" ]]; then
  echo '{"error":"usage: jira-attach.sh <ISSUE-KEY> <FILE-PATH>"}'
  exit 1
fi
if [[ ! -f "$FILE_PATH" ]]; then
  echo "{\"error\":\"file not found: $FILE_PATH\"}"
  exit 1
fi

NAME="$(basename "$FILE_PATH")"

SECRET="$(dirname "$0")/secret.sh"
JIRA_URL="$("$SECRET" jira uri 2>/dev/null || true)"
JIRA_EMAIL="$("$SECRET" jira username 2>/dev/null || true)"
JIRA_TOKEN="$("$SECRET" jira password JIRA_API_TOKEN 2>/dev/null || true)"

if [[ -z "$JIRA_URL" || -z "$JIRA_EMAIL" || -z "$JIRA_TOKEN" ]]; then
  echo '{"error":"jira credentials missing (need uri, username, password from Vaultwarden item \"jira\" or env)"}'
  exit 1
fi

URL="${JIRA_URL%/}"

if [[ "${COUNCIL_DRY_RUN:-0}" == "1" ]]; then
  echo "DRY-RUN would attach $NAME to $ISSUE_KEY"
  exit 0
fi

list_file=$(mktemp)
response_file=$(mktemp)
trap 'rm -f "$list_file" "$response_file"' EXIT

# 1. Find and delete any prior attachment of the same name (replace-in-place).
status=$(curl -sS -o "$list_file" -w "%{http_code}" \
  -u "$JIRA_EMAIL:$JIRA_TOKEN" -H "Accept: application/json" \
  "$URL/rest/api/3/issue/$ISSUE_KEY?fields=attachment")
if [[ "$status" == 2* ]]; then
  while IFS= read -r old_id; do
    [[ -n "$old_id" ]] && curl -sS -o /dev/null -X DELETE \
      -u "$JIRA_EMAIL:$JIRA_TOKEN" \
      "$URL/rest/api/3/attachment/$old_id" || true
  done < <(jq -r --arg n "$NAME" '.fields.attachment[]? | select(.filename == $n) | .id' "$list_file")
fi

# 2. Upload the new file (multipart).
status=$(curl -sS -X POST -o "$response_file" -w "%{http_code}" \
  -u "$JIRA_EMAIL:$JIRA_TOKEN" \
  -H "X-Atlassian-Token: no-check" \
  -H "Accept: application/json" \
  -F "file=@$FILE_PATH;type=image/png" \
  "$URL/rest/api/3/issue/$ISSUE_KEY/attachments")

if [[ "$status" != 2* ]]; then
  jq -cn --arg id "$ISSUE_KEY" --arg s "$status" --rawfile b "$response_file" \
    '{error: ("attach failed for " + $id + " (http=" + $s + ")"), response: $b}'
  exit 1
fi

att_id=$(jq -r '.[0].id // ""' "$response_file")
printf 'attached: name=%s id=%s url=%s/browse/%s\n' "$NAME" "$att_id" "$URL" "$ISSUE_KEY"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x hooks/jira-attach.sh
```

- [ ] **Step 3: Smoke-test the usage and dry-run paths by hand**

```bash
hooks/jira-attach.sh
```
Expected: `{"error":"usage: jira-attach.sh <ISSUE-KEY> <FILE-PATH>"}`, exit 1.

```bash
hooks/jira-attach.sh MET-1 /tmp/does-not-exist.png
```
Expected: `{"error":"file not found: /tmp/does-not-exist.png"}`, exit 1.

```bash
printf 'x' > /tmp/diagram-test.png
JIRA_BASE_URL=https://example.atlassian.net JIRA_EMAIL=test@example.com JIRA_API_TOKEN=dummy \
  COUNCIL_DRY_RUN=1 hooks/jira-attach.sh MET-1 /tmp/diagram-test.png
```
Expected: `DRY-RUN would attach diagram-test.png to MET-1`, exit 0 (no network call — verify by running with no network access, or by checking no `curl` process appears in a concurrent `ps` sample if in doubt).

- [ ] **Step 4: Commit**

```bash
git add hooks/jira-attach.sh
git commit -m "feat(jira): add attach hook, mirroring youtrack-attach.sh"
```

---

## Task 3: `hooks/council-jira-comment.sh` — `[[PLAN-PREVIEW]]` sentinel

**Files:**
- Modify: `hooks/council-jira-comment.sh` (its inline Python payload-builder heredoc)
- Test: `hooks/council-jira-comment.test.sh`

**Interfaces:**
- Consumes: `JIRA_ATTACHMENT_ID` env var (new, optional).
- Produces: when stdin's body contains a paragraph reading exactly `[[PLAN-PREVIEW]]` **and** `JIRA_ATTACHMENT_ID` is set and non-empty, that paragraph becomes:
  ```json
  {"type": "mediaSingle", "attrs": {"layout": "center"}, "content": [{"type": "media", "attrs": {"id": "<JIRA_ATTACHMENT_ID>", "type": "file", "collection": "jira"}}]}
  ```
  Otherwise, behavior is unchanged from today (the paragraph is emitted as literal text).

- [ ] **Step 1: Write the failing test**

Create `hooks/council-jira-comment.test.sh`:

```bash
#!/usr/bin/env bash
# Test for the [[PLAN-PREVIEW]] -> mediaSingle sentinel in council-jira-comment.sh.
# Run by hand: hooks/council-jira-comment.test.sh
# Uses COUNCIL_DRY_RUN=1 so no network call is made; dummy env-fallback
# credentials satisfy the non-empty checks without touching Vaultwarden.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/council-jira-comment.sh"

export JIRA_BASE_URL="https://example.atlassian.net"
export JIRA_EMAIL="test@example.com"
export JIRA_API_TOKEN="dummy"
export COUNCIL_DRY_RUN=1

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

# 1. Sentinel present + JIRA_ATTACHMENT_ID set -> mediaSingle node.
out=$(printf 'Some text.\n\n[[PLAN-PREVIEW]]\n\nMore text.' | JIRA_ATTACHMENT_ID=12345 "$HOOK" MET-1)
check "mediaSingle type present" "1" "$(printf '%s' "$out" | grep -c '"type": "mediaSingle"')"
check "attachment id embedded" "1" "$(printf '%s' "$out" | grep -c '"id": "12345"')"
check "collection is jira" "1" "$(printf '%s' "$out" | grep -c '"collection": "jira"')"
check "sentinel text not emitted literally" "0" "$(printf '%s' "$out" | grep -c 'PLAN-PREVIEW')"

# 2. Sentinel present but no JIRA_ATTACHMENT_ID -> emitted as plain text (unchanged behavior).
out=$(printf 'Some text.\n\n[[PLAN-PREVIEW]]\n\nMore text.' | "$HOOK" MET-1)
check "no env var -> sentinel stays literal text" "1" "$(printf '%s' "$out" | grep -c 'PLAN-PREVIEW')"
check "no env var -> no mediaSingle" "0" "$(printf '%s' "$out" | grep -c 'mediaSingle')"

# 3. No sentinel at all -> unaffected (today's behavior).
out=$(printf 'Plain paragraph, nothing special.' | JIRA_ATTACHMENT_ID=12345 "$HOOK" MET-1)
check "no sentinel -> no mediaSingle" "0" "$(printf '%s' "$out" | grep -c 'mediaSingle')"
check "no sentinel -> plain text intact" "1" "$(printf '%s' "$out" | grep -c 'Plain paragraph')"

exit $fail
```

- [ ] **Step 2: Make it executable and run to verify it fails**

```bash
chmod +x hooks/council-jira-comment.test.sh
hooks/council-jira-comment.test.sh
```

Expected: the four `mediaSingle`/`id`/`collection`-related checks in block 1 print `FAIL` (the sentinel is currently emitted as plain text, no `mediaSingle` node exists yet). Blocks 2 and 3 already pass (today's behavior).

- [ ] **Step 3: Implement the sentinel branch**

In `hooks/council-jira-comment.sh`, find the inline Python heredoc (the `python - "$body_file" > "$payload_file" <<'PY'` block). Replace it with:

```python
python - "$body_file" > "$payload_file" <<'PY'
import json, os, sys
sys.stdout.reconfigure(encoding="utf-8")

text = open(sys.argv[1], "r", encoding="utf-8").read().rstrip("\n")
paragraphs = text.split("\n\n")
attachment_id = os.environ.get("JIRA_ATTACHMENT_ID", "")

content = []
for para in paragraphs:
    if not para.strip():
        continue
    if para.strip() == "[[PLAN-PREVIEW]]" and attachment_id:
        content.append({
            "type": "mediaSingle",
            "attrs": {"layout": "center"},
            "content": [
                {"type": "media", "attrs": {"id": attachment_id, "type": "file", "collection": "jira"}}
            ],
        })
        continue
    lines = para.split("\n")
    nodes = []
    for i, line in enumerate(lines):
        if i > 0:
            nodes.append({"type": "hardBreak"})
        if line:
            nodes.append({"type": "text", "text": line})
    if nodes:
        content.append({"type": "paragraph", "content": nodes})

if not content:
    content = [{"type": "paragraph", "content": [{"type": "text", "text": text or " "}]}]

payload = {"body": {"version": 1, "type": "doc", "content": content}}
print(json.dumps(payload, ensure_ascii=False))
PY
```

Also update the script's header comment (the block of `#` lines at the top) to add, after the existing `# Env: COUNCIL_DRY_RUN=1 ...` line:

```bash
# Env: JIRA_ATTACHMENT_ID, if set, turns a body paragraph reading exactly
# "[[PLAN-PREVIEW]]" into an ADF mediaSingle node referencing that attachment
# id instead of emitting the sentinel as literal text.
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
hooks/council-jira-comment.test.sh
```

Expected: all `ok` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add hooks/council-jira-comment.sh hooks/council-jira-comment.test.sh
git commit -m "feat(jira): recognize [[PLAN-PREVIEW]] sentinel in comment post"
```

---

## Task 4: `hooks/jira-comment-edit.sh` — same sentinel

**Files:**
- Modify: `hooks/jira-comment-edit.sh` (its inline Python payload-builder heredoc — a byte-for-byte duplicate of `council-jira-comment.sh`'s builder, predating this change)
- Test: `hooks/jira-comment-edit.test.sh`

**Interfaces:**
- Consumes: `JIRA_ATTACHMENT_ID` env var (same contract as Task 3).
- Produces: identical `[[PLAN-PREVIEW]]` → `mediaSingle` behavior as Task 3, for the edit-in-place path (`echo body | jira-comment-edit.sh <ISSUE-KEY> <COMMENT-ID>`).

Note: `council-jira-comment.sh` and `jira-comment-edit.sh` already duplicate the same paragraph-builder logic verbatim (a pre-existing pattern, not introduced by this plan). Per `docs/style/universal.md`'s "lift on the third recurrence" rule, two duplicated copies stay as honest repetition — this task adds the *same* sentinel branch to the *existing* second copy rather than introducing a shared module neither script currently imports. If a third Jira-posting hook ever needs this builder, lift all three into one shared module then.

- [ ] **Step 1: Write the failing test**

Create `hooks/jira-comment-edit.test.sh`:

```bash
#!/usr/bin/env bash
# Test for the [[PLAN-PREVIEW]] -> mediaSingle sentinel in jira-comment-edit.sh.
# Run by hand: hooks/jira-comment-edit.test.sh
# Mirrors hooks/council-jira-comment.test.sh — same sentinel, edit path.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/jira-comment-edit.sh"

export JIRA_BASE_URL="https://example.atlassian.net"
export JIRA_EMAIL="test@example.com"
export JIRA_API_TOKEN="dummy"
export COUNCIL_DRY_RUN=1

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

out=$(printf 'Some text.\n\n[[PLAN-PREVIEW]]\n\nMore text.' | JIRA_ATTACHMENT_ID=12345 "$HOOK" MET-1 999)
check "mediaSingle type present" "1" "$(printf '%s' "$out" | grep -c '"type": "mediaSingle"')"
check "attachment id embedded" "1" "$(printf '%s' "$out" | grep -c '"id": "12345"')"

out=$(printf 'Some text.\n\n[[PLAN-PREVIEW]]\n\nMore text.' | "$HOOK" MET-1 999)
check "no env var -> sentinel stays literal text" "1" "$(printf '%s' "$out" | grep -c 'PLAN-PREVIEW')"

out=$(printf 'Plain paragraph, nothing special.' | JIRA_ATTACHMENT_ID=12345 "$HOOK" MET-1 999)
check "no sentinel -> no mediaSingle" "0" "$(printf '%s' "$out" | grep -c 'mediaSingle')"

exit $fail
```

- [ ] **Step 2: Make it executable and run to verify it fails**

```bash
chmod +x hooks/jira-comment-edit.test.sh
hooks/jira-comment-edit.test.sh
```

Expected: the two `mediaSingle`/`id`-related checks in block 1 print `FAIL`.

- [ ] **Step 3: Implement the sentinel branch**

Apply the identical Python heredoc replacement from Task 3 Step 3 to `hooks/jira-comment-edit.sh`'s payload-builder block, and add the same header-comment line documenting `JIRA_ATTACHMENT_ID`.

- [ ] **Step 4: Run the test to verify it passes**

```bash
hooks/jira-comment-edit.test.sh
```

Expected: all `ok` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add hooks/jira-comment-edit.sh hooks/jira-comment-edit.test.sh
git commit -m "feat(jira): recognize [[PLAN-PREVIEW]] sentinel in comment edit"
```

---

## Task 5: `skills/council/erestor.md` — fence a diagram or wireframe

**Files:**
- Modify: `skills/council/erestor.md`

**Interfaces:**
- Consumes: nothing new.
- Produces: Erestor's returned `[COUNSEL vN]`/`[PLAN]` body may now contain a fenced `` ```diagram `` or `` ```wireframe `` block — the exact shape Task 1's `find_diagram_block` and Task 6's workflow steps look for.

This is a prompt-document edit; there is no automated test. Verification is a read-through against the design doc's *Marking a diagram or wireframe* section, plus the manual dry-run in Task 6 Step 4.

- [ ] **Step 1: Read the current file**

```bash
cat skills/council/erestor.md
```

Locate the numbered "returns a markdown body whose sections are" list (Intent / Steps / Acceptance / Open questions / Not covered) — this is where the new instruction belongs, as it governs the *shape* of what Erestor returns.

- [ ] **Step 2: Add the fencing instruction**

Add a new paragraph immediately after that numbered list (before the "How to weave in Elrond's last reply" section), reading:

```markdown
**Diagrams and wireframes.** When a layout or structural point is genuinely
clearer shown than described — a screen's regions, a sequence of calls, a
class shape — sketch it in Unicode box-drawing, per the existing UI Review /
UML Review convention, and fence it distinctly so it can be found
mechanically:

    ```diagram
    ┌──────────┐     ┌──────────┐
    │  Client  │────▶│  Server  │
    └──────────┘     └──────────┘
    ```

Use `` ```wireframe `` instead of `` ```diagram `` when the sketch is a screen
layout rather than a structural diagram — either tag is handled identically
downstream. Do not use a bare fence or inline the sketch in prose; only a
fence tagged exactly `diagram` or `wireframe` is recognized. Include at most
one such block per round — a second is left as plain prose. Most plans need
no diagram at all; do not add one merely to fill this section.
```

- [ ] **Step 3: Verify by reading the diff**

```bash
git diff skills/council/erestor.md
```

Confirm the new paragraph reads correctly in context (numbered list above it, "How to weave in Elrond's last reply" heading below it), and that the fence example matches Task 1's `_FENCE_RE` pattern exactly (`` ```diagram\n...\n``` ``, no extra blank line inside the fence).

- [ ] **Step 4: Commit**

```bash
git add skills/council/erestor.md
git commit -m "docs(council): instruct Erestor to fence diagrams/wireframes"
```

---

## Task 6: `skills/council/SKILL.md` — wire the pipeline into the workflow

**Files:**
- Modify: `skills/council/SKILL.md`

**Interfaces:**
- Consumes: everything from Tasks 1–5 by exact name — `hooks/council-plan-html.py`'s four subcommands, `hooks/jira-attach.sh`, `hooks/youtrack-attach.sh` (existing), the `[[PLAN-PREVIEW]]`/`JIRA_ATTACHMENT_ID` contract from Tasks 3–4, and Erestor's new diagram/wireframe fencing from Task 5.
- Produces: the fully wired `/council` behavior described in the design doc.

This is a workflow-document edit; verification is the manual dry-run in Step 4 below, run against YouTrack `MET-1` (the project's designated write-path smoke-test ticket) per the existing Jira read-only rule.

- [ ] **Step 1: Add the Henneth-mirror step**

In the section documented for the YouTrack modify-only path (step 2's `draft_plan`/`await_start` and `redraft_plan` branches — both places that call `~/.claude/hooks/council-youtrack-comment.sh` or `~/.claude/hooks/youtrack-comment-edit.sh` with a freshly-drafted `[PLAN]` body) and in the Jira path's step 6 (both the first-turn create and the redraft-edit branches), add, immediately **before** posting/editing the comment:

```markdown
**Render the Henneth mirror.** Regardless of tracker, before posting or
editing the plan comment, write Erestor's full returned body to Henneth so
it can be read locally:

```bash
printf '%s' "$EREST_OR_BODY" | python3 ~/.claude/hooks/council-plan-html.py render-plan <TICKET-ID> ~/.claude/previews/henneth/plan-<TICKET-ID>.html
```

This always runs, on every draft and redraft — independent of whether a
diagram/wireframe block is present and independent of tracker-post success.
It does not run on `[PEDO]`/`[PARLEY]` (the plan body is unchanged in both
cases).
```

- [ ] **Step 2: Add the diagram/wireframe detection and rendering steps**

Immediately after the Henneth-mirror step added above (still before the comment posts), add:

```markdown
**Detect a diagram or wireframe.** Scan the same body for a fenced block:

```bash
DETECT_OUT=$(printf '%s' "$EREST_OR_BODY" | python3 ~/.claude/hooks/council-plan-html.py detect)
DETECT_STATUS=$?
```

If `$DETECT_STATUS` is `1` (no block found — `$DETECT_OUT` is `NONE`), skip
straight to posting/editing the comment with `$EREST_OR_BODY` unchanged; none
of the remaining sub-steps run. If `$DETECT_STATUS` is `0`, the first line of
`$DETECT_OUT` is `FOUND tag=<diagram|wireframe>` and the rest is the raw
block body — extract both and continue:

```bash
DIAGRAM_TAG=$(printf '%s' "$DETECT_OUT" | head -1 | sed 's/FOUND tag=//')
DIAGRAM_BODY=$(printf '%s' "$DETECT_OUT" | tail -n +2)
```

**Render and screenshot the block.** Write the block alone to a scratch HTML
file, then screenshot it — reusing the same pipeline `/celebrimbor --skeleton`
uses for its diagram PNG (`skills/celebrimbor/SKILL.md:152`):

```bash
printf '%s' "$DIAGRAM_BODY" | python3 ~/.claude/hooks/council-plan-html.py render-diagram <TICKET-ID> "$TMPDIR/diagram-<TICKET-ID>.html"
npx -y playwright screenshot "$TMPDIR/diagram-<TICKET-ID>.html" "$TMPDIR/diagram-<TICKET-ID>.png"
```

If either command fails (non-zero exit), stop the diagram pipeline here: log
the failure for the step-7 report, and post/edit the comment with
`$EREST_OR_BODY` **unchanged** (the fenced block posts as raw ASCII, exactly
as council would with no preview pipeline at all) — do not attempt the
attach/embed sub-steps below.
```

- [ ] **Step 3: Add the per-tracker attach + embed steps**

Still within the same conditional (a diagram/wireframe block was found and
screenshotted successfully), add — **before** the existing post/edit call for
each tracker:

```markdown
**Attach, then embed — per tracker:**

- **YouTrack:**

  ```bash
  ~/.claude/hooks/youtrack-attach.sh <TICKET-ID> "$TMPDIR/diagram-<TICKET-ID>.png"
  ```

  On success, replace the fenced block in the body before posting/editing:

  ```bash
  printf '![Plan diagram](diagram-<TICKET-ID>.png)' > "$TMPDIR/img-ref.txt"
  EREST_OR_BODY=$(printf '%s' "$EREST_OR_BODY" | python3 ~/.claude/hooks/council-plan-html.py replace "$TMPDIR/img-ref.txt")
  ```

  On failure, leave `$EREST_OR_BODY` unchanged (raw ASCII posts) and note the
  failure for step 7.

- **Jira:**

  ```bash
  ATTACH_OUT=$(~/.claude/hooks/jira-attach.sh <ISSUE-KEY> "$TMPDIR/diagram-<TICKET-ID>.png")
  ```

  On success, `$ATTACH_OUT` is `attached: name=... id=<ATTACHMENT-ID> url=...`
  — extract `<ATTACHMENT-ID>` and replace the fenced block with the sentinel:

  ```bash
  JIRA_ATTACHMENT_ID=$(printf '%s' "$ATTACH_OUT" | sed -n 's/.*id=\([^ ]*\).*/\1/p')
  printf '[[PLAN-PREVIEW]]' > "$TMPDIR/sentinel.txt"
  EREST_OR_BODY=$(printf '%s' "$EREST_OR_BODY" | python3 ~/.claude/hooks/council-plan-html.py replace "$TMPDIR/sentinel.txt")
  export JIRA_ATTACHMENT_ID
  ```

  The exported `JIRA_ATTACHMENT_ID` must be in scope when `council-jira-comment.sh`
  or `jira-comment-edit.sh` is called for this round (both hooks read it from
  the environment). On attach failure, leave `$EREST_OR_BODY` unchanged, do
  not export `JIRA_ATTACHMENT_ID`, and note the failure for step 7.
```

- [ ] **Step 4: Update the step-7 report format**

In the existing "Report and release" section, add one bullet to the list of
what to tell the user each round:

```markdown
- Whether a diagram/wireframe was found this round, and if so, whether it
  rendered and attached successfully or fell back to raw ASCII (name which
  tool failed, if any — screenshot or attach).
```

- [ ] **Step 5: Read the full diff for consistency**

```bash
git diff skills/council/SKILL.md
```

Confirm: the Henneth-mirror step appears in both the YouTrack modify-only path
and the Jira path (it must run for both trackers); the diagram detection and
attach/embed steps are clearly scoped as conditional (only inside the "a
block was found" branch); no changes were made to the `[PEDO]`/`[PARLEY]`
handling or the thirteen-token comment grammar table.

- [ ] **Step 6: Manual dry-run against YouTrack MET-1**

Post a comment on `MET-1` containing a fenced diagram block, then run
`/council MET-1` and confirm:

1. `~/.claude/previews/henneth/plan-MET-1.html` exists and contains the full
   plan text.
2. The `[PLAN]` comment posted on `MET-1` shows `![Plan diagram](...)` in
   place of the raw fence, and the issue's attachments list carries
   `diagram-MET-1.png`.
3. Running `/council MET-1` again with no fresh human reply reports the
   existing loop-safe "awaiting" message and does not re-render or re-attach
   anything (Henneth mirror also does not re-write, since no draft/redraft
   fires with no fresh counsel).

- [ ] **Step 7: Commit**

```bash
git add skills/council/SKILL.md
git commit -m "feat(council): wire Henneth mirror and diagram/wireframe embed into workflow"
```

---

## Task 7: Live verification against a real Jira ticket

**Files:** none — this is a verification-only task, no code changes.

**Interfaces:** consumes the entire pipeline from Tasks 1–6.

This is the design doc's called-out top risk: the Jira `mediaSingle` ADF shape
cannot be proven correct by `COUNCIL_DRY_RUN=1` alone (dry-run only proves the
payload is *sent*, not that Jira *renders* it). Per `skills/council/SKILL.md`'s
Jira read-only rule, this must be a deliberate, acknowledged live write — not
disguised as routine testing.

- [ ] **Step 1: Pick a real, low-stakes Jira ticket**

Choose an existing ticket already in a state where an extra comment round is
harmless (e.g. a stale or already-closed ticket in a project you own), or
create a new throwaway ticket explicitly for this check. State plainly to
whoever reviews this task which ticket was used and why it's low-stakes.

- [ ] **Step 2: Get a diagram onto it and run `/council`**

Ensure the ticket (or its description) contains something that would
naturally prompt Erestor to include a diagram — or directly seed a
`[COUNSEL v1]` comment carrying a fenced `` ```diagram `` block by hand, then
run `/council <TICKET-ID>` so the plan-preview pipeline fires on the next
redraft.

- [ ] **Step 3: Confirm the image actually renders in the Jira UI**

Open the ticket in a browser. Confirm the `[COUNSEL vN]` comment shows the
diagram as an **inline image**, not a broken media placeholder and not the
raw `[[PLAN-PREVIEW]]` sentinel text. Confirm the same PNG appears once in
the issue's Attachments list (not duplicated across rounds — redraft the plan
a second time and re-check that only one `diagram-<ticket-id>.png` exists).

- [ ] **Step 4: Record the outcome**

If the media node renders correctly: note this plainly wherever the plan's
completion is reported (e.g. "Jira mediaSingle embed verified live on
`<TICKET-ID>`"). If it does **not** render correctly (broken image, raw
sentinel text, wrong layout): this is a real finding, not a task to silently
patch around — return to Task 3/4's `mediaSingle` shape, fix it, and repeat
this task before calling the plan done.
