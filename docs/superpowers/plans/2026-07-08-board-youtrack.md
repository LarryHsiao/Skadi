# Board YouTrack Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the situation board seat YouTrack tickets alongside Jira ones, routed by the key's project prefix.

**Architecture:** `hooks/board-ticket.sh` gains a `--tracker <jira|youtrack>` flag (default `jira`). Each tracker fetches and normalizes its issue into one uniform intermediate JSON; a single shared jq shapes the channel from that intermediate; the hero-clearing and manifest tail are untouched. The `/board` skill resolves the tracker from the prefix on `add`; `board.sh refresh` re-derives it from each channel's recorded `.source`.

**Tech Stack:** Bash, jq, curl. Offline tests via injected fixtures (`BOARD_TICKET_ISSUE_FILE`), run with `bash hooks/board-ticket.test.sh`.

## Global Constraints

- Bash scripts start `set -euo pipefail` and `export LC_ALL=C.UTF-8` (match sibling hooks).
- No `-er`-suffixed names; methods/blocks stay focused.
- YouTrack credentials resolve only via `secret.sh youtrack` (uri + token) — never a raw `$ENV_VAR`.
- Non-ASCII safety: feed tracker responses to jq via `--slurpfile`/`--rawfile` or a file argument, never via `--arg` on the raw body (Windows argv cp1252 transcoding).
- The channel JSON shape the page reads is fixed: `{channel:"ticket", id, title, status, statusCategory, type, priority, blocked, ac:{met,total,pct}, subtasks:[{id,title,status,done}], active, url, source, updated}`.
- New code lands with a test in `hooks/board-ticket.test.sh`.
- Propagate with `/install` after merge; commit messages end with the `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` trailer.

---

### Task 1: Normalize-then-share refactor (Jira, behavior-preserving)

Refactor `board-ticket.sh` so the Jira path fetches a raw issue, normalizes it to a uniform intermediate, and a shared shaper writes the channel. Add the `--tracker` flag (default `jira`). No output change — the existing test is the guard.

**Files:**
- Modify: `hooks/board-ticket.sh`
- Test: `hooks/board-ticket.test.sh` (unchanged; the green baseline)

**Interfaces:**
- Produces (used by Task 2): a normalized intermediate written to `$norm_file` with shape
  `{id, title, status, statusCategory, type, priority, url, source, subtasks:[{id,title,status,done}]}`;
  a shared shaper jq that reads `$norm_file` (with `--arg active`, `--arg now`) and writes the channel;
  shell functions `fetch_jira`/`normalize_jira` and the `--tracker` dispatch.

- [ ] **Step 1: Run the existing test to capture the green baseline**

Run: `bash hooks/board-ticket.test.sh`
Expected: `── 4 passed, 0 failed ──`

- [ ] **Step 2: Replace argument parsing (lines ~28-35) with flag-aware parsing**

```bash
ISSUE_KEY=""
ACTIVE="false"
TRACKER="jira"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --active)  ACTIVE="true" ;;
    --tracker) TRACKER="${2:-}"; shift ;;
    -*)        echo "board-ticket: unknown flag $1" >&2; exit 1 ;;
    *)         ISSUE_KEY="$1" ;;
  esac
  shift
done

if [[ -z "$ISSUE_KEY" ]]; then
  echo "usage: board-ticket.sh <ISSUE-KEY> [--active] [--tracker jira|youtrack]" >&2
  exit 1
fi
```

- [ ] **Step 3: Replace the fetch + shape body with the normalize-then-share flow**

Replace everything from the `issue_file=$(mktemp)` block through the channel-writing `jq … > "$out_file"` (the current lines ~37-128) with:

