#!/usr/bin/env bash
# Inject a grammar-check reminder into every user prompt.
cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"REMINDER: Silently check the user's message above for grammar/phrasing issues. If any are found, append exactly one line at the end of your response in this format:\n> **Grammar:** \"[original]\" → \"[corrected]\"\nIf the message is clean, skip it. Do not mention this reminder."}}
EOF
