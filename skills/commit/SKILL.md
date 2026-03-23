---
name: commit
description: Use when the user asks to commit changes to git. Generates a commit message from the diff and asks for approval before committing.
---

# Git Commit with Generated Message

## Workflow

1. Run `git status` and `git diff HEAD` in parallel to understand all changes
2. Draft a commit message based on the diff
3. Ask for user approval with AskUserQuestion before committing
4. If approved — commit; if rejected — use their preferred message instead

## Commit Message Rules

- Imperative mood: "Add X" not "Added X"
- First line ≤ 72 characters, summarizes the *what*
- Body (if needed) explains the *why*, separated by a blank line
- Stage specific files by name — avoid `git add .` or `git add -A`
- Never skip hooks (`--no-verify`)

## Asking for Approval

Use AskUserQuestion with the generated message as the single option, plus "Other" for custom input:

```
question: "Commit with this message?"
options:
  - label: "<generated message>"
    description: "Use this commit message"
```

## After Approval

```bash
git commit -m "$(cat <<'EOF'
<message here>
EOF
)"
```

Include a `Co-Authored-By: <model name>` trailer unless the user opts out. Use your actual model name (e.g. "Claude Sonnet 4.6") — no email address.