```bash
issue_file=$(mktemp)   # raw tracker response
norm_file=$(mktemp)    # normalized intermediate
trap 'rm -f "$issue_file" "$norm_file"' EXIT

mkdir -p "$BOARD_DIR"
out_file="$BOARD_DIR/ticket-$ISSUE_KEY.json"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# The "done-enough" status names — a subtask counts met when the tracker's own
# done signal fires OR its status name is listed here. Absent/malformed, the
# name-set is empty and only the tracker's signal counts.
DONE_STATUSES="$BOARD_DIR/ac-done-statuses.json"
DONE_JSON="[]"
if [[ -f "$DONE_STATUSES" ]] && jq -e 'type == "array"' "$DONE_STATUSES" >/dev/null 2>&1; then
  DONE_JSON="$(cat "$DONE_STATUSES")"
fi

# ── Jira: fetch raw issue into $issue_file, set $BASE ──
fetch_jira() {
  BASE="https://example.atlassian.net"
  if [[ -n "${BOARD_TICKET_ISSUE_FILE:-}" ]]; then
    cp "$BOARD_TICKET_ISSUE_FILE" "$issue_file"
    return
  fi
  local jira_url jira_email jira_token http
  jira_url="$("$SECRET" jira uri 2>/dev/null || true)"
  jira_email="$("$SECRET" jira username 2>/dev/null || true)"
  jira_token="$("$SECRET" jira password JIRA_API_TOKEN 2>/dev/null || true)"
  if [[ -z "$jira_url" || -z "$jira_email" || -z "$jira_token" ]]; then
    echo "jira credentials missing (need uri, username, password from Vaultwarden item \"jira\" or env)" >&2
    exit 1
  fi
  BASE="${jira_url%/}"
  http=$(curl -sS -o "$issue_file" -w "%{http_code}" \
    -u "$jira_email:$jira_token" \
    -H "Accept: application/json" \
    "$BASE/rest/api/3/issue/$ISSUE_KEY?fields=summary,status,issuetype,priority,subtasks")
  if [[ "$http" != 2* ]]; then
    echo "fetch issue failed for $ISSUE_KEY (http=$http)" >&2
    exit 1
  fi
}

# ── Jira: raw issue -> normalized intermediate ──
normalize_jira() {
  jq --arg key "$ISSUE_KEY" --arg base "$BASE" --argjson doneNames "$DONE_JSON" '
    ($doneNames | map(select(type == "string") | ascii_downcase)) as $doneSet
    | .fields as $f
    | {
        id: $key,
        title: ($f.summary // ""),
        status: (($f.status.name) // ""),
        statusCategory: (($f.status.statusCategory.key) // ""),
        type: (($f.issuetype.name) // ""),
        priority: (($f.priority.name) // ""),
        url: ($base + "/browse/" + $key),
        source: "jira",
        subtasks: (($f.subtasks // []) | map(
          ((.fields.status.name // "") | ascii_downcase) as $sname
          | {
              id: .key,
              title: (.fields.summary // ""),
              status: ((.fields.status.name) // ""),
              done: (
                (((.fields.status.statusCategory.key) // "") == "done")
                or (($doneSet | index($sname)) != null)
              )
            }
        ))
      }
  ' "$issue_file" > "$norm_file"
}

case "$TRACKER" in
  jira)     fetch_jira;     normalize_jira ;;
  *)        echo "board-ticket: unknown tracker \"$TRACKER\"" >&2; exit 1 ;;
esac

# ── Shared shaper: normalized intermediate -> channel ──
jq --arg active "$ACTIVE" --arg now "$NOW" '
  . as $n
  | ($n.subtasks) as $roster
  | ($roster | length) as $total
  | ($roster | map(select(.done)) | length) as $met
  | {
      channel: "ticket",
      id: $n.id,
      title: $n.title,
      status: $n.status,
      statusCategory: $n.statusCategory,
      type: $n.type,
      priority: $n.priority,
      blocked: (($n.status // "") | ascii_downcase | test("block")),
      ac: {
        met: $met,
        total: $total,
        pct: (if $total > 0 then (($met * 100 / $total) | floor) else null end)
      },
      subtasks: $roster,
      active: ($active == "true"),
      url: $n.url,
      source: $n.source,
      updated: $now
    }
' "$norm_file" > "$out_file"
```

(The hero-clear python block and the `board-manifest.py` call that follow stay exactly as they are.)

- [ ] **Step 4: Run the existing test to verify no behavior change**

Run: `bash hooks/board-ticket.test.sh`
Expected: `── 4 passed, 0 failed ──` (AC math and `active` unchanged; `statusCategory` still the raw Jira key)

