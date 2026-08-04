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
2. Navigate to `console.firebase.google.com/project/<project>/crashlytics`.
3. If it shows a sign-in page or an empty project chooser, **stop and tell the
   user which account Chrome is signed in as.** The wrong identity renders an
   empty console that looks exactly like an app with no crashes.
4. Read the issue list with `get_page_text` or `read_page`. Take the issue title,
   subtitle, event count, and users-affected column.
5. Write them to a temp file in the scratchpad as
   `{"source": "console", "issues": [...]}` using the issue shape documented at
   the top of `beleg-crashes.py`, then rank them through the same scorer:

```bash
~/.claude/hooks/beleg-crashes.py --from-json <file>
```

**Never hand-rank.** Routing the console's issues through `--from-json` is what
keeps one value formula in the repo instead of two that drift.

The console cannot give you a blaming frame, so `missing_signals` will name
`actionability` — and step 5 is skipped for those issues. Say this in the brief.

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
