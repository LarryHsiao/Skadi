# The Session's Task Surface

> Read when a skill wants to leave a standing item the user can see after the
> chat has scrolled away — `/preflight`'s overdue checks, `/daily`'s tickets,
> `/working`'s in-progress ticket. This file states the convention once; each
> skill keeps only its own field mapping and identity key.

## The rule

**Name the outcome, not the tool.** A step here owes a standing item, not a
particular call. Where it lives depends on what the session was given.

- **A task-tracking tool stands in the session's tool roster** — mirror the
  items into it. That is the cheapest surface, since it is already on screen.
- **None does** — fall back on the render the skill already produces, and where
  it produces none, skip the step silently. Never add a second rendering of
  what the skill just printed.

**Never write a specific tool name as a step to perform.** The task-tracking
tools are offered only on some models, so a step written to call one silently
falls through everywhere else — which is precisely the failure this convention
was written to end.

## Why the tool is conditional

Claude Code restricted the task-tracking tools by model. Two entries in the
[official changelog](https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md)
carry it, quoted here verbatim so a reader can check them at the source:

> **2.1.233** — Todo/task-tracking tools (TaskCreate/Get/Update/List,
> TodoWrite) are no longer available on Opus 4.8, Sonnet 5, Fable 5, Mythos 5,
> and newer models; set `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` to bring them back
>
> **2.1.268** — Changed the task-tracking tools … to be offered only on Claude
> 3.x, Opus 4.0–4.7, Sonnet 4.0–4.6, Haiku 4.5; set
> `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` elsewhere

So the tools are present on an older model, absent on a newer one, and present
again on any model when `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` is set in
`settings.json`'s `env` block. A skill cannot know which it faces, and must not
assume.

**Judge by the roster, not by the model name.** The list above will age; what
never ages is whether the tool is actually in front of you this turn. Read the
roster.

## Identity keys

Every item a skill writes carries an identity key in its metadata, so a later
run matches rather than duplicates, and so one skill never disturbs another's
items. The keys in use:

| Key | Written by | Value |
|---|---|---|
| `preflight_key` | `/preflight` | the check's key (e.g. `cleanup-dev`) |
| `jira_key` | `/daily`, `/working` | the ticket number (e.g. `PSG-4864`) |

Two rules bind every skill writing here:

- **Match on the key before writing.** Found, advance it; absent, add it. A run
  that writes blindly duplicates on its second pass.
- **Never touch an item bearing no key you wrote.** An item without your
  skill's key belongs to another skill or to the user.

The keys are kept whether or not the tool is present today. They cost nothing
when it is absent, and they mean the sync works unchanged the moment it
returns.
