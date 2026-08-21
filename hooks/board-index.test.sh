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

// From the door helper through the tile render — both are needed, and the
// slice keeps them together so neither can be tested against a stale copy.
const start = page.indexOf("function consoleDoor(");
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
const APPS = [{
  label: "app · na · IOS",
  platform: "IOS",
  project: "vitallink-ca",
  bundle: "com.jubohealth.vitallink-ca",
}];
const CHANNELS = [{ channel: "stability", label: "app · na · IOS", crash_free_pct: 70.42 }];

// The state stabilityTileHtml reads. Re-assigned per case, so `let`, and the
// extracted source closes over these exactly as it does over the page's own.
let stabilityApps, stabilitySelected, stabilityResult, stabilityError, stabilityLoading;
// Bound under a different name: the extracted source declares
// `stabilityTileHtml` itself, and a same-named const here would collide.
const renderTile = eval(src + "\nstabilityTileHtml;");

// One case: set the state, render, report which number reached the tile and
// the console door's href, if one was drawn.
function render({ result = null, error = null, channels = [], selected = "app · na · IOS", apps = APPS }) {
  stabilityApps = apps;
  stabilitySelected = selected;
  stabilityLoading = false;
  stabilityResult = result;
  stabilityError = error;
  const html = renderTile(channels);
  const kpi = html.match(/class="kpi[^"]*">([^<]*)</);
  const enter = html.match(/<a class="enter" href="([^"]*)"([^>]*)>/);
  return {
    shown: kpi ? kpi[1].trim() : "?",
    failed: html.includes("fetch failed"),
    door: enter ? enter[1] : "",
    doorAttrs: enter ? enter[2] : "",
  };
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

// The console door. It hangs off the picked app alone, so it must stand even
// when the number could not be had — that is when it is most wanted.
console.log("DOOR " + live.door);
console.log("DOOR_ERR " + errNoChannel.door);
console.log("DOOR_NOPICK " + (render({ selected: null }).door || "none"));
// Same shape as the growth and pulse tiles' doors, which sit on a KPI row too.
console.log("DOOR_ATTRS " + live.doorAttrs.trim().replace(/\s+/g, " "));

// A hand-written stability-apps.json entry can carry a label and nothing else —
// board-stability.py's merge_apps admits it and replaces the discovered record.
// The tile must still render; an unguarded read here throws inside renderStrip's
// template and blanks the whole top strip.
let bare = { thrown: null, out: null };
try {
  bare.out = render({
    result: { crash_free_pct: 93.1, window_days: 7, note: null },
    apps: [{ label: "app · na · IOS" }],
  });
} catch (e) {
  bare.thrown = String((e && e.message) || e);
}
console.log("BARE " + (bare.thrown ? "THREW:" + bare.thrown : bare.out.shown + "|" + (bare.out.door || "none")));
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

# The console door. No /u/<N> segment: Google routes to the signed-in account
# and rewrites the path itself, so naming an index would bake this machine's
# account order into a file that installs to every root.
expected_door="https://console.firebase.google.com/project/vitallink-ca/crashlytics/app/ios:com.jubohealth.vitallink-ca"
check "the door deep-links the picked app, with no account index" "$expected_door" "$(field DOOR)"

# It hangs off the picked app, not off the number — most wanted when the fetch
# failed outright.
check "the door stands even when the fetch errored" "$expected_door" "$(field DOOR_ERR)"

# Nothing picked, nothing to open — no anchor rather than a dead one.
check "no app picked draws no door at all" "none" "$(field DOOR_NOPICK)"

# Same attributes as the growth and pulse doors, which also sit on a KPI row —
# board-index.html:602 and :622. A door that reads differently from its siblings
# is a divergence whether or not it works.
expected_attrs='target="_blank" rel="noopener" style="font-size:0.7rem"'
actual_attrs=$(printf '%s\n' "$out" | sed -n 's/^DOOR_ATTRS //p')
check "the door wears the same attributes as its sibling doors" "$expected_attrs" "$actual_attrs"

# A roster entry bearing only a label — legal per merge_apps — must cost the
# door, never the tile. The number still renders; only the link is withheld.
check "a roster entry with no platform renders the tile and withholds the door" "93.1%|none" "$(field BARE)"

