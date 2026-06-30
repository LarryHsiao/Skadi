---
name: mandos
description: Use when the user runs /mandos, /mandos TICKET-ID, /mandos <pr-or-mr-url>, /mandos post TICKET-ID, or /mandos comment <url>. With no argument, weighs the current branch against its ticket's goal, deriving the ticket from the branch name or recent commits; with a ticket ID, fetches the goal and resolves the branch from the ticket's [GWAITH] forge comment or naming conventions; with a URL, weighs an open PR/MR against its ticket. Reads by default — plain forms render to chat. Two opt-in write verbs: `post` threads a [DOOM] verdict onto the ticket (confirm-once); `comment` posts it on the PR/MR (confirm-once). The verdict pronounces faithfulness — Covered / Missing / Scope-crept — against the ticket's [COUNSEL]/[PLAN] comment, the ticket's own description, and the parent ticket's acceptance criteria, as returned by the council fetch hooks. Where Mithrandir weighs whether the code is good, Mandos weighs whether it is the right code. The `--deep` flag runs a per-criterion fan-out (defined in a later task). The `--plain` and `--lore` flags override the tone default and are mutually exclusive. Advisory — never auto-gates a merge.
user_invocable: true
---

# Mandos — The Doom

Námo, Keeper of the Halls of Waiting, is the Doomsman of the Valar — he who weighs each finished deed against the decree that preceded it. Where Mithrandir asks whether the code is sound, Mandos asks whether it answers the decree: whether the work is *faithful* to the ticket's goal. He speaks, and his word is final; but the decision of what to do with that word rests with Elrond.

## Ethos

- **Weighs faithfulness, not quality.** Mithrandir judges whether the code is sound; Mandos judges whether it answers the decree. Three verdicts: Covered — the deed matches the goal; Missing — the goal is only partly met; Scope-crept — the deed exceeds or contradicts what was asked. Quality concerns belong to Mithrandir.
- **Reads by default; writes only when summoned.** Plain forms render to chat. `post` and `comment` are the only write paths, and each asks once before touching the tracker or the forge.
- **Independent of the conversation.** The decree is re-derived fresh from the tracker — the ticket's `[COUNSEL]`/`[PLAN]` comment, its own description, and the parent ticket's acceptance criteria — and the weighing runs in a read-only subagent blind to the build conversation.
- **Advisory, never doom proper.** A verdict of Missing or Scope-crept does not auto-block any merge skill; the decision rests with the human. Mandos pronounces; Elrond weighs further.

## Argument parsing

```
/mandos                      # branch-path: current branch vs base; derive ticket from branch name / commits
/mandos TICKET-ID            # ticket-path: fetch goal; resolve branch from [GWAITH] forge comment / naming
/mandos <pr-or-mr-url>       # URL-path: weigh an open PR/MR against its ticket
/mandos post TICKET-ID       # ticket-write: thread [DOOM] verdict onto the ticket (confirm-once)
/mandos comment <url>        # forge-write: post verdict on the PR/MR (confirm-once)

# flags (compose with any read or write form):
--deep                       # per-criterion fan-out (defined in a later task)
--plain / --lore             # tone override (mutually exclusive)
```

Dispatch on the **first positional argument**:

- If there is no first positional, run the **branch-path** against the current branch, deriving the ticket from the branch name or recent commits.
- If the first positional is the literal token `post`, the second positional is the TICKET-ID and the **ticket-write path** runs.
- If the first positional is the literal token `comment`, the second positional is the URL and the **forge-write path** runs.
- If the first positional looks like a URL (`http://` or `https://` prefix), the **URL read-path** runs against it.
- If the first positional, after stripping any optional tracker prefix (e.g. `youtrack:`, `yt:`, `jira:`), matches the ticket-id shape `[A-Za-z]+-[0-9]+`, treat it as a TICKET-ID and run the **ticket read-path**.
- Otherwise, a token that cannot be dispatched to any path draws: *"Mandos knows only `post` and `comment` as verbs; a bare URL rides the read-path, a bare ticket-id the ticket-path, and the empty word the branch-path."*

