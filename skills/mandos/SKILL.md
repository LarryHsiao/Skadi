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
