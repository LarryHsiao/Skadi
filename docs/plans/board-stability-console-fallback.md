# Board Stability tile — Firebase console fallback

The live Stability tile (shipped 2026-08-05) reads crash-free users % from a
BigQuery join: Crashlytics (crashed users) against GA4 (active users). Neither
export exists yet on any bound app, so the tile's only path today is "GA4 not
configured" or a query failure — never a number.

The Firebase Crashlytics console shows a "Crash-free users %" headline
directly on its dashboard, no GA4 join required — the same number Google
computes internally from session data BigQuery's export doesn't carry. `/beleg`
already has a proven scrape flow for this console (`skills/beleg/SKILL.md`
§3), narrated by the model through the Chrome MCP tools when the BigQuery path
reports absence (exit code 2, `NoExport`).

## Why this can't be the live dropdown's fallback

The live tile's fetch is a synchronous chain with no model turn in it:
browser `fetch()` → `board-server.py` → a `board-stability.py` subprocess →
the `bq` CLI. Hooks cannot drive Chrome — only the model can, via the MCP
tools — so there is no point in that chain to insert a scrape. Fixing this
means changing what kind of tile Stability is, not patching the fetch.

## The shape that fits

Every other board tile is a **pulled channel**: a JSON file under
`~/.skadi/board/`, written by a model-driven step (`/board add`, `/board
refresh`), auto-shown by the page's poll within ~8s of the file changing. The
console-scrape number belongs there, not behind a live per-click endpoint —
the same "pull, not push" discipline `growth.json` already uses for metis.

Sketch:

- `/board refresh` gains a stability step, **opt-in via a flag** —
  `/board refresh --stability-scrape`. Plain `/board refresh` never scrapes;
  the flag is the explicit ask. **Decided 2026-08-05** — a console scrape is
  a heavier, model-driven action and must not fire silently on every refresh
  for every app.
- Under the flag: for each app in `board-stability.py list-apps`, try the
  BigQuery path first (`board-stability.py fetch <label>`); on a "GA4 not
  configured" or query-failure result, the model falls back to `/beleg`'s
  console-scrape flow, reading the dashboard's own crash-free % headline
  instead of ranking issues, and writes `stability-<label>.json`.
- The live dropdown keeps its current BigQuery-only fetch as the fast path
  when a GA4 pairing exists; when it doesn't, the tile reads the pulled
  channel instead of showing "not configured" forever.
- Staleness display — **decided 2026-08-05**: no special labeling. The tile
  shows whichever number it has (live BigQuery or last-scraped console)
  without marking its source or age.

## Steps
- [x] Write this concept and register it with the Mirror
- [x] Decide whether the scrape fires automatically — no, gated behind
      `--stability-scrape` (decided 2026-08-05)
- [x] Decide the staleness-display question — no special labeling, show
      whichever number is available (decided 2026-08-05)
- [x] Add a `--stability-scrape`-gated step to `board.sh refresh`, writing
      `stability-<label>.json` via the console-scrape flow when BigQuery
      reports no GA4 pairing
- [x] Teach the Stability tile to read a pulled `stability-<label>.json` as a
      fallback when the live fetch reports "GA4 not configured" — shown
      plainly, no source/age label per the staleness decision above
- [x] Extend `board-stability.py`'s CLI so the console-scrape writer has a
      `--from-json` path to feed it a scraped number, mirroring
      `beleg-crashes.py`'s own `--from-json` seam
- [x] Tests: fixture coverage for the new write path; the scrape itself stays
      unverifiable offline, same caveat `beleg-crash-analysis.md` already
      carries

## Deferred, deliberately
- **Auto-refresh cadence** for the scraped channel — a scheduled `/board
  refresh` via `/loop` or cron, once the manual path is proven.
- **Multi-app batch scraping** in one Chrome session — start with one app at
  a time, matching `/beleg`'s own single-app scope.