- [ ] **Step 5: Commit**

```bash
git add hooks/board-ticket.sh
git commit -m "Refactor board-ticket: normalize then share, add --tracker

Split the Jira path into fetch -> normalize -> shared shaper, guarded by
the existing test. Adds --tracker (default jira) for the YouTrack path.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: YouTrack fetch + normalize

Add the YouTrack branch: fetch via Bearer token, normalize its `State`/`resolved`/`Subtask`-link fields to the same intermediate. Add fixtures and tests.

**Files:**
- Modify: `hooks/board-ticket.sh`
- Test: `hooks/board-ticket.test.sh`

**Interfaces:**
- Consumes (from Task 1): `$issue_file`, `$norm_file`, `$BASE`, `$DONE_JSON`, `$ISSUE_KEY`, the shared shaper, the `case "$TRACKER"` dispatch.
- Produces: `fetch_youtrack`/`normalize_youtrack`; the writer accepts `--tracker youtrack`.

- [ ] **Step 1: Write the failing YouTrack tests**

Append to `hooks/board-ticket.test.sh`, before the final `echo ""` summary block:

```bash
# A YouTrack fixture: a parent (unresolved) with Subtask/OUTWARD links.
# Each pair is "state|resolved" where resolved is a ms epoch or the word null.
write_yt_fixture() { # file pair1 pair2 …
  local file="$1"; shift
  local subs="" i=1
  for pair in "$@"; do
    local state="${pair%%|*}" resolved="${pair##*|}"
    [[ -n "$subs" ]] && subs="$subs,"
    subs="$subs{\"idReadable\":\"MET-$i\",\"summary\":\"s$i\",\"resolved\":$resolved,\"customFields\":[{\"name\":\"State\",\"value\":{\"name\":\"$state\"}}]}"
    i=$((i + 1))
  done
  cat >"$file" <<JSON
{"idReadable":"MET-0","summary":"YT Parent","resolved":null,"customFields":[{"name":"State","value":{"name":"In Progress"}},{"name":"Type","value":{"name":"Bug"}},{"name":"Priority","value":{"name":"Normal"}}],"links":[{"direction":"OUTWARD","linkType":{"name":"Subtask"},"issues":[$subs]}]}
JSON
}

# ── 5 · YouTrack AC: a resolved subtask counts, an unresolved one does not ──
d=$(tmpdir)
issue=$(tmpfile)
write_yt_fixture "$issue" "Fixed|1700000000000" "Open|null"
BOARD_DIR="$d" BOARD_TICKET_ISSUE_FILE="$issue" bash "$WRITER" MET-1 --tracker youtrack >/dev/null 2>&1
expected_yt="1/2/50/youtrack"
actual_yt=$(jq -r '"\(.ac.met)/\(.ac.total)/\(.ac.pct)/\(.source)"' "$d/ticket-MET-1.json")
check "youtrack AC counts resolved subtask, stamps source" "$expected_yt" "$actual_yt"

# ── 6 · YouTrack done-set: an unresolved subtask in the name-set still counts ──
d=$(tmpdir)
issue=$(tmpfile)
echo '["Verified"]' >"$d/ac-done-statuses.json"
write_yt_fixture "$issue" "Fixed|1700000000000" "Verified|null" "Open|null"
BOARD_DIR="$d" BOARD_TICKET_ISSUE_FILE="$issue" bash "$WRITER" MET-2 --tracker youtrack >/dev/null 2>&1
expected_ytmap="2/3/66"
actual_ytmap=$(jq -r '"\(.ac.met)/\(.ac.total)/\(.ac.pct)"' "$d/ticket-MET-2.json")
check "youtrack done-set state counts as met" "$expected_ytmap" "$actual_ytmap"

