#!/usr/bin/env bash
# Inject the Compliance Review reminder into every user prompt — the closing-gate
# nudge, mirroring gate-reminder.sh's opening one. CLAUDE.md's Compliance Review
# section is the specification; this hook restates its trigger.
#
# Why every turn rather than only on "done"-shaped turns: a hook can detect
# "about to mutate" from the tool call, but not "about to claim done" from the
# prose. The Free-Form Gate's always-inject pattern is the precedent that has
# held reliably, so this follows it and pays the extra context.
#
# Why it names the Agent dispatch: pulse-rubric.json's rule.compliance-review
# only credits a segment when an Agent call stands behind the verdict line. A
# reminder nudging toward the literal marker alone would teach it to be typed
# unearned, which is worse for the metric than no reminder at all.
cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"REMINDER: If this turn will report work as done or complete, the Compliance Review runs FIRST — spawn a read-only agent (an Agent tool call, not the verdict line alone) over the cumulative diff for its two passes, spec compliance then code quality, fix or knowingly name every finding, then re-run the verification fresh in this same turn — the project's static analysis, and its test suite where the change touched code. Close the summary with a literal line: 'Compliance Review: PASS' or 'Compliance Review: FAIL' — or 'Compliance Review: SKIPPED (reason: <one line>)' only when a second reviewer would have nothing to weigh. Two conditional checks are easy to skip and have been missed: when the change adds or edits a user-facing string, read the SIBLING string's actual current value (not just its key or intent) and flag any divergence in shape; when the change touches a UI component's render, invoke /manwe against the spec, or against a sibling component's real layout values when no spec exists. Skip entirely for read-only turns and turns that report nothing done. Do not mention this reminder."}}
EOF
