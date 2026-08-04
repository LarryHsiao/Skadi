# Beleg — crash analysis ranked by value

Beleg Cúthalion tracked a trail across a continent to its end. This skill follows a
crash from its stack frame home to the line of code that caused it.

`/beleg` reads an app's Crashlytics issues, ranks them by **impact rather than
volume**, and suggests a fix for the top few — reading the actual source at the
blaming frame where it can. Read-only; the write verbs (file a ticket, draft a fix)
come after the read path is proven against real data.

## Why not just sort by crash count

One user stuck in a retry loop out-counts a fault hitting a thousand people. The
score weighs four signals instead, held in `hooks/beleg-rubric.json` so they are
tunable without editing code — the pattern `hooks/pulse-rubric.json` already sets:

```
value = users_affected^0.7      # blast radius, flattened so a loop cannot dominate
      × trend_weight            # new 2.0 · regressed 1.6 · steady 1.0 · fading 0.6
      × version_concentration   # 1.5 when confined to the newest build
      × actionability           # 1.0 in-package · 0.3 third-party SDK · 0.1 OS-level
```

The fourth is the one no console offers, and the reason this is a skill and not a
chart: a crash you have no power to reach does not deserve the top slot, however
loud it is.

## Two collectors, one ranking

A hook cannot drive a browser — hooks are shell and Python, the Chrome tools are
MCP and belong to the model. So the sources split, and the ranking must not:

- **BigQuery export** (preferred) — `firebase_crashlytics.<bundle>_<PLATFORM>`.
  Structured, cheap, carries `blame_frame`. Requires the export switched on in the
  Firebase console; it back-fills nothing and the tables expire at 60 days.
- **Firebase console via Chrome** (fallback) — the skill's own instructions
  navigate and scrape when the hook reports no export. Thinner evidence: no
  `blame_frame`, so no code reading and no actionability weight.

`beleg-crashes.py` owns the ranking and the render, and takes `--from-json` so it
can rank issues it did not collect. One scorer, one renderer, two collectors —
otherwise the value formula gets written twice and drifts apart.

**Degradation is stated, never silent.** The rendered brief names which source it
used and which signals were unavailable. A score computed from half the inputs must
not wear the same face as the full one.

## Known state at authoring (2026-08-04)

Neither path can be proved end-to-end yet, and the plan says so rather than
discovering it late:

- The Crashlytics BigQuery export is **absent** on `vitallink-ca`,
  `vitallink-ca-staging`, and `jubolink` — confirmed under an account that can
  create query jobs in all three, so this is absence and not a permission mask.
- The Chrome extension is **not connected**, so the fallback cannot be exercised
  either.
- `vitallink2-tw` *does* carry an export, but it belongs to a legacy TW app whose
  last write was 2026-06-21. Its silence is expected, not a symptom.

Everything below is provable against fixtures. Live proof waits on one of those two
doors opening.

## Steps

- [x] Write this concept and register it with the Mirror
- [x] Add `hooks/beleg-rubric.json` — the four weights, with a `criterion` line per signal
- [x] Write the pure ranking function over the rubric, blind to its issues' origin
- [x] Test the ranking with fixtures in both shapes — full (BigQuery) and degraded (console)
- [x] Add the BigQuery collector: query, 60-day horizon, per-issue user counts
- [x] Give the collector a distinct "no export" exit, separate from "no crashes"
- [x] Render the ranked brief into Henneth, naming source and missing signals
- [x] Resolve `blame_frame` to a real `file:line` and read the function there
      (skill prose, not hook code — the model does the reading; unproven until a
      run against a tree matching the crashing build)
- [x] Write `skills/beleg/SKILL.md` — binding, verb routing, browser-fallback instructions
- [x] Bind per repo via `crash_routing.md`: project · bundle · platform · account · flavor
- [x] Prompt once on an unbound repo, as `/amon-din` does for CI
- [x] Add the README rows for the skill and its hooks

## Deferred, deliberately

- **Write verbs** — `ticket` (file the top N) and `fix` (dispatch a smith on a
  branch), each confirm-once. They wait until the read path has ranked real
  crashes; ranking nothing is not worth acting on.
- **`PlatformDispatcher.instance.onError`** is unset in `vitallink-ca`, so errors
  outside the guarded zone go unrecorded. Not this skill's business, but it thins
  the data this skill will read.
