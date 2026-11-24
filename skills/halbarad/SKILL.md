---
name: halbarad
description: Use when the user runs /halbarad [mail|teams|jira]. One read-only sweep of Outlook, Teams and Jira that prints a single brief of what is new since the last run and wants the user — a ranked NEEDS ME list, then Mail, Teams and Jira sections. Mail and Teams come from /gwaihir unchanged; Jira is its own pass (assigned to the user or mentioning them). Each source keeps its own cursor and a failed source never moves it. Never writes to Outlook, Teams or Jira; acting stays with /triage and /vor.
purpose: Sweeps Outlook, Teams and Jira into one brief of what is new since the last run.
user_invocable: true
stage: intake
composes: gwaihir:dispatch, triage:companion, vor:companion
---

# Halbarad — the Ranger Who Carried Word North

Halbarad rode south with the Dúnedain to bring word where it was owed. This
skill does the same errand for the inbox: it gathers what arrived since the
last ride and lays it in one place. **It reads and surfaces. It never acts.**
Replying and triage stay with `/triage` (mail) and `/vor` (Teams).

## Arguments

`/halbarad [source]` — optional.

- No argument → the full brief: every source, capped.
- `mail`, `teams` or `jira` → the drill-down: that one source, no cap (see
  *Drill-down*).

## State

Every state file sits beside the profile's other Skadi state. All reads and
writes go through one tool, `~/.claude/hooks/halbarad-jira.sh` (Jira's delta
pass, plus the cursor and last-list verbs for the other sources):

- `halbarad-jira.sh cursor get <source>` / `cursor set <source> <iso-utc>` —
  one cursor per source (`mail`, `jira`). Teams keeps no cursor here: its
  poller (inside `/gwaihir`) reads its own delta.
- `halbarad-jira.sh last put <source>` (JSON on stdin) / `last get <source>` —
  the full list of the latest brief, for the drill-down.

**A source that fails never advances its own cursor.** The others still render;
the failed one is footnoted.

## Workflow

Take the run's start stamp once, `date -u +%Y-%m-%dT%H:%M:%SZ` — call it `NOW`.
Gather all three sources before rendering anything. Fetch each source once.

### 1. Mail and Teams — through `/gwaihir`

Do not copy `/gwaihir`'s logic; run it and take its result as data.

- Mail window: read `cursor get mail`. Pass `/gwaihir` the whole number of hours
  from that cursor to `NOW`, rounded up, at least `1`; with no cursor, `24`.
- Run `/gwaihir <hours>` and use what it gathered — worth-a-look mail rows,
  Teams threads (`@you:` mentions first, then `Q:` questions), the routine
  tallies, and its footer notes. Print none of its own brief; step 4 prints
  the one brief.
- Times in `/gwaihir`'s rows are local; compare them with the cursor in local
  time. Drop every mail row received at or before the mail cursor — `/gwaihir` asks
  for unread mail by whole hours, so rows from before the cursor can come back.
  Teams needs no such cut: its poller already returns only the delta.
- Mail is **answered** when `/gwaihir` did not footnote it silent. When it is
  answered and at least one message (worth-a-look or routine) is new, run
  `cursor set mail NOW`; when nothing is new, leave the cursor. When it is
  silent, leave the cursor and carry `/gwaihir`'s reason forward.
- Teams silent → carry the reason forward as a footnote.
- Keep the full mail and Teams lists for the drill-down:
  `last put mail` and `last put teams`, each fed a small JSON object
  (`{"worth":[…],"routine":N}` for mail, `{"threads":[…],"routine":N}` for
  Teams — the rows as `/gwaihir` gave them). Store a source only when it was
  answered and had something new; otherwise the previous list stays.

### 2. Jira

Run `~/.claude/hooks/halbarad-jira.sh` with no arguments. It prints one JSON
object and handles its own cursor and its own last-list.

- Exit `0`, `status: ok` — read `tickets` (newest first). Each carries `key`,
  `summary`, `status`, `url`, `assigned`, `reopened`, `reassigned_to_me`,
  `changes` (others' changes after the cursor: `who`, `local`, `kind`, `from`,
  `to`) and `mentions` (`who`, `local`, `quote`). A ticket is here because the
  user is assigned or mentioned **and** someone else touched it after the
  cursor — the user's own edits never count.
- Exit `2` or `4`, `status: error` — Jira is silent. Footnote
  `Jira: <reason> — cursor NOT advanced for Jira`. The tool has left the
  cursor where it was.

