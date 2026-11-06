---
name: imladris
description: Use when the user runs /imladris <group|repo|git-source>..., /imladris sync, or /imladris done, to gather several repos into the current empty folder and work across them in one session. Build clones each named repo (or every repo a group in repo_groups.md lists) into its own subfolder, so the session's project directory holds them all and dir-guard needs no loosening; sync repairs the folder; done tears it down only when no work would be lost. Refuses a non-empty folder and any protected repo.
purpose: Gathers several repos into the current empty folder so one session can work across them.
user_invocable: true
args: "<group|repo|git-source>... | sync | done"
stage: desk
---

# Imladris — the Last Homely House

Imladris, which men call Rivendell, was the house in the hidden valley where
travellers out of many lands met, rested, and took counsel before a journey.
This skill is that house for repos. Work that crosses repos has always had one
awkward fact in the way: a session may only edit beneath its own project
directory (`dir-guard.sh`), so a change spanning three repos meant three
sessions and a baton passed between them. Imladris turns it round — start in
an empty folder, gather the repos into it, and the one session stands in
all of them.

The folder is disposable and the recipe is the memory. Only what is pushed
survives a rebuild; `repo_groups.md` lets the same folder be built again.

## When to use

- A change spans two or more repos and one session should hold them all.
- The same set of repos is gathered again and again — name it once in
  `repo_groups.md`, then `/imladris <group>`.

Not for a single repo (open a session there), and not for the repos listed in
`~/.skadi/protected_repos.md` — the skill refuses those by folder name; route
to their own session with `/handoff send <repo>` instead.

## Arguments

`/imladris <name-or-source>...` — each argument is, in this order:

1. a **group** from `repo_groups.md` — every repo it lists,
2. a **repo** from `repo_groups.md` — one named source,
3. a **git source** as it stands — anything containing `/` or `:`, or ending
   `.git` (a URL, an ssh address, a local path); it clones into a folder named
   for its last path part.

An unknown name is refused, with the known groups listed.

`/imladris sync` — repair an existing workspace. `/imladris done` — tear it down.

## Where the recipe lives

`~/.skadi/profiles/<profile>/repo_groups.md`, resolved by
`skadi-state.sh profile-path` — profile-level, so any folder finds it, and the
work and personal profiles keep their own. Two line shapes; `#` comments and a
leading `- ` are ignored:

```
psg-app = git@github.com:org/psg-app.git
psg-be  = git@gitlab.example.com:org/psg-be.git

psg: psg-app psg-be
```

When the file is absent, say so plainly and show this shape; do not invent
repo sources. An argument that is already a git source works without the file.

## Workflow

### Step 1: Confirm the folder is the intended workspace

The session's working directory is the workspace. Run `pwd` and name it to the
user before cloning. If it is not empty, do not clear it: tell the user to open
a session in an empty folder (`mkdir ~/work/ws-<topic> && cd` there).

### Step 2: Build

```bash
bash ~/.claude/hooks/imladris.sh build <name-or-source>...
```

Report each `cloned:` line and any refusal verbatim. Refusals change nothing:
the folder is checked, names resolved, and protected repos weighed before the
first clone. A clone that fails midway leaves the repos already cloned in
place and the recipe in `.imladris`, so the fault can be mended and the folder
repaired rather than rebuilt.

### Step 3: Sync (when asked)

```bash
bash ~/.claude/hooks/imladris.sh sync
```

Clones any repo of the recorded set that has gone missing; fast-forwards a repo
that is clean and behind. A repo with uncommitted changes, a diverged history,
or no git directory is left exactly as it stands and reported `skipped` with the
reason — do not resolve those for the user unprompted. Report every line verbatim.

### Step 4: Done (when asked)

Two calls, one confirmation between them.

```bash
bash ~/.claude/hooks/imladris.sh done
```

This only reports. Each repo reads `clean:`, `blocked:` or `absent:` (already
gone). A `blocked:` reason is one of: uncommitted or untracked files, a stash, a
linked worktree, commits that no remote holds (on any branch, a detached HEAD, a
tag, the reflog, or inside a submodule), an ignored folder that holds a git
repo of its own, a git that could not be read, a symlink
standing in the clone's place, or a folder that is not a git repo. If any repo is `blocked`, stop there: relay the
reasons, and let the user push, commit or discard first — the script refuses to
delete anything while one repo is blocked.

A `clean:` line may carry a note, `N ignored item(s) go with it (...)`: files
git ignores (a `.env`, a build folder) are not work a remote could hold, so they
do not block, but they are deleted with the clone. Read that note to the user.
If all are `clean`, say the clones are about to be deleted, name any ignored
items, wait for a plain yes, then:

```bash
bash ~/.claude/hooks/imladris.sh done --confirm
```

It removes the clones and `.imladris`, and leaves the folder itself, since the
session stands in it. If a clone cannot be removed (a `failed:` line), `.imladris`
is kept and the rest of the clones are already gone: tell the user which folder
to remove by hand, and do not retry with `rm -rf` on their behalf. Never pass `--confirm` on the first call.

### What `done` cannot see

Say these plainly if the user asks how safe the check is:

- It trusts the clone's remote-tracking refs. A push that failed after a ref was
  updated locally is not caught; `git fetch` inside the clone first if in doubt.
- Tags are weighed against the remote: a tag the remote also holds does not block,
  and a tag only this clone has, or one moved here, does. That needs the remote
  reachable; offline, or after 30 seconds without an answer, a clone whose only
  unpushed-looking commits are tagged reads `blocked: git could not be read`, never
  `clean`. A remote that is the clone itself or another clone in the workspace is
  not asked, since it is deleted along with the workspace.
- Commits reachable only from the reflog block the teardown, including ones the
  user abandoned on purpose (a deleted branch, a reset). They clear when the user
  pushes them or lets git's own reflog expiry drop them — that is the user's call.
- Only git history is looked for inside ignored folders. A Mercurial, Subversion or
  Fossil checkout in an ignored folder is not recognised and is deleted with the clone.
- A remote that points at another clone counts as "pushed". Deletion is all or
  nothing, so the other clone's own check still holds the line — but if that
  clone was already removed, the commits are gone with it.
- A mode-only change (`chmod +x`) is invisible when the clone has `core.fileMode=false`,
  which is git's own default on Windows; the check does not override it, since
  forcing it on would flag every file there.
- A sparse-checkout clone, or any file flagged `assume-unchanged` or
  `skip-worktree`, blocks the teardown: git cannot show whether those files were
  edited, so the check will not guess.
- A build that failed partway leaves the repos already cloned and `.imladris` in
  place: run `/imladris sync` to finish the set.

## After the build

The session root is now the workspace, not a git repo. Run git per repo with
`git -C <repo> ...`, or `cd` into one for commits and PRs. Each repo's own
`CLAUDE.md` loads only when files in it are touched.

## Rules

- Never build into a folder that already holds anything; the check is the
  script's, not a courtesy.
- Never clone a protected repo, and never work around the refusal.
- Never edit `.imladris` by hand; it is the record `sync` and `done` read.
- Never delete a clone by any route but `done --confirm`, and never reach for
  `rm` to get past a `blocked:` line — that line is the whole point of the check.
