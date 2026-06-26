---
name: remember
description: Use when the user wants to save knowledge to the Minerva knowledge base — from any repo, not just Minerva itself. Determines category, suggests sub-categories, and writes the note into the Minerva repo.
user_invocable: true
args: "[topic or content to remember]"
---

# Remember — Save Knowledge to Minerva

This skill writes into the **Minerva** knowledge-base repo regardless of the current
working directory. Every search, write, and git action below targets the Minerva
root resolved in Step 0 — never the cwd.

## Arguments

- Optional free-text: the topic or content the user wants to remember

## Workflow

### Step 0: Resolve the Minerva root

Before anything else, resolve the absolute path to the Minerva repo and use it for
every file and git operation in the steps that follow:

```bash
MINERVA_ROOT="${MINERVA_ROOT:-$HOME/phantom/Minerva}"
```

The `MINERVA_ROOT` env var is the override; the `~/phantom/Minerva` fallback is the
default when it is unset. Confirm the path exists (`test -d "$MINERVA_ROOT"`); if it
does not, tell the user plainly and stop — do not write the note into the cwd.

All paths named below (`work/…`, `personal/…`) are **relative to `$MINERVA_ROOT`**.
Read, write, and commit against the absolute path; never against the working
directory the session happens to sit in.

### Step 1: Check for Duplicates

Before creating anything, search the Minerva repo for existing notes on the same topic:

1. Use Grep over `$MINERVA_ROOT` to search for key terms from the user's input across
   all `.md` files.
2. If a relevant note already exists, ask the user using AskUserQuestion:

```
question: "Found an existing note at <path>. Update it or create a new one?"
header: "Existing note found"
options:
  - label: "Update existing"
    description: "Append or modify <path>"
  - label: "Create new"
    description: "Create a separate note"
```

3. If updating, edit the existing file and skip to the end (show the path).

### Step 2: Determine Main Category

Check if the user's input clearly belongs to one of these top-level categories:

| Category | Purpose |
|----------|---------|
| `work/` | Engineering, tools, processes, debugging, management |
| `personal/` | Finance, health, learning, home |

If the category is **not obvious** from context, ask the user using AskUserQuestion:

```
question: "Which category does this belong to?"
header: "Category"
options:
  - label: "Work"
    description: "Engineering, tools, processes, debugging, management"
  - label: "Personal"
    description: "Finance, health, learning, home"
```

### Step 3: Determine Sub-Category

Each top-level category has sub-folders, plus shared `projects/` and `resources/` folders:

**work/**
| Sub-folder | What goes here |
|------------|---------------|
| `engineering/` | Architecture, design patterns, code review, language knowledge |
| `tools/` | IDE setup, CLI tools, CI/CD, Docker, Git workflows |
| `processes/` | Team workflows, agile/sprint, on-call, incident response |
| `debugging/` | Debugging techniques, postmortems, failure modes |
| `management/` | 1:1s, career growth, hiring, feedback, people & roles |
| `projects/active/` | Active project notes |
| `projects/archive/` | Archived project notes |
| `resources/bookmarks/` | Bookmarked links |
| `resources/cheatsheets/` | Quick reference sheets |
| `resources/reading-notes/` | Notes from articles, books, talks |

**personal/**
| Sub-folder | What goes here |
|------------|---------------|
| `finance/` | Budgeting, taxes, investments, insurance |
| `health/` | Exercise, nutrition, medical, mental health |
| `learning/` | Courses, skill-building, language learning |
| `home/` | Home maintenance, cooking, travel, local services |
| `projects/active/` | Active personal project notes |
| `projects/archive/` | Archived personal project notes |
| `resources/bookmarks/` | Bookmarked links |
| `resources/cheatsheets/` | Quick reference sheets |
| `resources/reading-notes/` | Notes from articles, books, talks |

1. Pick the best-fitting sub-folder from the tables above.
2. If none fits, suggest a new sub-folder name using AskUserQuestion:

```
question: "No existing sub-folder fits. Create a new one?"
header: "Sub-folder"
options:
  - label: "<suggested-name>"
    description: "New sub-folder for this topic"
  - label: "Place in <category>/ root"
    description: "Skip sub-folder, put it directly in the category"
```

If a new sub-folder is created, also create a `README.md` in it following the pattern of existing READMEs.

### Step 4: Write the Note

1. Pick a `kebab-case.md` filename that captures the topic.
2. Write the file under `$MINERVA_ROOT/<category>/<sub-folder>/<filename>.md` with:
   - A top-level `# Title` heading
   - If the note belongs under `work/`, a `> **Company:** <employer>` blockquote near the top identifying which employer the content pertains to (default: Jubo Health — confirm with the user if the content looks cross-company or generic)
   - The knowledge content, organized clearly
   - A date line if the content is time-sensitive: `*Captured: YYYY-MM-DD*`
3. Show the user the full file content and path.

### Step 5: Confirm and Commit

Ask the user using AskUserQuestion:

```
question: "Save this note to Minerva?"
header: "Confirm"
options:
  - label: "Save"
    description: "Commit and push to remote"
  - label: "Discard"
    description: "Delete the file, nothing saved"
```

- If **Save**: run the git steps against the Minerva repo, not the cwd —
  `rtk git -C "$MINERVA_ROOT" add <relative-path> && rtk git -C "$MINERVA_ROOT" commit -m "Add note: <filename>" && rtk git -C "$MINERVA_ROOT" push`
- If **Discard**: delete the file and notify the user.

## Rules

- One focused topic per file.
- File names use `kebab-case.md`.
- Use relative paths for cross-references between notes.
- Don't over-structure — keep notes concise and scannable.
- If the user provides multiple unrelated things to remember, create separate files for each.
- Every file and git operation targets `$MINERVA_ROOT` (Step 0), never the working directory.