The flags `--plain` and `--lore` may appear anywhere after the verb/URL; they are mutually exclusive. If both are passed, stop with: *"`--plain` and `--lore` cannot stand together; choose one tongue."*

The `--deep` flag may also appear anywhere after the verb/URL. It composes with any path or tone flag — it changes the *depth* of the weighing, not the voice. Its mechanism is specified in a later task; here it is accepted, parsed, and passed into the weighing step.

## Tracker routing

Two trackers are wired:

| Tracker | Fetch hook | Comment hook |
|---|---|---|
| YouTrack | `~/.claude/hooks/council-youtrack-fetch.sh` | `~/.claude/hooks/council-youtrack-comment.sh` |
| Jira | `~/.claude/hooks/council-jira-fetch.sh` | `~/.claude/hooks/council-jira-comment.sh` |

The fetch hooks return the ticket's summary, description, and comments.

**Hybrid dispatch rule.** Resolve the tracker for a given ticket ID in this order:

1. **Explicit override.** If the ticket ID carries a tracker prefix — `youtrack:MET-1`, `yt:MET-1`, `jira:PSG-4264` — that wins. Strip the prefix and use the remainder as the ticket ID. Accept `youtrack` or `yt`; accept `jira`. Case-insensitive.
2. **Per-project memory.** Read `tracker_routing.md` from the project memory directory. The file maps a project key prefix to a tracker:

   ```markdown
   ---
   name: Tracker Routing
   description: Project-key prefix to tracker mapping for /council and /glorfindel.
   type: reference
   ---

   - MET → youtrack
   - PSG → jira
   ```

   Match the prefix of the ticket ID (`MET-1` → prefix `MET`) against the table; if found, use the named tracker.
3. **Ask.** No prefix override, no memory mapping — ask the user via AskUserQuestion which tracker to use, then offer to save the mapping to memory for next time.

Once the tracker is chosen, all steps that fetch or comment on the ticket use that backend's hooks. Do not hardcode any list of valid project-key prefixes — the prefix is just a project shortName.

## Spec harvest

From the fetched ticket data Mandos folds a **decree** — an ordered list of acceptance items, each tagged by its source, that the weighing step will hold the deed against. Three sources are drawn in turn; every item found is kept, tagged, and placed in order.

### 1. Plan

From the ticket's comment thread, take the body of the newest comment whose first line matches `[COUNSEL vN]` (any N) or the bare `[PLAN]` marker (case-insensitive). This is Erestor's settled plan — the sharpest statement of what the deed was asked to do. Each acceptance item it names is tagged `[COUNSEL]` in the decree.

If no such comment exists, note plainly that the plan source is absent. The decree leans on ticket text and parent AC alone; the weighing step is told the plan is missing.

### 2. Ticket text

Take the ticket's `summary` and `description`. Scan for an acceptance-criteria list:

- Lines under a heading that matches (case-insensitive) `acceptance`, `AC`, or `criteria`.
- A checkbox (`- [ ]` / `- [x]`) or bullet list that reads as criteria rather than prose.

Each item found is tagged `<ticket-id>` in the decree (e.g. `MET-1`).

### 3. Parent AC

If the fetch hook's `parent` key is non-null — the ticket belongs to an epic or parent story — scan `parent.description` for an AC list by the same rules as step 2. Parent AC is often the sharpest gate: epics carry the criteria the leaf ticket inherits. Each item found is tagged `<parent-id> AC` in the decree (e.g. `MET-1 AC`, where `MET-1` is the parent's id).

### No-AC fallback

If no explicit acceptance items are found in any of the three sources, derive implicit acceptance from the ticket description — its stated intent, the verb in the summary, the goal the description body implies. The weighing step proceeds, but the render **must say plainly** that the gate is softer: implicit criteria, not an explicit AC list. Do not silently proceed as if AC existed — Mandos speaks plainly or not at all.

The folded decree — items from all three sources, each tagged `[COUNSEL]`, `<ticket-id>`, or `<parent-id> AC` — is what the weighing step (a later task) consumes.

