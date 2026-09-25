#!/usr/bin/env bash
# Inject the context-cleanup reminder into every user prompt — a judgment
# nudge, not a detector: nothing here parses topic drift, the model does.
# CLAUDE.md's Context Cleanup section is the specification; this hook
# restates its trigger, mirroring gate-reminder.sh and
# compliance-review-reminder.sh's always-inject pattern.
cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"REMINDER: If this message opens a topic unrelated to the session's prior work, and that prior work reads as concluded (no open step, no pending verification or decision), ask plainly whether to /clear before continuing — never run it unprompted. Skip when the new message continues, refines, or follows up on the same thread, when the session is mid-task, or when the user already opted out this session. Do not mention this reminder."}}
EOF
