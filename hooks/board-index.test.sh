#!/bin/bash
# Offline tests for the Stability tile's render in board-index.html — the one
# piece of that page carrying a real decision (which number to show, and from
# where). The page has no build step and no DOM harness, so the test lifts
# stabilityTileHtml() out of the file and runs it in node with the module-level
# state it reads supplied as locals. That keeps the assertion against the
# shipped source rather than a copy that can drift.
# Run: bash board-index.test.sh
set -uo pipefail

PAGE="$(cd "$(dirname "$0")" && pwd)/board-index.html"
pass=0
fail=0

check() {
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# One node run answers every case: it extracts the function once, then calls it
# under each state and prints one line per case for the shell to compare.
out=$(node - "$PAGE" <<'JS'
const fs = require("fs");
const page = fs.readFileSync(process.argv[2], "utf8");

const start = page.indexOf("function stabilityTileHtml(");
const end = page.indexOf("async function loadStabilityApps(", start);
if (start === -1 || end === -1) {
  console.log("EXTRACT_FAILED");
  process.exit(0);
}
const src = page.slice(start, end);

const esc = (s) =>
  String(s).replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
// Read from the page rather than restated here: a hardcoded copy drifts from
// the value it stands in for, in a harness whose whole point is to exercise the
// shipped source.
const STABILITY_WARN_BELOW = Number(
  page.match(/const STABILITY_WARN_BELOW = (\d+)/)[1]);
const APPS = [{ label: "app · na · IOS", platform: "IOS" }];
const CHANNELS = [{ channel: "stability", label: "app · na · IOS", crash_free_pct: 70.42 }];

// The state stabilityTileHtml reads. Re-assigned per case, so `let`, and the
// extracted source closes over these exactly as it does over the page's own.
let stabilityApps, stabilitySelected, stabilityResult, stabilityError, stabilityLoading;
// Bound under a different name: the extracted source declares
// `stabilityTileHtml` itself, and a same-named const here would collide.
const renderTile = eval(src + "\nstabilityTileHtml;");

// One case: set the state, render, report which number reached the tile.
function render({ result = null, error = null, channels = [] }) {
  stabilityApps = APPS;
  stabilitySelected = "app · na · IOS";
  stabilityLoading = false;
  stabilityResult = result;
  stabilityError = error;
  const html = renderTile(channels);
  const kpi = html.match(/class="kpi[^"]*">([^<]*)</);
  return { shown: kpi ? kpi[1].trim() : "?", failed: html.includes("fetch failed") };
}

const live = render({ result: { crash_free_pct: 93.1, window_days: 7, note: null }, channels: CHANNELS });
console.log("LIVE " + live.shown);

const nullWithChannel = render({ result: { crash_free_pct: null, window_days: 7, note: "GA4 not configured" }, channels: CHANNELS });
console.log("NULL_CH " + nullWithChannel.shown);

const nullNoChannel = render({ result: { crash_free_pct: null, window_days: 7, note: "GA4 not configured" }, channels: [] });
console.log("NULL_NOCH " + nullNoChannel.shown);

const errWithChannel = render({ error: "Dataset not found", channels: CHANNELS });
console.log("ERR_CH " + errWithChannel.shown);

const errNoChannel = render({ error: "Dataset not found", channels: [] });
console.log("ERR_NOCH " + (errNoChannel.failed ? "failed" : errNoChannel.shown));
JS
)

field() { printf '%s\n' "$out" | awk -v k="$1" '$1 == k { print $2 }'; }

# A live percentage wins outright — the pulled channel must never shadow it.
check "a live percentage is shown as-is" "93.1%" "$(field LIVE)"

# The documented fallback: fetch succeeded but produced no number.
check "a null percentage falls back to the pulled channel" "70.42%" "$(field NULL_CH)"

# Nothing to fall back to — the tile says so rather than inventing a number.
check "a null percentage with no channel shows an em dash" "—" "$(field NULL_NOCH)"

# The case this file was written for: a query that ERRORS, not one that returns
# null. board-server.py answers 400, the page throws, and before the fix the
# error branch returned without ever consulting the pulled channel — so a
# scraped number sat on disk, correct and invisible.
check "an errored fetch still falls back to the pulled channel" "70.42%" "$(field ERR_CH)"

# The error must not be swallowed when there is nothing to show in its place.
check "an errored fetch with no channel still reports the failure" "failed" "$(field ERR_NOCH)"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