## Resolution

Mandos walks one of three paths to gather the diff and the decree, chosen by how he was summoned.

### Branch-path (no positional argument)

#### 1. Resolve the base

Find the project's default base branch — the first of `master`, `main`, `origin/HEAD` that resolves locally:

```bash
git rev-parse --verify --quiet master \
  || git rev-parse --verify --quiet main \
  || git rev-parse --verify --quiet origin/HEAD
```

If none resolves, stop with: *"Mandos cannot find a base — neither `master`, `main`, nor `origin/HEAD` stands in this repo. Name the base, or stand on firmer ground."*

#### 2. Guard against the base branch

```bash
git rev-parse --abbrev-ref HEAD
```

If the current branch matches the resolved base, or is one of the literal names `master` or `main`, stop with: *"Nothing to weigh — you stand on the default branch. The decree needs a deed to weigh against; branch off first."*

#### 3. Derive the ticket-id

Mandos cannot weigh a deed that bears no decree. Search in order:

1. The branch name. If it carries a leading token matching `^[A-Za-z]+-[0-9]+` (e.g. `MET-1-my-feature` → `MET-1`), that is the ticket-id.
2. If the branch name bears no such prefix, scan commit subjects: `git log <base>..HEAD --format=%s` and take the first token matching `^[A-Za-z]+-[0-9]+` found in any subject line.

If neither yields a ticket-id, stop with: *"Mandos cannot weigh this branch — no ticket marks it. The decree must have a name; add the ticket-id to the branch name or to a commit subject, then return."*

With the ticket-id resolved, apply **Tracker routing** to choose the fetch hook, then fetch the ticket and harvest the decree per **Spec harvest** above.

#### 4. Capture the diff

```bash
git diff $(git merge-base HEAD <base>)..HEAD
```

If the diff is empty, stop with: *"Nothing to weigh — the branch stands even with its base."*

### Ticket-path (`TICKET-ID` positional)

#### 1. Fetch and harvest

Apply **Tracker routing** to resolve the fetch hook. Invoke it:

```bash
<fetch-hook> <TICKET-ID>
```

The hook returns a single JSON object:

```json
{
  "summary": "...",
  "description": "...",
  "parent": { "id": "...", "summary": "...", "description": "..." },
  "comments": [
    { "author": "...", "login": "...", "text": "...", "created": 1700000000000 }
  ]
}
```

`parent` may be `null` if the ticket has no parent. On `{"error":"..."}`, surface the error and stop. Harvest the decree per **Spec harvest** above.

#### 2. Resolve the branch

Search in order:

1. **`[GWAITH]` comment.** Scan the thread for a comment whose first line carries the `[GWAITH]` token (or its aliases `[FORGED]`, `[SHIPPED]`, case-insensitive). Its body carries the PR/MR URL and the branch name — read both. This is Celebrimbor's mark: the deed is wrought, the forge is named.
2. **Local branch by name.** If no `[GWAITH]` comment is found, search local branches:
   ```bash
   git branch --list "*<ticket-id>*"
   ```
   Take the first match whose name carries the ticket-id.

If neither resolves a branch, stop with: *"No forged branch found for `<ticket-id>`. Celebrimbor has not yet marked the deed — check the ticket thread for a `[GWAITH]` comment, or name the branch directly."*

#### 3. Resolve the base and capture the diff

Resolve the base via the same ladder as the branch-path (step 1 above). Guard against the base branch the same way. Capture the diff:

```bash
git diff $(git merge-base HEAD <base>)..HEAD
```

where `HEAD` is resolved against the branch found in step 2.

### URL-path (`http(s)://...` positional)

#### 1. Forge dispatch

Match the URL against the same host-agnostic patterns Mithrandir uses:

| Forge | Pattern | Read hook |
|---|---|---|
| GitHub | `https?://[^/]+/(?<owner>[^/]+)/(?<repo>[^/]+)/pull/(?<n>\d+)` | `~/.claude/hooks/lindir-github-pr.sh` |
| GitLab | `https?://[^/]+/(?<group>.+)/-/merge_requests/(?<iid>\d+)` | `~/.claude/hooks/lindir-gitlab-mr.sh` |

