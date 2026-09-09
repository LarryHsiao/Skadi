# Mechanism cache (Pengolodh)

A per-repo cache of facts a cold session cannot get from `rg` in one call —
which of several look-alike modules is live, where a request actually
begins, what invariant a strangely-shaped file protects, which of two
contradicting conventions won. Read this before recording an entry, and
before authoring or reviewing anything that touches `hooks/pengolodh.sh` or
`hooks/pengolodh.py`.

## When to record

At the same moment a worklog entry and the Compliance Review are already
owed — when a turn reports work as done or complete. Not a separate habit:
if debugging or tracing a path just taught you something the cache should
hold, write it down before the "done" report, the same way you would write
the worklog line.

Recording is opportunistic, not a sweep. There is no scan phase and no
coverage target — an entry is written only when a task already paid the
cost of discovering it. A repo with no entries after real work in it simply
means nothing non-derivable has been learned yet, not that the cache failed.

## The boundary rule

Two questions, in order — both mechanical, so neither is the kind of
judgment call that gets skipped silently under time pressure.

**First: is it a fact, checkable as true or false, or is it an opinion?**
"The auth flow is convoluted" fails here — no anchor and no auto-memory
entry could make it checkably true or false, so it is recorded nowhere.
This filter runs before the boundary rule below even applies; it is not a
third destination alongside cache and auto-memory, it is what keeps opinions
out of both.

**Second, for whatever survives that filter:**

> An entry bearing a `` `file:line` `` anchor goes to the mechanism cache.
> An entry without one goes to auto-memory or the knowledge-base repo.

The anchor test needs no judgment either: either the fact points at a
specific line that can be checked against the tree, or it does not.

- **Good** — "Retry backoff is capped at 30s, not configurable" — a fact,
  and `retry.rs:44` exists with the cap as a literal in the code. Cache.
- **Good** — "The team prefers GitLab MRs over GitHub PRs for this client" —
  a fact, and no file makes it true or false. Auto-memory or the knowledge
  repo.
- **Bad** — "The auth flow is convoluted" — fails the first question. Not a
  fact, so neither destination applies; it is recorded nowhere, anchor or
  not.

## What gets recorded — and what never does

Five facets, chosen because none of them is answerable by grep:

- **Entry points** — where a request, a build, or a session actually begins.
- **Live vs. dead** — which of several look-alike modules is the one that
  runs, and which is a corpse nobody deleted.
- **Seams** — where a change of kind X always lands.
- **Invariants** — what a strangely-shaped piece of code is protecting.
- **Conventions in force** — naming the loser when two patterns contradict.

An entry that starts *describing behaviour* rather than *locating it* has
become a spec, and specs are out of scope here — see `CLAUDE.md`'s
*Simplicity* and *Surgical Changes* for why a generated description of code
is a liability, not an asset: it reads as confident prose long after it has
gone stale, and nothing about it announces the drift.

## Entry format

```markdown
<!-- pengolodh v1 | repo: skadi | last-verified: 2026-09-09 -->

## Seams
- **New skill needs no registry** — `install.sh:143` — glob-discovered by
  `mirror_dirs`; a directory is enough <!-- a:mirror_dirs c:high -->

## Invariants
- **Live `~/.claude*` copies are overwritten on install** — `install.sh:81`
  — repo first, never the copy <!-- a:install_file() c:high -->
```

Every entry line carries a trailing anchor comment:

- `` `file:line` `` — the location, a path relative to the repo root.
- `<!-- a:LITERAL c:high|low -->` — `LITERAL` is a substring `verify`
  expects to find in that file; `c:` is your confidence in the entry.

**Pick a literal specific enough to be unique.** `install_file` alone
matches both the function's definition and an unrelated comment mentioning
it earlier in the file — `verify` finds whichever comes first, which may
not be the one you meant. `install_file()` (with the parens) or a longer
phrase disambiguates. This was found by dogfooding the very first real
entry written for this repo — not a hypothetical.

Confidence is not a guess about how important the fact is; it is how sure
you are the fact is still true. Low-confidence entries are the first thing
dropped when `inject` runs over its size budget, and the first thing worth
revisiting by hand.

**Never put a second `path:line`-shaped span in backticks in the
description text.** `verify` takes the first backtick span it finds on the
line as *the* location — if a description mentions another file in passing
using the same backtick-and-colon shape, that mention wins silently and the
real anchor is checked against the wrong place. If a description genuinely
needs to reference another location, name it in plain words instead of
backticks: "see also other.rs, near the retry loop."

## Storage and the tools

`~/.skadi/mechanisms/<repo-key>/index.md`, one file per repo — resolved by
`hooks/pengolodh.sh path <repo-root>`, which creates the file's directory if
needed. Because `~/.skadi` is on `dir-guard.sh`'s allowlist, any session can
append to it directly, from any repo, with no `/handoff` detour.

```bash
idx="$(bash ~/.claude/hooks/pengolodh.sh path "$PWD")"
# append your entry to $idx
```

- `bash ~/.claude/hooks/pengolodh.sh verify <repo-root>` — walks every
  anchor, repairs a line number that merely moved, reports STALE (literal
  gone) or MISSING (file gone).
- `bash ~/.claude/hooks/pengolodh.sh status <repo-root>` — entry and
  staleness counts, plus the git posture (see below).
- `bash ~/.claude/hooks/pengolodh.sh inject <repo-root>` — what
  `pengolodh-inject.sh` feeds into a session's `SessionStart` context: the
  same repair pass, with STALE/MISSING entries withheld and, if still over
  budget, low-confidence entries dropped next. This never touches the file
  on disk — it is a session-scoped withholding, not a deletion.
- `bash ~/.claude/hooks/pengolodh.sh gc <repo-root>` — the file-mutating
  counterpart: permanently deletes whatever `verify` confirms STALE or
  MISSING. Leaves a `c:low` entry alone as long as it still verifies OK —
  low confidence is a claim about certainty, not a claim about correctness,
  and `gc` only ever removes what is mechanically confirmed dead.

Any `verify`/`inject`/`gc` call that touches the file normalizes its line
endings to `\n` (Python's universal-newlines handling) — harmless for a
markdown file one contributor edits, but worth knowing if you ever diff
this file against a version authored on a CRLF editor.

## Git is optional

The cache works as plain files on one machine with no git at all. Git only
adds cross-machine accumulation and history, so nothing here requires it or
runs `git init` on your behalf — `status` detects its absence and prints the
command to run, and syncing (pull/push) only happens once
`~/.skadi/mechanisms/.autosync` exists, which `status` also offers. Full
mechanics — why commit is automatic but sync is opt-in, why sync runs
detached, why divergence stops rather than auto-merges — are in the
`README.md` *Setup* section; this doc only needs you to know the switch
exists and where `status` tells you about it.

## The open question

Whether this cache actually saves a cold session real work has not been
measured. Watch two things as it accumulates: whether entries actually get written (a cache
with near-zero entries after real work means the recording rule is being
missed silently, and has earned promotion to a hook per
`docs/workflow/maintenance.md`'s evidence bar), and whether an indexed
session genuinely needs fewer search tool-calls than an unindexed one. If
neither holds after a fair trial, delete this — a cache nobody uses or that
saves nothing is ceremony, not infrastructure.
