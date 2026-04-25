---
name: install
description: Run skadi install.sh to sync CLAUDE.md, settings, hooks, and skills into each configured Claude config root. Remembers roots in memory; asks on first run.
user_invocable: true
args: ""
---

# Install Claude Config

Syncs the skadi repo into one or more Claude config roots via `install.sh <root>`. `install.sh` accepts the root as its first argument (defaults to `$HOME/.claude`).

## Workflow

### 1. Resolve config roots

Read the memory file `claude_config_roots.md`. It should contain a list of absolute paths (one per line, possibly bulleted).

**If the memory exists and has paths**, use them.

**If the memory is missing or empty**, ask via AskUserQuestion:

```
question: "No Claude config roots saved. Which root(s) to install into?"
options:
  - label: "~/.claude only"
    description: "Default Claude config root"
  - label: "~/.claude and ~/.claude-personal"
    description: "Install into both"
```

The "Other" option lets the user type custom paths (comma-separated).

After the user picks, save the chosen roots to `claude_config_roots.md`:

```markdown
---
name: Claude Config Roots
description: Filesystem paths where /install syncs the skadi repo. Read by the /install skill.
type: reference
---

Roots:
- <path1>
- <path2>
```

Then add a pointer line to `MEMORY.md`:

```
- [Claude Config Roots](claude_config_roots.md) — paths used by /install
```

### 2. Run install for each root

Resolve the repo root via `git rev-parse --show-toplevel`. The skill is loaded from `.claude/skills/install/`, so the working directory is inside the skadi repo by definition.

For each resolved Claude config root:

```bash
"$(git rev-parse --show-toplevel)/install.sh" <root>
```

Show the script's output.

### 3. Report paths

For each root, print:

```
<root>:
  CLAUDE.md       <root>/CLAUDE.md
  settings.json   <root>/settings.json
  statusline      <root>/statusline.sh
  hooks           <root>/hooks/
  skills          <root>/skills/
```

## Rules

- Do not pass any flags to `install.sh` beyond the root path
- If `git rev-parse --show-toplevel` fails, the working directory is not inside a git repo — stop and ask the user to `cd` into the skadi repo before invoking `/install`
- If the resolved repo root has no `install.sh` at its top, stop and tell the user this isn't the skadi repo
- If the memory file exists but looks malformed, fall back to asking again and overwrite
- To change the saved roots, the user can edit `claude_config_roots.md` or delete it to re-prompt