# ── 7 · YouTrack browse url + no-subtask AC is null ──
d=$(tmpdir)
issue=$(tmpfile)
cat >"$issue" <<'JSON'
{"idReadable":"MET-9","summary":"Lonely","resolved":null,"customFields":[{"name":"State","value":{"name":"Open"}}],"links":[]}
JSON
BOARD_DIR="$d" BOARD_TICKET_ISSUE_FILE="$issue" bash "$WRITER" MET-9 --tracker youtrack >/dev/null 2>&1
expected_ytnone="null/https://youtrack.example.com/issue/MET-9"
actual_ytnone=$(jq -r '"\(.ac.pct)/\(.url)"' "$d/ticket-MET-9.json")
check "youtrack no-subtask AC null, browse url composed" "$expected_ytnone" "$actual_ytnone"
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `bash hooks/board-ticket.test.sh`
Expected: tests 5-7 FAIL (tracker `youtrack` is unknown — the writer exits non-zero, no channel written, jq reads a missing file)

- [ ] **Step 3: Add the YouTrack fetch + normalize functions**

Insert after `normalize_jira` (before the `case "$TRACKER"` dispatch):

```bash
# ── YouTrack: fetch raw issue into $issue_file, set $BASE ──
fetch_youtrack() {
  BASE="https://youtrack.example.com"
  if [[ -n "${BOARD_TICKET_ISSUE_FILE:-}" ]]; then
    cp "$BOARD_TICKET_ISSUE_FILE" "$issue_file"
    return
  fi
  local yt_url yt_token http
  yt_url="$("$SECRET" youtrack uri 2>/dev/null || true)"
  yt_token="$("$SECRET" youtrack 2>/dev/null || true)"
  if [[ -z "$yt_url" || -z "$yt_token" ]]; then
    echo "youtrack credentials missing (need uri + token from Vaultwarden item \"youtrack\" or env)" >&2
    exit 1
  fi
  BASE="${yt_url%/}"
  local fields="idReadable,summary,resolved,customFields(name,value(name)),links(direction,linkType(name),issues(idReadable,summary,resolved,customFields(name,value(name))))"
  http=$(curl -sS -o "$issue_file" -w "%{http_code}" \
    -H "Authorization: Bearer $yt_token" \
    -H "Accept: application/json" \
    "$BASE/api/issues/$ISSUE_KEY?fields=$fields")
  if [[ "$http" != 2* ]]; then
    echo "fetch issue failed for $ISSUE_KEY (http=$http)" >&2
    exit 1
  fi
}

# ── YouTrack: raw issue -> normalized intermediate ──
normalize_youtrack() {
  jq --arg key "$ISSUE_KEY" --arg base "$BASE" --argjson doneNames "$DONE_JSON" '
    def cf($fields; $name): (($fields // []) | map(select(.name == $name)) | (.[0].value.name? // ""));
    def isdone($resolved; $state; $doneSet):
      (($resolved != null) or (($doneSet | index(($state // "") | ascii_downcase)) != null));
    ($doneNames | map(select(type == "string") | ascii_downcase)) as $doneSet
    | {
        id: (.idReadable // $key),
        title: (.summary // ""),
        status: (cf(.customFields; "State")),
        statusCategory: (if .resolved != null then "done" else "" end),
        type: (cf(.customFields; "Type")),
        priority: (cf(.customFields; "Priority")),
        url: ($base + "/issue/" + $key),
        source: "youtrack",
        subtasks: (
          (.links // [])
          | map(select((.linkType.name == "Subtask") and (.direction == "OUTWARD")))
          | (map(.issues // []) | add // [])
          | map(
              (cf(.customFields; "State")) as $sstate
              | {
                  id: (.idReadable // ""),
                  title: (.summary // ""),
                  status: $sstate,
                  done: isdone(.resolved; $sstate; $doneSet)
                }
            )
        )
      }
  ' "$issue_file" > "$norm_file"
}
```

- [ ] **Step 4: Add the youtrack case to the dispatch**

Change the `case "$TRACKER"` block to:

```bash
case "$TRACKER" in
  jira)     fetch_jira;     normalize_jira ;;
  youtrack) fetch_youtrack; normalize_youtrack ;;
  *)        echo "board-ticket: unknown tracker \"$TRACKER\"" >&2; exit 1 ;;
esac
```

- [ ] **Step 5: Run the tests to verify all pass**

Run: `bash hooks/board-ticket.test.sh`
Expected: `── 7 passed, 0 failed ──`

