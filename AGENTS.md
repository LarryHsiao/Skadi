# Skadi Agent Configuration

Skadi is the source repository for a personal agent configuration that supports
both Claude Code and Codex. Never edit installed copies under `~/.claude*` or
`~/.codex*`; edit this repository and run the `install` skill.

## Working agreement

- Read before writing. Follow the repository's existing conventions and keep
  changes narrowly scoped to the request.
- For mutating free-form work, state the size, observable acceptance outcomes,
  non-goals, and intended files before the first mutation, then wait for the
  user's approval. Explicitly invoked skills follow their own confirmation
  rules instead.
- Build in vertical, independently verifiable slices. After each slice, run its
  relevant check. Before reporting completion, review the cumulative diff for
  specification compliance and code quality, fix findings, and run fresh tests.
- Never hide skipped checks, partial failures, or unresolved uncertainty.
- Do not overwrite or clean unrelated user changes in a dirty worktree.
- Keep two writable agents away from the same files. Read-only investigations
  may run concurrently.

## Runtime-neutral conventions

- Claude invokes a skill as `/name`; Codex invokes it as `$name`. Treat either
  spelling in documentation as the same Skadi workflow.
- Claude's interactive question tool and Codex's structured user-input tool are
  equivalent. If neither is available, ask one concise question in chat.
- Claude's Agent tool and Codex subagents are equivalent. Choose a current
  model by capability (mechanical, default worker, or strongest judgment), not
  by copying a vendor-specific model slug from old documentation.
- Prefer authenticated connectors or MCP tools for private workspace data. If a
  required connector is unavailable, stop with setup instructions rather than
  silently substituting public web search.
- Skadi workflow state lives under `~/.skadi/profiles/<profile>/projects/`, so
  paired Claude and Codex profiles share routing without sharing chat history.

## Safety

- Keep work inside the active repository, configured development roots, agent
  config roots, `~/.skadi`, and temporary directories. Respect the directory,
  protected-repository, and cross-worktree hooks.
- Ask before destructive actions, commits, pushes, tracker/forge writes, or
  broader access. An invoked skill is authority only where its own instructions
  explicitly say so.
- Resolve secrets through the installed `hooks/secret.sh`; never print or read a
  raw credential environment variable in model-visible output.
- Assign new PRs, MRs, and tracker tickets to the user unless they request a
  different assignee or the destination is explicitly an unassigned queue.

## Repository maintenance

- Shell automation belongs in `hooks/`, with tests beside it when practical.
- Skills live in `skills/<name>/SKILL.md`; Codex installation renders compatible
  copies rather than maintaining a second skill tree.
- Read `docs/workflow/maintenance.md` before changing global rules, skills,
  settings, or hooks. Read the language/tool/workflow guide relevant to the
  task before changing that area.
- Run `./hooks/lint.sh` over changed shell scripts and run the focused `*.test.sh`
  or Python tests for every changed component.

## Communication

- Lead with the outcome. Keep updates concise and name blockers plainly.
- Use clickable local file paths where the client supports them.
- Silently check the user's grammar. If correction is useful, append exactly
  one `> **Grammar:** "original" → "corrected"` line with only changed tokens
  bolded; omit it when the message is already clear.
