#!/bin/bash
# Offline tests for the Compliance Review reminder hook. The contract: the hook
# emits valid UserPromptSubmit JSON whose reminder carries the exact verdict
# tokens the pulse scorer matches, names the agent dispatch the rubric demands
# behind them, and nudges the three conditional checks a real session missed.
# Run: bash compliance-review-reminder.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/compliance-review-reminder.sh"
pass=0
fail=0

# The patterns pulse-rubric.json's rule.compliance-review matches. Held here
# rather than read from the rubric, the same decoupling gate-reminder.test.sh
# took — a suite that reads a live key goes red when the key moves, telling you
# nothing about the hook. Should the rubric's regexes change, these must follow.
VERDICT_RE='Compliance Review[:：]\s*(PASS|FAIL)'
SKIPPED_RE='Compliance Review[:：]\s*SKIPPED'

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# ── 1 · the hook emits valid JSON shaped for UserPromptSubmit ──
expected_shape="UserPromptSubmit/yes"
actual_shape=$(bash "$HOOK" | python3 -c "
import json, sys
out = json.load(sys.stdin)['hookSpecificOutput']
print('%s/%s' % (out['hookEventName'], 'yes' if out.get('additionalContext') else 'no'))
")
check "hook emits valid UserPromptSubmit JSON with context" "$expected_shape" "$actual_shape"

# Hook output lands in a temp file, not a pipe — `python3 -` reads its script
# from stdin, so piping the JSON there too would starve one of them.
hook_out="$(mktemp)"
bash "$HOOK" > "$hook_out"

# ── 2 · the reminder carries the verdict tokens the scorer matches ──
expected_tokens="verdict:yes skipped:yes"
actual_tokens=$(VERDICT_RE="$VERDICT_RE" SKIPPED_RE="$SKIPPED_RE" python3 - "$hook_out" <<'PY'
import json, os, re, sys
ctx = json.load(open(sys.argv[1], encoding="utf-8"))["hookSpecificOutput"]["additionalContext"]
verdict = bool(re.search(os.environ["VERDICT_RE"], ctx))
skipped = bool(re.search(os.environ["SKIPPED_RE"], ctx))
print("verdict:%s skipped:%s" % ("yes" if verdict else "no", "yes" if skipped else "no"))
PY
)
check "reminder carries the scorer's PASS/FAIL and SKIPPED tokens" "$expected_tokens" "$actual_tokens"

# ── 3 · the reminder demands the agent, not merely the marker ──
# The rubric only credits a segment when a reviewer ran within it, never on
# the verdict line alone. A reminder nudging toward the literal line alone would
# teach the marker to be typed unearned, making the metric worse than no
# reminder at all.
expected_agent="yes"
actual_agent=$(python3 - "$hook_out" <<'PY'
import json, sys
ctx = json.load(open(sys.argv[1], encoding="utf-8"))["hookSpecificOutput"]["additionalContext"]
print("yes" if "agent" in ctx.lower() else "no")
PY
)
check "reminder names the agent dispatch behind the verdict" "$expected_agent" "$actual_agent"

# ── 3b · the reviewer files the verdict itself ──
# review.verdict reads a review's outcome only from the reviewer's own PASS/FAIL
# line. A dispatch prompt that does not ask for it leaves the reviewer reporting
# findings with no marker, and the outcome goes unread — 78 such segments stood
# between 11-10 and 11-23. When the prompt asked, the reviewer filed it every time.
expected_filed="yes"
actual_filed=$(python3 - "$hook_out" <<'PY'
import json, sys
ctx = json.load(open(sys.argv[1], encoding="utf-8"))["hookSpecificOutput"]["additionalContext"].lower()
print("yes" if "reviewer" in ctx and "its own report" in ctx else "no")
PY
)
check "reminder asks the reviewer to end its own report with the verdict" "$expected_filed" "$actual_filed"

# ── 4 · the two earlier conditional checks the observed miss involved ──
expected_checks="sibling:yes manwe:yes"
actual_checks=$(python3 - "$hook_out" <<'PY'
import json, sys
ctx = json.load(open(sys.argv[1], encoding="utf-8"))["hookSpecificOutput"]["additionalContext"].lower()
print("sibling:%s manwe:%s" % ("yes" if "sibling" in ctx else "no",
                               "yes" if "manwe" in ctx else "no"))
PY
)
check "reminder nudges the sibling-string check and the /manwe render weigh" "$expected_checks" "$actual_checks"

# ── 4b · a flag-hidden render still owes /manwe (PSG-5462) ──
# A render behind a feature flag or constant was declared n/a with no render to
# weigh; flipping the flag locally caught two deltas the unit tests could not.
expected_flag="yes"
actual_flag=$(python3 - "$hook_out" <<'PY'
import json, sys
ctx = json.load(open(sys.argv[1], encoding="utf-8"))["hookSpecificOutput"]["additionalContext"].lower()
print("yes" if "flag" in ctx and "not n/a" in ctx else "no")
PY
)
check "reminder says a flag-hidden render is not n/a" "$expected_flag" "$actual_flag"

# ── 5 · the third conditional check: DI/provider wiring (PSG-4716) ──
expected_wiring="yes"
actual_wiring=$(python3 - "$hook_out" <<'PY'
import json, sys
ctx = json.load(open(sys.argv[1], encoding="utf-8"))["hookSpecificOutput"]["additionalContext"].lower()
print("yes" if "provider" in ctx and "entry point" in ctx else "no")
PY
)
check "reminder nudges the DI/provider entry-point wiring check" "$expected_wiring" "$actual_wiring"

# ── 6 · it tells the model not to mention the reminder ──
# Every sibling reminder carries this; without it the nudge leaks into the
# user-facing reply as process chatter.
expected_quiet="yes"
actual_quiet=$(python3 - "$hook_out" <<'PY'
import json, sys
ctx = json.load(open(sys.argv[1], encoding="utf-8"))["hookSpecificOutput"]["additionalContext"]
print("yes" if "not mention this reminder" in ctx else "no")
PY
)
check "reminder tells the model not to mention it" "$expected_quiet" "$actual_quiet"

rm -f "$hook_out"

echo
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