- [ ] **Step 6: Commit**

```bash
git add hooks/board-ticket.sh hooks/board-ticket.test.sh
git commit -m "Add YouTrack fetch + normalize to board-ticket

State/resolved/Subtask-link fields map to the shared intermediate; done
from resolved or the done-set state. Fixtures cover AC, the name-set
override, and the no-subtask/url case.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Route by tracker — refresh + /board skill

`board.sh refresh` re-derives the tracker from each channel's `.source`; the `/board` skill resolves the tracker from the prefix on `add`.

**Files:**
- Modify: `hooks/board.sh` (the `refresh` loop)
- Modify: `.claude/skills/board/SKILL.md` (the `add` section) — source at `skills/board/SKILL.md`

**Interfaces:**
- Consumes: `board-ticket.sh <KEY> [--active] --tracker <jira|youtrack>` from Tasks 1-2.

- [ ] **Step 1: Update the refresh loop to pass the recorded tracker**

In `hooks/board.sh`, replace the `refresh` loop body:

```bash
    shopt -s nullglob
    for chan in "$BOARD_DIR"/ticket-*.json; do
      id="$(jq -r '.id' "$chan")"
      tracker="$(jq -r '.source // "jira"' "$chan")"
      if [[ "$(jq -r '.active' "$chan")" == "true" ]]; then
        "$DIR/board-ticket.sh" "$id" --active --tracker "$tracker"
      else
        "$DIR/board-ticket.sh" "$id" --tracker "$tracker"
      fi
    done
    "$DIR/board-growth.sh" || echo "board: growth refresh failed (skipped)" >&2
    "$DIR/board-henneth.sh" || echo "board: henneth link refresh failed (skipped)" >&2
    ;;
```

- [ ] **Step 2: Verify refresh routing by reading a recorded channel back**

Run:
```bash
d=$(mktemp -d)
printf '%s' '{"idReadable":"MET-1","summary":"P","resolved":null,"customFields":[{"name":"State","value":{"name":"Open"}}],"links":[]}' > "$d/yt.json"
BOARD_DIR="$d" BOARD_TICKET_ISSUE_FILE="$d/yt.json" bash hooks/board-ticket.sh MET-1 --tracker youtrack >/dev/null
jq -r '.source' "$d/ticket-MET-1.json"
```
Expected: `youtrack` — confirming the channel records the tracker that `refresh` reads back via `.source`. (Full `refresh` hits the live tracker, so this stands in for the routing check.)

- [ ] **Step 3: Update the /board skill's `add` section**

In `skills/board/SKILL.md`, under `### /board add <KEY> [--active]`, add after the existing description:

```markdown
**Tracker routing.** Before dispatching, resolve the tracker from the key's
project prefix via the `tracker_routing` memory (e.g. `MET → youtrack`,
`PSG → jira`), the same map `/council` and `/glorfindel` use. Default to
`jira` when the prefix is unmapped. Pass it through:

    ~/.claude/hooks/board.sh add MET-1 --active --tracker youtrack

`board.sh add` forwards all arguments to the ticket writer, so `--tracker`
reaches it unchanged. On `refresh`, the tracker is re-derived from each
channel's recorded `source` — no memory lookup needed.
```

- [ ] **Step 4: Run the full ticket suite to confirm nothing regressed**

Run: `bash hooks/board-ticket.test.sh`
Expected: `── 7 passed, 0 failed ──`

- [ ] **Step 5: Commit**

```bash
git add hooks/board.sh skills/board/SKILL.md
git commit -m "Route board tickets by tracker on refresh and add

refresh re-derives each ticket's tracker from its recorded source; the
/board skill resolves the tracker from the key prefix on add.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Notes for the implementer

- After all tasks land and merge, run `/install` to propagate the hooks and skill into every configured root.
- The board page (`board-index.html`) needs **no change** — YouTrack channels carry the same shape; `source: "youtrack"` and the `/issue/<id>` URL flow through the existing tiles and Enter door.
- Manual end-to-end check once credentials are present: `/board add MET-1 --active` seats a real YouTrack ticket; confirm its tile shows status, AC, and an Enter door to the YouTrack issue.
