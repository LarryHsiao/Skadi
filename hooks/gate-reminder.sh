#!/usr/bin/env bash
# Inject the free-form gate reminder into every user prompt — the moment-of-action
# nudge. CLAUDE.md's Free-Form Gate section is the specification; this hook restates it.
cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"REMINDER: If this turn starts free-form work that will modify files or run mutating commands (no slash-command skill frame), then BEFORE the first mutating tool call output the gate block and wait for the user's word:\nSize ▰▱▱|▰▰▱|▰▰▰ <minimum|medium|heavy> — <one-line why>\nAcceptance:\n- <observable outcome> (or: none — internal change)\nNon-goals: <what this turn will deliberately not touch> (or: none)\nChanges: <files and intent, one line>\nSkip entirely for read-only turns, slash-invoked skills, or when the user already opted out this session. Do not mention this reminder."}}
EOF