If neither pattern matches, stop with: *"Mandos does not know that URL — it bears no PR or MR mark."*

#### 2. Fetch metadata and diff

```bash
<read-hook> <url>
```

Read the title, source-branch name, and description from the hook's JSON. Then:

```bash
<read-hook> --diff <url>
```

This unified diff is the deed Mandos weighs. If the diff call fails, render the verdict on metadata alone and say so plainly.

#### 3. Derive the ticket-id and harvest the decree

Search in order:

1. The PR/MR title — take the first token matching `^[A-Za-z]+-[0-9]+`.
2. The source-branch name — take the first token matching `^[A-Za-z]+-[0-9]+`.

If a ticket-id is found, apply **Tracker routing**, fetch the ticket, and harvest the decree per **Spec harvest** above.

If no ticket-id can be read from the PR/MR, proceed using the PR/MR's own `description` as the (softer) decree — and say so plainly in the render: *"No ticket found; the decree is drawn from the PR/MR description alone — the gate is softer."*

## Weigh

Mandos's verdict springs from a read-only subagent — the Doomsman himself — whose sole input is the decree and the diff. He has seen neither this session's build conversation nor Elrond's prior comments; his eyes rest on the deed alone. **This is the independence guarantee: fresh eyes by construction.** The weigher receives the decree and the diff, nothing more; the independence of his verdict is the whole point of the skill.

### Default (holistic) — one weigher, the whole decree

Load the Doomsman's prompt from `<skill-dir>/mandos.md` (read the file contents). Dispatch a subagent via the Agent tool, `subagent_type: general-purpose`, `model: opus`, passing:

- The `mandos.md` prompt as the instruction portion of the Agent call's `prompt`.
- A tail block carrying the decree and the diff:

```
## Decree

The following acceptance items were drawn from the ticket. Each item is prefixed by
its source tag: [COUNSEL] (from Erestor's settled plan), <ticket-id> (from the
ticket's own AC), or <parent-id> AC (from the parent ticket's AC).

<decree items, one per line, each prefixed by its source tag>

[Note any absent source — e.g. "No [COUNSEL] plan found; decree drawn from ticket
text and parent AC only." or "No explicit AC found; decree derived from ticket
description — implicit criteria, softer gate."]

## Diff

<unified diff of the deed>
```

The subagent reads only — it does not write, commit, or post. It returns the three-bucket structured body (Covered / Missing / Scope-crept) and declares the tier. Carry its output into the Render step.

### `--deep` — per-criterion fan-out

When `--deep` is active, do not dispatch a single weigher over the whole decree. Instead:

1. **Partition** the decree into its individual acceptance items.
2. **Fan out.** Dispatch one read-only weigher subagent per acceptance item, in parallel — cap concurrent dispatches to a sane handful and queue the rest. Hand each agent **only its one item** as the decree and the **full diff**, charged to hunt the whole diff for evidence that this one item is met. Use the same `skills/mandos/mandos.md` prompt; only the tail block differs — the decree carries a single item, the diff is the full diff unchanged.
3. **Aggregate.** Collect every per-item verdict into the three buckets. All items returned Covered (with their `file:line` evidence) form the Covered section; all items returned Missing (with their severities) form the Missing section.
4. **Scope-crept pass.** After all per-item weighers have returned, dispatch **one final read-only weigher subagent** (same `skills/mandos/mandos.md` prompt, `general-purpose`, `model: opus`), handed the full decree and the full diff, charged ONLY to name changes that no acceptance item asked for as Scope-crept (with severities). The skill body aggregates its result; it does not itself judge scope-crept.
5. **Render** per the Render section below, with the deep-mode tail-line added under the blockquote header: *"Deep mode — N criteria weighed each on its own."*

The unit of the deep pass is the **acceptance criterion**, not the file. Where Mithrandir's `--deep` weighs one file per agent, Mandos's `--deep` weighs one acceptance item per agent — each agent receives the deed in full; the per-agent partition is the decree. No agent sees another's item; each hunts independently.

