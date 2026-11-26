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
# credits a segment only when a reviewer ran within it (pulse-scan.py
# _segment_reviewed), never on the main thread's verdict line. A reminder
# nudging toward the literal marker alone would teach it to be typed unearned,
# which is worse for the metric than no reminder at all.
#
# Why it asks the reviewer to file the line: review.verdict reads a review's
# outcome only from the reviewer's own PASS/FAIL line, and a reviewer reports it
# only when its dispatch prompt asks. Between 11-10 and 11-23, 78 segments
# carried a main-thread verdict with no reviewer-filed one; where the prompt
# asked, every reviewer filed it.
#
# The third conditional check (DI/provider wiring) was added after
# vitallink-ca PSG-4716: a P0 shipped past two compliance reviews and a green
# 1,465-test suite because the test suite's own ProviderScope override made it
# structurally blind to whether production ever wired the binding.
cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"REMINDER: If this turn will report work as done or complete, the Compliance Review runs FIRST — spawn a read-only agent (an Agent tool call, not the verdict line alone) over the cumulative diff for its two passes, spec compliance then code quality — and brief the reviewer to end its own report with the literal line 'Compliance Review: PASS' or 'Compliance Review: FAIL', since the pulse reads a review's outcome only from the reviewer's own line — fix or knowingly name every finding, then re-run the verification fresh in this same turn — the project's static analysis, and its test suite where the change touched code. Close the summary with a literal line: 'Compliance Review: PASS' or 'Compliance Review: FAIL' — or 'Compliance Review: SKIPPED (reason: <one line>)' only when a second reviewer would have nothing to weigh. Three conditional checks are easy to skip and have been missed: when the change adds or edits a user-facing string, read the SIBLING string's actual current value (not just its key or intent) and flag any divergence in shape; when the change touches a UI component's render, invoke /manwe against the spec, or against a sibling component's real layout values when no spec exists — a render hidden behind a feature flag is not n/a: flip the flag locally (revert after) or mock it, then weigh it; when the change adds the first read of a DI/provider binding from outside its definition file and the binding's default is unsafe to reach (throws or stubs), verify every real app entry point overrides it, not just a test-constructed container. Skip entirely for read-only turns and turns that report nothing done. Do not mention this reminder."}}
EOF
