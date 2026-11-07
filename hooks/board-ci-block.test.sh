#!/bin/bash
# Offline tests for the CI block's render in board-index.html. The page has no
# build step and no DOM harness, so — as board-index.test.sh does for the
# Stability tile — this lifts ciBlockHtml() and its helpers out of the shipped
# file and runs them in node, so the assertions are against the real source.
# Run: bash board-ci-block.test.sh
set -uo pipefail

PAGE="$(cd "$(dirname "$0")" && pwd)/board-index.html"
pass=0
fail=0

check() {
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

out=$(node - "$PAGE" <<'JS'
const fs = require("fs");
const page = fs.readFileSync(process.argv[2], "utf8");
const start = page.indexOf("function ciAge(");
const end = page.indexOf("function renderCi(", start);
if (start === -1 || end === -1) {
  console.log("EXTRACT_FAILED");
  process.exit(0);
}
const esc = (s) =>
  String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);
const ci = new Function("esc", page.slice(start, end) + "; return { ciBlockHtml };")(esc);

const NOW = Date.parse("2026-11-07T14:00:00Z");
const lamp = (over) => ({
  id: "X", label: "x", status: "success", number: "1", branch: "main",
  finished: "2026-11-07T07:00:00Z", url: "https://tc/b/1", error: null, ...over,
});
const project = (name, worst, lamps) => ({ name, worst, lamps });
const source = (source, label, projects, unreachable = false) =>
  ({ source, label, projects, unreachable });
const channel = (sources) => ({ channel: "ci", fresh_window_hours: 6, sources });
const out = (name, value) => console.log(name + "=" + value);

// 1 · a populated channel: github leads, red lamp is bad, a recent finish wears the ring
const populated = ci.ciBlockHtml(channel([
  source("github", "github actions", [project("jubo", "success", [lamp({ label: "CI" })])]),
  source("teamcity", "teamcity", [project("snotra", "failed", [
    lamp({ label: "ios", status: "failed" }),
    lamp({ label: "web", finished: "2026-11-07T13:20:00Z" }),
  ])]),
]), NOW);
out("github_before_teamcity", populated.indexOf("github actions") < populated.indexOf("teamcity"));
out("failed_lamp_is_bad", /ci-lamp ci-bad[^>]*>(?:(?!ci-lamp)[\s\S])*ios/.test(populated));
out("recent_finish_is_fresh", /ci-fresh(?:(?!ci-lamp)[\s\S])*web/.test(populated));
out("old_finish_is_not_fresh", !/ci-fresh(?:(?!ci-lamp)[\s\S])*>CI</.test(populated));

// 2 · empty: a written channel with no sources says how to bind one; an absent one draws nothing
out("empty_names_the_remedy", ci.ciBlockHtml(channel([]), NOW).includes("No CI bound yet"));
out("absent_channel_draws_nothing", JSON.stringify(ci.ciBlockHtml(undefined, NOW)));

// 3 · a lamp with no runs is unknown and says so, never green
const noRuns = ci.ciBlockHtml(channel([source("teamcity", "teamcity", [project("p", "unknown", [
  lamp({ label: "release", status: "unknown", number: null, finished: null, url: null, error: "no runs" }),
])])]), NOW);
out("no_runs_is_unknown", /ci-unk/.test(noRuns) && noRuns.includes("no runs") && !/ci-ok/.test(noRuns));

// 4 · overflow: a group of eight shows six and folds the rest
const eight = Array.from({ length: 8 }, (_, i) => lamp({ label: "b" + i }));
const crowded = ci.ciBlockHtml(channel([source("teamcity", "teamcity", [project("big", "success", eight)])]), NOW);
out("overflow_folds_the_rest", (crowded.match(/class="ci-lamp /g) || []).length + "+" + /\+2 more/.test(crowded));

// 4b · the fold's tooltip names every build it hides, so no value is lost
out("fold_lists_hidden_builds", /class="ci-more" title="b6, b7"/.test(crowded));

// 4c · a build still running is never ringed, even if a finish time is on record
const running = ci.ciBlockHtml(channel([source("teamcity", "teamcity", [project("p", "running", [
  lamp({ label: "live", status: "running", finished: "2026-11-07T13:50:00Z" }),
])])]), NOW);
out("running_build_is_not_ringed", !/ci-fresh/.test(running));

// 4d · an unreachable source says so in its own header, and its lamps stay hollow
const down = ci.ciBlockHtml(channel([
  source("github", "github actions", [project("a", "success", [lamp({ label: "ok" })])]),
  source("teamcity", "teamcity", [project("b", "unknown", [lamp({ label: "dead", status: "unknown", number: null, error: "hook failed" })])], true),
]), NOW);
const [githubPart, teamcityPart] = down.split('<div class="ci-sec">').slice(1);
out("unreachable_is_named_in_its_own_section", teamcityPart.includes("unreachable") && !githubPart.includes("unreachable"));
out("unreachable_lamp_is_hollow", /ci-lamp ci-unk/.test(teamcityPart));

// 5 · hostile text: labels are escaped and only http(s) addresses become links
const hostile = ci.ciBlockHtml(channel([source("teamcity", "teamcity", [project("p", "success", [
  lamp({ label: "<b>x</b>", url: "javascript:alert(1)" }),
])])]), NOW);
out("label_is_escaped", hostile.includes("&lt;b&gt;") && !hostile.includes("<b>x"));
out("javascript_url_is_not_linked", !hostile.includes("javascript:"));
JS
)

[[ "$out" == "EXTRACT_FAILED" ]] && { echo "  FAIL · could not lift ciBlockHtml out of $PAGE"; exit 1; }

val() { printf '%s\n' "$out" | sed -n "s/^$1=//p"; }

check "a github section precedes a teamcity one" "true" "$(val github_before_teamcity)"
check "a failed build is a bad lamp" "true" "$(val failed_lamp_is_bad)"
check "a build finished inside the window wears the ring" "true" "$(val recent_finish_is_fresh)"
check "a build finished before the window does not" "true" "$(val old_finish_is_not_fresh)"
check "an empty channel names the remedy" "true" "$(val empty_names_the_remedy)"
check "an absent channel draws nothing" '""' "$(val absent_channel_draws_nothing)"
check "a build with no runs is unknown, not green" "true" "$(val no_runs_is_unknown)"
check "a group of eight shows six lamps and folds two" "6+true" "$(val overflow_folds_the_rest)"
check "the fold's tooltip lists the hidden builds" "true" "$(val fold_lists_hidden_builds)"
check "a running build is never ringed" "true" "$(val running_build_is_not_ringed)"
check "an unreachable source is named in its own section only" "true" "$(val unreachable_is_named_in_its_own_section)"
check "an unreachable lamp is hollow" "true" "$(val unreachable_lamp_is_hollow)"
check "a hostile label is escaped" "true" "$(val label_is_escaped)"
check "a javascript: address is not linked" "true" "$(val javascript_url_is_not_linked)"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
