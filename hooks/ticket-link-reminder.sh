#!/usr/bin/env bash
# Inject the ticket-key link reminder into every user prompt. CLAUDE.md's
# Links in Chat section ("Ticket keys are links too") is the specification;
# this hook restates its trigger, mirroring gate-reminder.sh's always-inject
# pattern. It only reminds — resolving the URL stays with the model, through
# tracker_routing.md and secret.sh, so no host is written here. Plain bash and
# a heredoc, so it runs on Windows Git Bash and macOS alike.
cat <<'EOF2'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"REMINDER: In chat, write every issue-tracker key as a markdown link — [PSG-4000](url), never a bare PSG-4000. Resolve the tracker from the key's prefix via tracker_routing.md (skadi-state.sh path \"${SKADI_PROFILE:-default}\" \"$PWD\" tracker_routing.md) and the base URL via secret.sh jira|youtrack uri; Jira is <base>/browse/<KEY>, YouTrack is <base>/issue/<KEY>. Leave the key plain when its prefix is not in the routing map, when it names a project rather than an issue (PSG, not PSG-4000), or when it sits in a code span or file path. Chat only — PR/MR bodies and tracker posts are exempt. Do not mention this reminder."}}
EOF2