# The Attention band's render — attentionBandHtml() is pure (string in,
# string out), so this slice needs no DOM harness at all, unlike the Stability
# tile above. Sliced by its own findable neighbours: the function starts right
# after renderSweeps's closing brace and ends at renderAttention's own close.
attn_out=$(node - "$PAGE" <<'JS'
const fs = require("fs");
const page = fs.readFileSync(process.argv[2], "utf8");

const start = page.indexOf("function attentionBandHtml(");
const end = page.indexOf("function renderBody(", start);
if (start === -1 || end === -1) {
  console.log("EXTRACT_FAILED");
  process.exit(0);
}
const src = page.slice(start, end);

const esc = (s) =>
  String(s ?? "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);
const fn = eval(src + "\nattentionBandHtml;");

const mkItem = (over) => ({
  surface: "mrs", label: "GitLab MRs", count: 3, detail: "2 to review · 1 mine",
  verdict: "stirred", url: "https://gitlab.example.com/dashboard/merge_requests",
  ...over,
});

// Fixed order regardless of input array order.
const outOfOrder = [
  mkItem({ surface: "jira", label: "Jira movement" }),
  mkItem({ surface: "mrs", label: "GitLab MRs" }),
  mkItem({ surface: "prs", label: "GitHub PRs" }),
];
const orderHtml = fn(outOfOrder);
const orderSeen = [...orderHtml.matchAll(/class="nm">([^<]*)</g)].map((m) => m[1]);
console.log("ORDER " + orderSeen.join(","));

// count null renders an em dash, not "0".
const nullCount = fn([mkItem({ count: null, verdict: "unknown" })]);
console.log("NULLCOUNT " + (nullCount.match(/class="pill[^"]*">([^<]*)</) || [, "?"])[1]);

// count 0 renders "0".
const zeroCount = fn([mkItem({ count: 0, verdict: "quiet" })]);
console.log("ZEROCOUNT " + (zeroCount.match(/class="pill[^"]*">([^<]*)</) || [, "?"])[1]);

// stirred takes the active pill class.
console.log("STIRREDCLS " + (fn([mkItem({ verdict: "stirred" })]).match(/class="pill ([^"]*)"/) || [, "?"])[1]);

// Three items -> exactly three rows; a channel simply absent from the input
// (mail never wired) draws no ghost row.
const three = fn([mkItem({ surface: "mrs" }), mkItem({ surface: "prs" }), mkItem({ surface: "jira" })]);
console.log("THREEROWS " + (three.match(/class="srow"/g) || []).length);
console.log("NOGHOST " + (three.includes("ghost") ? "ghost" : "clean"));

// Empty array -> "" so the band and its divider vanish entirely.
console.log("EMPTY " + JSON.stringify(fn([])));

// No url -> no Enter link.
console.log("NOURL " + (fn([mkItem({ url: null })]).includes("Enter") ? "has-link" : "no-link"));

// An unknown surface sorts last but still renders.
const withUnknown = fn([mkItem({ surface: "zzz", label: "Unknown surface" }), mkItem({ surface: "mrs", label: "GitLab MRs" })]);
const unknownSeen = [...withUnknown.matchAll(/class="nm">([^<]*)</g)].map((m) => m[1]);
console.log("UNKNOWNSURF " + unknownSeen.join(","));
JS
)

afield() { printf '%s\n' "$attn_out" | awk -v k="$1" '{ if ($1 == k) { $1=""; sub(/^ /,""); print; exit } }'; }

check "fixed row order regardless of input array order" "GitLab MRs,GitHub PRs,Jira movement" "$(afield ORDER)"
check "count null renders an em dash, not 0" "—" "$(afield NULLCOUNT)"
check "count 0 renders 0" "0" "$(afield ZEROCOUNT)"
check "a stirred verdict takes the active pill class" "active" "$(afield STIRREDCLS)"
check "three items produce exactly three rows" "3" "$(afield THREEROWS)"
check "an absent channel draws no ghost row" "clean" "$(afield NOGHOST)"
check "an empty array returns empty string (band + divider vanish)" '""' "$(afield EMPTY)"
check "no url means no Enter link" "no-link" "$(afield NOURL)"
check "an unknown surface sorts last but still renders" "GitLab MRs,Unknown surface" "$(afield UNKNOWNSURF)"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
