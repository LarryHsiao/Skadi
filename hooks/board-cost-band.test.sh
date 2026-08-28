#!/bin/bash
# Offline tests for the spend band's render in board-index.html. The page has no
# build step and no DOM harness, so this lifts costBandHtml() out of the file and
# runs it in node — the same approach board-index.test.sh takes for the Stability
# tile, and for the same reason: the assertion must hit the shipped source, not a
# copy that can drift from it.
# Run: bash board-cost-band.test.sh
set -uo pipefail

PAGE="$(cd "$(dirname "$0")" && pwd)/board-index.html"
pass=0
fail=0

check() {
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

if ! command -v node >/dev/null 2>&1; then
  echo "  skip · spend band render — node absent, JS not exercised"
  echo ""
  echo "── 0 passed, 0 failed (skipped) ──"
  exit 0
fi

out=$(node - "$PAGE" <<'JS'
const fs = require("fs");
const page = fs.readFileSync(process.argv[2], "utf8");

// The slice starts at trimModel, not at costBandHtml: the render calls it, so
// a slice that began one function later would extract cleanly and then throw
// at call time — which is exactly what it did.
const start = page.indexOf("const trimModel =");
const end = page.indexOf("function renderCost(", start);
if (start === -1 || end === -1) {
  console.log("EXTRACT_FAILED");
  process.exit(0);
}
const src = page.slice(start, end);

// The page's own esc, lifted rather than restated: a harness whose whole claim
// is "this exercises the shipped source" must not quietly supply a different
// escaper than the one the page ships with.
// Bounded by the blank line that ends the statement, not by the first ';':
// esc's own body contains "&amp;", whose semicolon cut the slice mid-literal.
const escAt = page.indexOf("const esc =");
const escSrc = page.slice(escAt, page.indexOf("\n\n", escAt));
const esc = new Function(escSrc + " return esc;")();

const costBandHtml = new Function("esc", src + "; return costBandHtml;")(esc);

const full = {
  channel: "cost", window_days: 90,
  total_usd: 39.8185,
  transcripts_settled: 10, transcripts_in_window: 429,
  sessions_settled: 10,
  by_project: [
    { name: "bilbo", usd: 16.0014 },
    { name: "work-vitallink-ca", usd: 15.0324 },
    { name: "skadi", usd: 3.8131 },
  ],
  by_root: [{ name: "personal", usd: 33.3337 }, { name: "work", usd: 6.4848 }],
  by_model: [{ name: "claude-haiku-4-5-20251001", usd: 0.0626 }],
  per_session_usd: 3.9819, per_changed_line_usd: 0.0341,
  changed_lines: 1166, multi_record_sessions: 0,
  unknown_model_cost: 0, malformed: 0, format_ok: true,
};

// 1 · the coverage denominator rides in the band's own header
const head = costBandHtml(full);
console.log("A:" + (head.includes("10 of 429") ? "yes" : "no"));

// 2 · every project is a row, largest first, money to two places
// The class attribute, not the bare word: the plural container class
// "costrows" contains "costrow" and would be counted as a fourth row.
console.log("B:" + (head.match(/class="costrow"/g) || []).length +
            "/" + (head.includes("$16.00") ? "yes" : "no") +
            "/" + (head.indexOf("bilbo") < head.indexOf("skadi") ? "ordered" : "unordered"));

// 3 · bars are relative to the largest row, not to the total
const widths = [...head.matchAll(/width:(\d+)%/g)].map((m) => Number(m[1]));
console.log("C:" + widths[0] + "/" + (widths[1] < 100 && widths[1] > 80 ? "scaled" : "wrong"));

// 4 · the caveat is spelled out beneath, not left to the header alone
console.log("D:" + (head.includes("not a total for the period") ? "yes" : "no"));

// 5 · a date-suffixed model id is trimmed for the footnote
console.log("E:" + (/(^|[^-])haiku-4-5([^-]|$)/.test(head) && !head.includes("20251001")
                    && !head.includes("claude-haiku") ? "trimmed" : "raw"));

// 5b · the coverage caveat is not dressed as a footnote — it is the line that
// separates a number from a claim, and .muted would file it beside the ratios
console.log("I:" + (/color: var\(--accent\)[^>]*>covers /.test(head) ? "accented" : "muted"));

// 6 · nothing settled says so; it must not render as a $0.00 spend
const empty = costBandHtml({ ...full, total_usd: null, transcripts_settled: 0,
                             sessions_settled: 0, by_project: [], by_root: [], by_model: [] });
console.log("F:" + (empty.includes("$0") ? "shows-zero" : "no-zero") +
            "/" + (/no settled sessions/i.test(empty) ? "explains" : "silent"));

// 7 · a moved format is named on the band, in the red the page uses elsewhere
const bad = costBandHtml({ ...full, format_ok: false, malformed: 3 });
console.log("G:" + (bad.includes("var(--red)") ? "red" : "plain") +
            "/" + (bad.includes("3") ? "counts" : "vague"));

// 8 · an absent channel renders nothing rather than an empty frame
console.log("H:" + (costBandHtml(null) === "" ? "empty" : "something"));

// 9 · the window picker offers every span the writer produced, and reuses the
// page's own .app-pick select rather than inventing a second control
const windowed = {
  ...full,
  windows: {
    "1": { ...full, window_days: 1, total_usd: 15.34, transcripts_settled: 4,
           transcripts_in_window: 13, by_project: [{ name: "Minerva", usd: 15.34 }] },
    "7": { ...full, window_days: 7 },
    "30": { ...full, window_days: 30 },
    "60": { ...full, window_days: 60 },
    "90": { ...full, window_days: 90 },
  },
};
const picked = costBandHtml(windowed);
console.log("J:" + (picked.includes('class="app-pick"') ? "reuses" : "invents") +
            "/" + (picked.match(/<option /g) || []).length);

// 10 · selecting a window redraws from THAT window's numbers, coverage included
const one = costBandHtml(windowed, 1);
console.log("K:" + (one.includes("Minerva") ? "yes" : "no") +
            "/" + (one.includes("4 of 13") ? "coverage" : "stale") +
            "/" + (one.includes("$15.34") ? "amount" : "wrong"));

// 11 · the chosen span stays chosen across a redraw
console.log("L:" + (/<option value="1" selected/.test(one) ? "kept" : "lost"));

// 12 · a channel written before windows existed still renders
console.log("M:" + (costBandHtml(full).includes("$16.00") ? "renders" : "broken") +
            "/" + (costBandHtml(full).includes("app-pick") ? "picker" : "no-picker"));
JS
)

get() { printf '%s\n' "$out" | grep "^$1:" | cut -d: -f2-; }

check "coverage rides in the band header" "yes" "$(get A)"
check "one row per project, largest first, two decimal places" "3/yes/ordered" "$(get B)"
check "bars scale to the largest row" "100/scaled" "$(get C)"
check "the caveat is spelled out beneath the rows" "yes" "$(get D)"
check "a date-suffixed model id is trimmed" "trimmed" "$(get E)"
check "nothing settled explains itself and shows no zero" "no-zero/explains" "$(get F)"
check "a moved format is named in red, with its count" "red/counts" "$(get G)"
check "an absent channel renders nothing" "empty" "$(get H)"
check "the coverage caveat is accented, not a muted footnote" "accented" "$(get I)"
check "the picker reuses .app-pick and offers every window" "reuses/5" "$(get J)"
check "picking a window redraws from that window's numbers" "yes/coverage/amount" "$(get K)"
check "the chosen span stays selected across a redraw" "kept" "$(get L)"
check "a channel with no windows key still renders, without a picker" "renders/no-picker" "$(get M)"

# ── 13 · the picker is wired, not merely drawn ──
# costBandHtml's own tests prove the redraw picks the right span; none of them
# can prove anything calls it. That is the exact gap board-cost.py fell into —
# tested, installed, and never invoked — so the listener gets its own check.
#
# What these four assertions do and do not cover. They read the source, so they
# prove the listener is bound, reads the picker, stores the choice and redraws.
# The event path itself was exercised for real against a running board — a
# `change` dispatched on the live select redrew the band to that window's
# numbers and kept the choice across the poll's next render.
#
# What remains unverified anywhere: a physical mouse click opening the native
# dropdown and picking a row. A select's popup is an OS-level widget that
# synthetic mouse and key events do not reach, so no automation available here
# can drive it. Dispatching the event is not the same claim as clicking, and
# this file will not pretend otherwise.
wiring=$(awk '/getElementById\("cost"\).addEventListener/{f=1} f{print} f&&/^      \}\);/{exit}' "$PAGE")
check "a change listener is delegated on the band container" "yes" \
  "$(printf '%s' "$wiring" | grep -q 'addEventListener("change"' && echo yes || echo no)"
check "it acts only on the window picker" "yes" \
  "$(printf '%s' "$wiring" | grep -q 'costWindowPick' && echo yes || echo no)"
check "it stores the pick, then redraws" "yes" \
  "$(printf '%s' "$wiring" | grep -q 'currentCostWindow = e.target.value' \
     && printf '%s' "$wiring" | grep -q 'render()' && echo yes || echo no)"
check "renderCost passes the stored span back in" "yes" \
  "$(grep -q 'costBandHtml(cost, currentCostWindow)' "$PAGE" && echo yes || echo no)"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
