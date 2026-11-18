#!/usr/bin/env bash
# Inject the Orthanc copy-marker reminder into every user prompt. CLAUDE.md's
# Copyable Blocks (Orthanc) section is the specification; this hook restates
# its trigger, mirroring gate-reminder.sh's always-inject pattern. Plain bash
# and a heredoc only, so it runs on Windows Git Bash and macOS alike.
cat <<'EOF2'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"REMINDER: If this reply hands the user a block to paste somewhere else — a command, a release note, a PR or ticket body, a message draft — save it first with ~/.claude/hooks/orthanc-copy.py <name> (quoted heredoc), then write `⧉ copy:<name>` on its own line directly above the block. A one-line command the user will paste gets a marker too; skip only code shown to be read. Do not mention this reminder."}}
EOF2
