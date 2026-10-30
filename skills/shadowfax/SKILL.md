---
name: shadowfax
description: Use when the user runs /shadowfax <the change>, or asks in plain words to "make a small change in the cloud", "quick fix from my phone", "do this small tweak and merge it". Carries one small change end to end in a fresh cloud container — readies the toolchain the project pins, asks what is unclear in plain words, shows a preview before any UI code, builds and verifies it, then merges straight into the default branch with no pull request. Built for a container that starts bare and is thrown away after; on the bench, the ordinary work loop needs none of its setup.
purpose: Carries one small change from ask to merged in a fresh cloud container.
args: "<the change>"
user_invocable: true
stage: forge
---

# Shadowfax — the Swift

Shadowfax comes when called and outruns the road. One small change, one cloud
session: read the rules, ready the tools, show the shape, build it, prove it,
land it on the default branch. The container is new each time and gone after,
so everything the bench keeps standing — the SDK, the generated code, the SSH
key — is paid for again, once, at the start.

The argument is the change, in the user's words: `/shadowfax hide locked posts
behind a settings switch`. With no argument, ask what to change before
anything else.

## The run

### 1. Ground

- The CLAUDE.md rules are already loaded; follow them as on the bench. The
  slash invocation is the approval for this skill's purpose, so the Free-Form
  Gate block is not written — step 4's preview-and-plan is the confirm step
  instead.
- Find the project: the repository the change names, among those attached to
  the session. If two could fit, ask which.
- Find the branch to work on: the session's designated feature branch where
  the harness names one, else a new branch off the default branch.

### 2. Ready the toolchain

For a Flutter project (a `pubspec.yaml` at the root):

    ~/.claude/hooks/shadowfax-toolchain.sh <project-dir>

Run it bare, not inside `eval` or a pipe, so its permission entry matches and
no prompt interrupts. It clones the SDK the project pins (`.fvmrc`), rewrites
`git@github.com:` to https so pub reaches git dependencies through the proxy,
runs `pub get`, and runs `build_runner` when the project uses it. Its one line
on stdout is an `export PATH=...` line. Shell state does not carry between
calls, so prefix every later Flutter call with that line. Call `flutter`
directly, not `fvm flutter`: the export already puts the pinned SDK first.

For anything else, read the project's README or CI config and run its own
install step. Do not guess a toolchain the project does not name.

When a download is blocked, stop and ask the user to allow it — name what was being fetched and why. Do not route around
the refusal.

### 3. Ask

Read the code the change touches before asking anything. Then ask, with
AskUserQuestion, only the questions whose answer changes what gets built —
where a control goes, what else it should reach, what the default is. Put the
recommended option first. Use the words the user's preferences ask for. Where
they ask for plain, non-programmer words, say what the user will *see*, not
what the code will do.

### 4. Preview and plan — wait for the word

For any change a user can see, show it before writing the code:

- **Render the real widget when it exists.** In Flutter, a throwaway widget
  test can pump the actual components and write a PNG through
  `matchesGoldenFile` with `--update-goldens`. The test fonts draw boxes for
  every glyph unless real fonts are loaded:
  - Load Roboto (shipped under the SDK at
    `bin/cache/artifacts/material_fonts/`) with `FontLoader`, and set
    `ThemeData(fontFamily: 'Roboto')`.
  - Load a CJK font as its **own family** and name it in
    `fontFamilyFallback`. Folded into Roboto's family at the same weight, one
    face wins and the other script still draws as boxes.
  - Delete the throwaway test afterwards. It is never committed.
- **Draw a wireframe when it does not exist yet.** Follow CLAUDE.md's
  *Previews* rules.
- Send the image with SendUserFile.

Then list, in those same words:

- what will change;
- what the user will see when it is done;
- what will deliberately be left alone;
- the steps, each small enough to verify on its own.

Wait for the user's word. A change no one can see skips the preview, but not
the plan or the wait.

### 5. Build and prove

Work the CLAUDE.md *Implementation Loop*: steps cut in layers, a test with
every new branch, static analysis clean after each step. In this container:

- A generated file (translation keys, `.freezed.dart`, `.g.dart`) is
  regenerated with the project's own generator, never hand-written.
- Before trusting an analyzer count, run `build_runner`. Generated code is not
  checked in, and its absence reads as hundreds of errors in files the change
  never touched.
- When a suite fails, find out whether the failure is yours before calling it
  pre-existing. Tests often lean on a shared marker, such as an icon, a key,
  or a string, that a new widget can borrow by accident.

If the change turns out bigger than small — more files, a riskier edit, a
decision nobody named — stop and tell the user before going on. Their word
covered the plan they saw, not the one it grew into.

Close with the CLAUDE.md *Compliance Review* and a fresh run of the full
suite, both in the same turn as the report. If no reviewer can be dispatched,
say so and write no verdict line, as CLAUDE.md requires.

### 6. Land

1. Commit on the working branch and push it.
2. Fetch the default branch. Confirm it is an ancestor of the working branch;
   if it has moved, merge it in, re-run the suite, and push again.
3. Merge into the default branch with `--no-ff` (or match the repository's
   own history when it plainly does otherwise), then push the default branch.
   No pull request — that is this skill's whole purpose. If the user asks for
   one, open one instead and stop here.
4. Delete the working branch, locally and on the remote. A cloud session's
   git proxy may refuse the remote delete with a 403. If it does, say so in one
   line and give the user the repository's branches page as a link, so they
   can delete it with one tap.

### 7. Report

Lead with the verdict. Then, in the user's words:

- what now works;
- what was checked, naming the same-turn analysis and test counts;
- what still needs the user's hands — a run on a real device, a branch to
  delete.

End with the Compliance Review line, as CLAUDE.md requires.

## What the cloud cannot do

Name these when they come up, rather than discovering them each time:

- **No device or emulator.** The app cannot be launched or tapped through.
  A widget test render is the nearest stand-in.
- **No hot reload.** `/narya` has no device to hold.
- **No iOS build.** The container runs Linux.
- **Nothing survives.** The SDK, generated code and caches are gone when the
  container is reclaimed. Anything worth keeping is committed and pushed.
- **No `~/.skadi` state.** Worklog, handoff channels and memory pointers are
  unconfigured here. Their hooks stay silent; do not ask for their paths.
