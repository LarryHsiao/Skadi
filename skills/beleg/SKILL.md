---
name: beleg
description: Use when the user runs /beleg, /beleg <firebase-project> <bundle-id> [platform], or asks in plain words to "what's crashing", "rank our crashes", "which crash should I fix first". Reads an app's Crashlytics issues, ranks them by impact rather than volume — distinct users, trend, version concentration, and whether the blaming frame is code you can actually reach — then reads the source at that frame and suggests a fix for the top few. Prefers the Crashlytics BigQuery export; falls back to scraping the Firebase console through Chrome when no export exists, ranking on thinner evidence and saying so. Read-only: it never writes to Firebase, the tracker, or your branches.
---

# Beleg — the crash, tracked home

Beleg Cúthalion followed a trail across a continent to its end. This skill follows
a crash from its stack frame to the line of code that caused it.

Read-only. It opens no PR, files no ticket, edits no source.

## 1. Resolve the binding

Read the `crash_routing.md` auto-memory. It maps a repo root to the app's
Crashlytics coordinates, **one row per flavor** — an app commonly ships several
Firebase projects, and one binding per repo would be wrong:

```
- /Users/x/work/vitallink-ca | na    | vitallink-ca | com.jubohealth.vitallink_ca | ANDROID | someone@work.com
- /Users/x/work/vitallink-ca | jp    | jubolink     | com.jubohealth.jubogo       | ANDROID | someone@work.com
```

Fields: repo root · flavor · firebase project · bundle id · platform · account.

**Arguments override the memory** — `/beleg <project> <bundle> [platform]` runs
against exactly that, binding nothing. **An unbound repo prompts once**, as
`/amon-din` does for CI, then writes the row.

The account matters as much as the project: a work identity and a personal one see
different Firebase projects entirely, and querying as the wrong one returns a
permission error that reads like an empty dataset.

## 2. Collect — BigQuery first

```bash
~/.claude/hooks/beleg-crashes.py --project <p> --bundle <b> --platform <PLAT> --account <a>
```

It prints `{source, window_days, missing_signals, issues[]}` on stdout, ranked.

Three exits, and they mean different things:

| Exit | Meaning | What to do |
|---|---|---|
| 0 | Issues collected and ranked | Go to step 4 |
| 2 | **No Crashlytics export on this project** | Fall back to the console — step 3 |
| 1 | The query failed (permission, missing CLI, bad SQL) | Report the message; do **not** fall back, the fault is not absence |

The distinction on exit 1 matters. A failed query is not the same as a missing
export, and papering one over with a browser scrape would hide a fault the user
needs to see.

The export reaches back **60 days** — its own partition expiry — and back-fills
nothing. If it is off, say so plainly and name the cost: every day it stays off is
crash history this skill will never be able to read.

## 3. Fall back — the Firebase console through Chrome

Only on exit 2. A hook cannot do this: the Chrome tools are MCP and belong to the
model, not to a subprocess. So the scrape is yours to drive.

1. Load the browser tools in **one** `ToolSearch` call, then `tabs_context_mcp`.
2. **Confirm the account before navigating anywhere.** Do not guess the `/u/N`
   index — a work identity and a personal one see disjoint halves of Firebase,
   and the wrong one renders a "project does not exist" page indistinguishable
   from a project with no crashes. Open the account menu, or check an already-open
   tab's URL, and read the index from that. Guessing `/u/1` on a machine whose
   work account sat at `/u/0` cost a full round of confusion.
3. Navigate to the **deep issues URL**, not the project root — the latter does not
   resolve to a list:

   ```
   console.firebase.google.com/u/<N>/project/<project>/crashlytics/app/<platform>:<bundle>/issues?state=open&time=90d&types=crash&tag=all
   ```

   Set `time` deliberately. The console defaults to `7d`, far narrower than the
   export's 60. Set the sort deliberately too — the console's default is
   `sort=eventCount`, which is precisely the ranking this skill exists to reject;
   what it orders by does not matter, since the scorer re-ranks, but never report
   the console's order as if it were a finding.
4. Read the issue list with `get_page_text`. Per issue take: the title (the
   exception line), the subtitle (the symbol), the **blaming `file:line`**, the
   version range, and the events and users counts.

   **The console does show a blaming frame** — `package:…/foo.dart:198` sits
   right under the symbol. Carry it into `blame_frame` and set `in_package`
   accordingly; a scraped run is *not* frame-blind, and step 4 below applies to
   it in full. On the first real run, reading the source at a scraped frame is
   what overturned a diagnosis the stack trace alone had got wrong.
5. Three parsing rules the console's shape imposes:
   - **Versions come as a range** (`2.2.0 – 2.3.0`), not a list. Record the
     endpoints.
   - **A new issue is badged** (`新問題` / "New issue"). Pass that as an explicit
     `trend: "new"` — the badge is Crashlytics' own verdict and beats anything
     derived from dates, especially inside a narrow window where every issue
     looks new.
   - **The stated "latest release" can be lower than a version in the list.**
     When they disagree, say so rather than picking one silently; it usually
     means something is shipping ahead of what the console considers current.
6. Write the payload to the scratchpad and rank it through the same scorer:

```json
{"source": "console (<project> · <platform>)", "window_days": 90, "issues": [ … ]}
```

```bash
~/.claude/hooks/beleg-crashes.py --from-json <file>
```

**Declare the window you actually scraped.** `window_days` is yours to set here;
omit it and the brief says "window not stated" rather than borrowing the
export's 60-day horizon, which would claim a breadth of evidence never gathered.

**Never hand-rank.** Routing the console's issues through `--from-json` is what
keeps one value formula in the repo instead of two that drift.

## 4. Read the code at the blaming frame

For the top three issues carrying a `blame_frame`, open that `file:line` in the
working tree and read the enclosing function. This is the half that makes the
skill more than a dashboard: the suggestion stops being *"add a null check"* and
becomes *"`xs.first` at `lib/foo.dart:88` with no empty guard — the Indexing rule
in `docs/style/general.md` names this exact trap."*

Three cautions, all worth stating when they bite:

- **The tree must match the crashing build.** A frame resolved against a branch
  that has moved on points at the wrong line. Check the version the crash carries
  against what is checked out, and say so when they differ.
- **The top frame is often the victim, not the culprit.** Read outward before
  concluding.
- **A path that does not exist in this tree** means the crash belongs to another
  app or another repo. Report that rather than guessing at a nearby file.

## 5. Render the brief

Render into the Henneth folder (`~/.claude/previews/henneth/`), newest-first, and
print the URL. The brief leads with the source it used and, when
`missing_signals` is non-empty, **names which signals were unavailable** — a
ranking resting on half the inputs must not wear the same face as a full one.

For each of the top issues: the value score, the trend, users affected, the
blaming `file:line`, and the suggested fix.

## Notes

- **Read-only.** No Firebase write, no tracker comment, no branch. The `ticket`
  and `fix` verbs are deliberately unbuilt until the read path has ranked real
  crashes for the app in question.
- **Volume is not value.** One user in a retry loop can out-count a fault hitting
  a thousand people. The weights live in `hooks/beleg-rubric.json`, each with a
  `criterion` line naming what counts as a pass — argue with them there, not in
  the code.
- **Obfuscated frames are noise.** If the release build's mapping or dSYM upload
  is broken, every frame is unreadable and step 4 is worthless. Say so rather
  than inventing a fix from a mangled symbol.
- **Tests ride beside the hook** — `test_beleg_crashes.py`, offline, fixtures in
  both the full and the degraded shape.
