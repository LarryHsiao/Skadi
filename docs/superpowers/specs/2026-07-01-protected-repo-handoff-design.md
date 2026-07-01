# Protected-repo guard — route skadi/Minerva edits through `/handoff`

**Date:** 2026-07-01
**Status:** design, awaiting review

## Purpose

skadi (this repo) and Minerva (the personal knowledge base) are both "rule"
repos — their content shapes how every other session behaves or what it
believes is true. A session rooted in an unrelated project should never
mutate either directly; it lacks the context of the rules already in force
there, and a silent edit from an unrelated repo is exactly the kind of
un-reviewed drift skadi's own `CLAUDE.md` warns against. Instead, such a
session should hand its proposed change to a session that *is* rooted in the
target repo, via the existing `/handoff` mailbox — the target session applies
it with full context, under its own repo's normal review discipline.

## Current gap

Two existing hooks guard cross-directory access, but neither covers this case:

- **`dir-guard.sh`** — `Bash`-matcher only. Blocks a Bash command that
  references an absolute path outside the project dir / `~/.claude` / `/tmp` /
  `CLAUDE_DEV_DIRS`. Since `CLAUDE_DEV_DIRS` is currently unset, a Bash `git`
  operation against Minerva from another repo's session is *already* denied —
  but the denial is generic and gives no path forward.
- **`worktree-guard.sh`** — `Write|Edit|MultiEdit|NotebookEdit`-matcher. Its
  own comment states the scope plainly: it blocks same-repo cross-worktree
  edits only. *"Unrelated repos (a different project, ~/Minerva, /tmp) are
  NOT affected."* So today, a direct `Edit`/`Write` into skadi or Minerva from
  any other session's file tools is completely unguarded.

This design closes that gap with one new hook, and gives the blocked session
a concrete next step instead of a dead end.

## Mechanism

### `protected_repos.md` — the list

**Not** an auto-memory file. Auto-memory is scoped per *project directory*
(`~/.claude-personal/projects/-Users-larryhsiao-<project>/memory/`) — a hook
firing in a session rooted in some other project would never see a memory
file that only exists under skadi's own project-memory folder. `/moria`
already hit this exact problem for `mend_repos.md` and solved it the same
way: a **global store outside any per-project memory dir**, so the file reads
identically "from whatever directory you summon" it.

Plain flat file at `~/.skadi/protected_repos.md` — one line per protected
repo, absolute root path → handoff channel name:

```
- /Users/larryhsiao/skadi → skadi
- /Users/larryhsiao/phantom/Minerva → minerva
```

No frontmatter (the hook parses it with shell tools, not the memory system);
same bare list-line shape `mend_repos.md` uses. The list is deliberately
generic — adding a third protected repo later is a one-line file edit, not a
hook change. Lives under `~/.skadi/`, so — like `~/.skadi/handoff/` and
`~/.skadi/moria/` — it is **never touched by `/install`** (it's runtime
config, not propagated skadi source) and is visible to every session
regardless of profile (`~/.claude`, `~/.claude-personal`, `~/.claude-work`)
or working directory.

### `hooks/protected-repo-guard.sh` — the guard

New `PreToolUse` hook, registered on both the `Bash` matcher and the
`Write|Edit|MultiEdit|NotebookEdit` matcher — sitting beside `dir-guard.sh`
and `worktree-guard.sh`, each keeping its one existing concern.

Logic:

1. Read `~/.skadi/protected_repos.md`. If missing or unparseable, exit 0
   (fail open — a broken list file must never silently break unrelated
   sessions' normal edits elsewhere).
2. Resolve the session's own project root (`$CLAUDE_PROJECT_DIR`, normalized
   the same way `dir-guard.sh` already normalizes paths — lowercase, forward
   slashes, Windows-drive handling — so the two hooks agree on equivalence).
3. For each protected repo in the list:
   - If the session's own root **is** that repo (or nested under it), skip —
     self-edits are never blocked; this hook only guards *other* sessions.
   - Otherwise, extract the target path(s) for the tool call — `file_path` /
     `notebook_path` for Edit/Write/MultiEdit/NotebookEdit; absolute-path
     tokens in the Bash `command` string, reusing `dir-guard.sh`'s existing
     shlex-based tokenizer so quoted strings aren't false-flagged.
   - If any target path resolves inside the protected repo, **deny**:
     ```
     Blocked: <repo-name> is protected — run
     `/handoff send <channel> <your change>` instead.
     ```
4. This check runs **before** and **independent of** `CLAUDE_DEV_DIRS` — a
   protected repo listed as a dev dir is still blocked. Protected means
   protected; the dev-dir escape hatch must not silently defeat it.