The tool finds mentions in the comments' mention nodes: Jira's docs offer no
reliable mention search in JQL ([JRACLOUD-27594](https://jira.atlassian.com/browse/JRACLOUD-27594)),
so JQL only narrows the candidates. Mentions in a ticket's description, not its
comments, are not seen.

### 3. Rank NEEDS ME

Collect these items from all answered sources:

- every Jira ticket that is `reopened`, has a `mention`, or is `reassigned_to_me`;
- every surfaced Teams thread;
- every worth-a-look mail.

Order them in four tiers. Inside a tier, newest first by latest activity — a
ticket's latest change or mention, a row's own time; an item with no time
(a Teams thread) sorts after the timed ones, in `/gwaihir`'s order:

1. Jira reopened, or Jira mention.
2. A human asking directly — a Teams `@you:` or `Q:` thread; mail from a real
   person writing to the user, or carrying an action-by date.
3. Jira reassigned to the user.
4. Routine alerts — monitoring and system mail, and the rest.

Show the top **8**. The heading carries the true total: `NEEDS ME  (9)`, and
when more than 8 qualify, `NEEDS ME  (9)  showing top 8 · +1 more`. The rest
stay in their sections. Each item is one source tag, its title line, and one
`→` line: the strongest reason (`status Done→Reopened`, `mention by <who>`,
`<who>: "<quote>"`, `assigned to you`); several mentions on a ticket appear as
`N mentions` here, and in full in the JIRA section. A Jira ticket that is merely assigned and
changed is not a NEEDS ME item; it lives in the JIRA section only.

### 4. Render

One brief. Shapes follow the three states of `wireframe-halbarad-brief.html`.

**Header.** `Halbarad — since <earliest window start among the answered
sources that keep a cursor — mail and Jira — local> (<span>)`; with no cursor
yet, the 24h window's start. The span is `NOW` minus that start, as `4h 31m`;
past a day, whole hours only (`99h`).

**Populated.**

    Halbarad — since 2026-11-24 08:12 (4h 31m)
    NEEDS ME  (3)
     [Jira]  PSG-4716  Crashlytics provider not overridden
             → status Done→Reopened · comment by Vivian
     [Teams] Vivian Yen · Daily Care
             → "can you confirm the release window?"
     [Mail]  Jubo Infra · [ALERT] disk 91% on build-02
             → monitoring alert, open
    MAIL   1 worth a look · 17 routine
    TEAMS  2 threads want a reply · 5 quiet
    JIRA   4 moved · 2 mention you · 1 reassigned to you
    cursor → mail 2026-11-24 12:43 · jira 2026-11-24 12:43

Counters: `JIRA  N moved · M mention you · K reassigned to you` — `N` is every
ticket listed, `M` those with a mention, `K` those reassigned to the user;
`TEAMS  N threads want a reply · J quiet` — `J` is the routine tally.

Under each counter, list up to **5** items; Jira's in the NEEDS ME order
(reopened, mentioned, reassigned, then the rest). When a source has more, end its
list with `+N more — /halbarad <source>`.

- Mail item: `<local time>  <sender>  <subject>`.
- Teams item: `<thread>  @you: | Q:  <text>`.
- Jira item: the ticket line `<KEY>  <summary>`, a second line with the change
  (`Done → Reopened · 08:41`, `reassigned to you by <who>`, `mentions you`,
  `comment by <who> <time>`, `<field> change by <who>`), and
  **one line per mention**: `· <who> <time>  "<quote>"`. Several mentions on one
  ticket stay several lines; they are never merged.
- In a chat render, write each ticket key as a link, per the tracker-key rule
  in `CLAUDE.md`; the tool's `url` field carries the address.

**Empty** — every answered source has nothing new:

    Halbarad — since 2026-11-24 12:43 (2m)
    Nothing new.
    MAIL   0 new
    TEAMS  0 new
    JIRA   0 moved
    cursor unchanged · 2026-11-24 12:43

A second run straight after the first lands here for every source.

The last line names each cursor: `cursor → <source> <local time>` for one that
moved this run, `<source> unchanged` for one that did not (`cursor unchanged ·
<time>` when none moved).

**Footnotes** close the brief, one line per silent source — `Mail: <reason>` and
`Teams: <reason>` with `/gwaihir`'s reason, Jira as in step 2. A silent source's section is replaced by
its footnote; the others still render. When every source is silent, print the
header, `Nothing to look through.`, and the footnotes.

**Overflow.** Ticket keys, counts and any date or time standing as its own
field are never truncated. Identity text — a summary, a subject, a sender, a
thread name — ellipses at the end of its line; a date that sits inside such text
goes with the text. A quote ellipses at the line's end. The full value lives in the ticket or
the mail.

### 5. Persist and feed the board

After the brief prints:

1. The cursors are already set (steps 1 and 2).
2. **Board feed — the mail row only.** Whenever mail was answered, even with
   nothing new (then `0` and `0`), write the mail count to the board with
   the same pattern `/board` uses: a scratch JSON file
   `{"count": <worth-a-look>, "detail": "<N> worth a look · <K> routine",
   "url": "https://outlook.office.com/mail/"}`, then
   `~/.claude/hooks/board-attention.sh mail --from-json <file>`. When the Outlook
   connector was dark this run, run `~/.claude/hooks/board-attention.sh mail --clear`
   instead — the row is accurate or absent, never stale.
3. **Never touch the board's Jira row** — the board keeps its own definition of
   it — and **write no Teams row**.

## Drill-down

`/halbarad jira`, `mail` or `teams` opens one source in full, with no cap and no
fetch: read `halbarad-jira.sh last get <source>` and print the list the latest
brief stored, under a header naming that brief's time (`from the brief of
<local time>`). A drill-down never moves a cursor and never writes the board.

- Jira shows each ticket as in step 4 plus its whole `changes` list and every
  mention line, and ends with `showing N of N`.
- No stored list for the source (nothing new at the last brief, or no brief yet)
  → say so in one line, and point to `/halbarad` for a fresh run.

## Read-only guarantee

Every call is read-shaped: `/gwaihir`'s, Jira's GET requests inside
`halbarad-jira.sh`, and local state files. The only writes are Skadi's own — the
cursors, the stored lists, and the board's mail row. Nothing is sent to Outlook,
Teams or Jira, and nothing is drafted.

## Rules

- Never copy `/gwaihir`'s classification or polling; run it.
- Never advance a cursor for a source that failed.
- Never write the board's Jira row, and never write a Teams row.
- No built-in timer: to repeat the sweep, wrap `/halbarad` in `/loop` or
  `/amon-sul`.
- Reveal no mail body — subject and sender suffice, as in `/gwaihir`.
