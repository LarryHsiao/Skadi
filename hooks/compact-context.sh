#!/usr/bin/env bash
# SessionStart(source=compact): remind the resumed model what must survive a
# compaction. Codex command hooks cannot run a prompt handler before compaction.

cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Compaction recovery: re-establish the current task and progress, decisions already made, files being modified and why, verification state, blockers, and pending questions from the retained conversation before continuing. Do not restart completed work."}}
EOF