5. The `Read` tool is not guarded. Cross-repo reads for context (checking
   skadi's own conventions before proposing a change, say) stay unaffected —
   only mutation is walled off.

### `/remember` update

Today, `/remember` always attempts a direct write into `$MINERVA_ROOT`
regardless of where the session is rooted (see the skill's own header: "writes
into the Minerva knowledge-base repo regardless of the current working
directory"). That write would now be caught by the new guard whenever the
session isn't rooted in Minerva — but hitting a hook denial mid-skill is a
worse experience than the skill knowing better up front.

**Step 0 gains a root check:** compare `$CLAUDE_PROJECT_DIR` (resolved
toplevel) against `$MINERVA_ROOT`.

- **Same repo** — nothing changes; the skill proceeds exactly as it does
  today (duplicate check, category, sub-category, write, confirm, commit,
  push).
- **Different repo** — skip straight past the write path. Still run Steps 2–3
  (category / sub-category judgment) so the composed note carries the right
  shape, then compose the note body (title, company blockquote if
  applicable, content, date line — same content rules as Step 4) and:

  ```bash
  printf '%s' "<composed note, with intended path as a heading>" | \
    ~/.claude/hooks/handoff.sh send minerva
  ```

  Tell the user plainly: *"Not rooted in Minerva — queued this note on the
  `minerva` handoff channel instead of writing directly. Open a Minerva
  session and run `/handoff read minerva` to file it."*

  Step 1's duplicate check (grepping the live Minerva tree) is skipped in
  this path — the session has no read access reason to reach into Minerva's
  tree for this, and the check is deferred to pickup time anyway (see
  below). This is a known trade-off, not an oversight.

## Data flow

**Case 1 — skadi, blocked edit.** A session rooted elsewhere attempts
`Edit(/Users/larryhsiao/skadi/CLAUDE.md, …)`. The guard denies with the
`skadi` channel name. The model reacts in the same turn:
`/handoff send skadi <the proposed change, described in prose>`. Later, a
session opened at the skadi root runs `/handoff read skadi`, reviews the
proposal, and makes the edit itself as a normal free-form change — subject to
skadi's own Change Approval gate, exactly as if the idea had originated
there.

**Case 2 — Minerva, `/remember` redirect.** A session anywhere runs
`/remember "some note"`. Step 0 finds the session isn't rooted in Minerva,
so it composes the note and runs `/handoff send minerva <note>` instead of
writing. Later, a session opened at the Minerva root runs
`/handoff read minerva`, sees the queued note, and re-runs
`/remember <content>` **from inside Minerva** — the root check now passes,
so it takes the normal direct-write path, with its existing duplicate-check
and categorization logic fully intact. Both repos pick up the identical way:
`/handoff read <channel>`, then act locally.

## Pickup — fully manual

No `SessionStart` automation, no polling, no `subscribe`-based live pickup
for this flow — considered and explicitly declined. Picking up a queued
change is a deliberate act: open a session rooted in the protected repo,
run `/handoff read <channel>`, decide what to do with what's there. This
matches `/handoff`'s own default (manual `read`) rather than reaching for its
optional `subscribe` live-pickup mode.

## Edge cases

- **Missing/malformed `~/.skadi/protected_repos.md`** — hook exits 0, no
  protection. Fail-open: a broken list file must not become a silent,
  hard-to-diagnose block on unrelated work.
- **Session already rooted in the protected repo** — never blocked; this is
  the whole point. The guard only fires for *other* sessions.
- **`CLAUDE_DEV_DIRS` lists a protected repo** — still blocked. No escape
  hatch, per the explicit design choice above.
- **Nonexistent target paths** (a `Write` to a not-yet-existing file under
  skadi) — comparison is a normalized string-prefix check against each
  protected repo's known root, not a `git`/`cd`-based resolution, so it needs
  no existing file or directory on disk. This is simpler than
  `worktree-guard.sh`'s ancestor-walk, which exists only because *that* hook
  resolves git toplevels.
- **Nested repo relationships between protected entries** — not a real
  scenario here (skadi and Minerva are unrelated sibling trees); not
  specially handled.

## Wiring

- `settings.json` → `PreToolUse` gains `~/.claude/hooks/protected-repo-guard.sh`
  as an additional hook on both the existing `Bash` matcher group and the
  existing `Write|Edit|MultiEdit|NotebookEdit` matcher group.
- `permissions.allow` gains `Bash(~/.claude/hooks/protected-repo-guard.sh:*)`.
- `hooks/protected-repo-guard.sh` must run clean under macOS bash 3.2 (no
  `${var,,}`, `declare -A`, `mapfile`) — the same trap `dir-guard.sh` and
  `handoff.sh` already navigate around.
- `~/.skadi/protected_repos.md` is created once by hand (or by a first-run
  bootstrap in the hook, mirroring how `handoff.sh` lazily creates its own
  channel folders) — **not** propagated by `/install`, same as
  `~/.skadi/handoff/` and `~/.skadi/moria/mend_repos.md`.
- Propagate the hook + `/remember` skill change with `/install`.

## Acceptance

1. From a session rooted outside skadi, `Edit`-ing a file under
   `/Users/larryhsiao/skadi/` is denied, and the denial names the `skadi`
   channel and the `/handoff send` command to use.
2. From a session rooted outside Minerva, `/remember "test note"` does not
   create any file under Minerva; it instead appends a message to the
   `minerva` handoff channel, and says so to the user.
3. From a session rooted *inside* skadi, editing skadi files is unaffected —
   no denial, no behavior change from today.
4. From a session rooted *inside* Minerva, `/remember "test note"` still
   writes, commits, and pushes directly, exactly as it does today.
5. Setting `CLAUDE_DEV_DIRS` to include the Minerva parent directory does
   **not** un-block a direct edit from another repo's session.
6. `/handoff read skadi` and `/handoff read minerva` both surface queued
   messages from a session rooted in the respective repo.
7. `hooks/protected-repo-guard.sh` runs clean under `/bin/bash` (3.2).

## Out of scope (YAGNI for v1)

- `SessionStart` automation announcing unread protected-repo channels —
  explicitly declined; pickup is manual.
- Auto-applying a queued `/handoff` message on pickup — the human/model still
  reviews and decides how to file it (re-running `/remember`, or making the
  skadi edit by hand).
- Extending the guard to the `Read` tool — reads across repos remain
  unrestricted.
- A generalized "protected-repo edit" skill beyond `/remember`'s own update —
  no other existing skill writes into skadi or Minerva from outside, so none
  else needs a redirect path today.