All per-criterion subagents read only — they find and report; they do not edit, commit, or post. The skill body owns aggregation and any forge write.

## Render

Render the verdict in plain markdown in this order. The title line and closing paragraph follow the active tone mode (lore by default in chat; plain by default when posting to a forge or ticket). Tiers, gauges, source tags, and section headings stay plain in both modes — only the title line and closing paragraph shift voice.

```
> <gauge> **<tier>** — <one-clause justification, ≤ 15 words>

# Mandos — <ticket-id>: <summary>
<branch> → <base> · weighed against <sources>

## Covered
- `<source-tag>` — <evidence> `file:line`

## Missing            ← omit section if empty
### Blocker           ← omit subsection if empty
- `<source-tag>` — <what was asked, not found>
### Nice-to-have      ← omit subsection if empty
- `<source-tag>` — <what was asked, not found>
### Nit               ← omit subsection if empty
- `<source-tag>` — <what was asked, not found>

## Scope-crept        ← omit section if empty
### Blocker           ← omit subsection if empty
- `file:line` — <what the change does, not asked for>
### Nice-to-have      ← omit subsection if empty
- `file:line` — <what the change does, not asked for>
### Nit               ← omit subsection if empty
- `file:line` — <what the change does, not asked for>

## Doom <gauge>  <tier>

<one paragraph naming the chief gap, or affirming faithful work, in the active tone>
```

**Blockquote header** — the first line distils the verdict to a single clause. Gauge and action label by tier:

- `▰▱▱ **Faithful**` — every acceptance line is met; no drift.
- `▰▰▱ **Hold**` — at least one Blocker outstanding; work wavers.
- `▰▰▰ **Astray**` — several Blockers; the deed strays from the decree.

The justification clause is ≤ 15 words and aligns with the chief concern named in the closing paragraph.

**Sources line** — `weighed against [COUNSEL] + <ticket-id> + parent AC (<parent-id>)`. Omit any source that was not found (e.g. omit `parent AC (…)` when there is no parent; omit `[COUNSEL]` when no plan exists). When the no-AC fallback fired, append: *"implicit criteria — softer gate"*.

**`--deep` tail-line** — when `--deep` is active, add one line immediately under the blockquote header (before the title line): *"Deep mode — N criteria weighed each on its own."*

**Governing principle:** only Blocker severity gates the tier; Nice-to-have and Nit are reported, not gating.

**Gate rule (restate for render):**
- Any **Blocker**-severity item (Missing or Scope-crept) → **Hold** (`▰▰▱`).
- Several Blocker-severity items → **Astray** (`▰▰▰`).
- No Blocker-severity item → **Faithful** (`▰▱▱`) — **Nice-to-have and Nit** gaps (Missing or Scope-crept) are reported in their buckets but do NOT change the tier.
- A clean covering (nothing Missing or crept) → **Faithful** (`▰▱▱`).

**Tone modes** — mirror Mithrandir's axis:

| Mode | Chat default | Forge/ticket-post default | What changes |
|---|---|---|---|
| **lore** | yes | no | Title `Mandos — <ticket-id>: <summary>`; closing paragraph in narrator voice; Tolkien diction permitted |
| **plain** | no | yes | Title `Faithfulness Review — <ticket-id>: <summary>`; closing paragraph in plain reviewer voice; no persona, no similes, no lore-words |

The `--plain` and `--lore` flags override either default; they are mutually exclusive. Tier labels (`Faithful` / `Hold` / `Astray`), gauges (`▰▱▱` / `▰▰▱` / `▰▰▰`), source tags (`[COUNSEL]`, `<ticket-id>`, `<parent-id> AC`), and section headings stay plain in both modes.

**Closing paragraph** — three sentences at most. Names the chief gap (for Hold / Astray) or plainly affirms the work (for Faithful). In lore mode the paragraph may carry Mandos / Valar / Elrond diction; in plain mode it stays in neutral reviewer voice with no persona, no similes, no lore-words.
