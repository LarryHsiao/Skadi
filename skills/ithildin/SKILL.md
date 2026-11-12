---
name: ithildin
description: Use when the user runs /ithildin <ACs or a plan file>, or asks in plain words to "capture proof for each acceptance criterion", "screenshot every AC", "make a report that proves the AC". Takes a list of acceptance criteria, shoots one screenshot of the running app for each, and reads each shot and gives the AC a pass, fail or unclear verdict with a one-line reason, and renders one HTML report into Henneth with a row per AC, a badge and tally for the verdicts, and a plain missing-proof row for any capture that failed. Never drives the app — the user navigates, it captures. Built on Fëanor's shot hooks.
purpose: Captures one screenshot per acceptance criterion, judges it, and renders an HTML proof report.
args: "<ACs | plan file>"
user_invocable: true
stage: forge
---

# Ithildin — the Moon-Letters

Ithildin is the writing that shows only when the moon shines on it. This skill
does the same for acceptance criteria: each AC is a claim, and the report shows
the picture that backs it — or says plainly that none was taken.

It captures and reports. It does not judge whether an AC passed; that stays with
the human's eye, or with [Manwë](../manwe/SKILL.md) when a visual spec exists.

## What it needs

- **The ACs** — pasted in the call, or read from a plan concept
  (`docs/plans/*.md`) or a ticket the user names. One line each, in the user's
  words. With none given, ask which before anything else.
- **A target to shoot** — a browser-loadable URL (`feanor-shot.sh`), or a Flutter
  app already running on a booted emulator/simulator (`feanor-flutter-shot.sh`).
  The user boots the device and navigates; this skill only captures. Neither
  hook launches anything.
- **For a video** (optional) — macOS with Xcode, a booted iOS Simulator, and
  `ffmpeg`. Nothing else is recorded yet.

## The run

### 1. Capture, one AC at a time

When the user wants a video, start the recording once, before the first AC:

    ~/.claude/hooks/ithildin-record.py start

It prints the raw `.mov` path and returns once the simulator reports it has
begun. Time zero is that instant. `--device <udid>` names a simulator when more
than one is booted (default `booted`). If it exits non-zero, say why and carry
on with screenshots alone; never fake a video. The codes, shared by all three
verbs: 2 no recording in progress, 3 already recording or an unfinished
recording is kept (or no `xcrun`: macOS with Xcode is required), 4 the recorder
failed, 5 `ffmpeg` missing or failed.

For each AC, in order:

1. Say which AC is next and ask the user to put the app on the screen that
   proves it. Wait for their word.
2. With a recording running, stamp the moment first:

       ~/.claude/hooks/ithildin-record.py mark ac-<n>

3. Shoot it into the scratchpad as `ac-<n>.png`:

       ~/.claude/hooks/feanor-flutter-shot.sh <scratchpad>/ac-<n>.png [<deviceId>]
       ~/.claude/hooks/feanor-shot.sh <url> <scratchpad>/ac-<n>.png

   Run it bare so its permission entry matches. A non-zero exit is a failed
   capture: note the AC's `hint` (what the user must do for the shot to work)
   and go on to the next AC. Never retry silently, and never substitute another
   AC's image.
4. Read the image once. If it does not show the screen the AC names, it is a
   failed capture, not proof: say so and give the AC no verdict.
5. Judge it. Keep a running note for the manifest: `verdict` (`pass` when the
   screen shows the AC met, `fail` when it shows the AC not met, `unclear` when
   you cannot tell from this one image) and `reason`, one sentence naming what
   on the screen decided it. Never mark `pass` on a hope; `unclear` is the honest
   word when the shot does not settle it.

### 2. Render the report

With a recording running, end it after the last AC:

    ~/.claude/hooks/ithildin-record.py stop --out <scratchpad>/recording.mp4

It prints one JSON object: `video`, `marks` (each `{"label", "at"}`) and
`duration`. Put `video` in the manifest, and give each AC the `at` of the mark
labelled `ac-<n>`. An AC with no mark (it was skipped) gets no `at`. If `stop`
exits 5, `ffmpeg` is missing or failed: the raw `.mov` and the marks are kept,
so install it and run `stop` again; the retry pads to when the recorder stopped,
and `start` refuses to overwrite the unfinished recording meanwhile. State and
the recorder's log live in `~/.skadi/ithildin/`.

Write a manifest to the scratchpad and render it:

    ~/.claude/hooks/ithildin-report.py <manifest.json>

Manifest fields are in the hook's docstring: `slug`, `title`, optional `lede`,
optional `video` and `videoHint`, and per AC `text`, `shot`, `hint` and optional
`at`, `verdict`, `reason`, `verdictBy` and `notes`. `verdictBy` is `model`
(the default; the page labels it "model's reading") or `human` when the user
confirmed or overrode it ("your reading"). A verdict needs a shot. The hook writes
`ithildin-<slug>.html` and copies the shots into an `ithildin-<slug>/` folder
beside it in `~/.skadi/henneth/`. An AC with no shot draws a dashed
missing-proof row carrying its hint. The page opens with five exact counts, every
AC in exactly one (`pass`, `fail`, `unclear`, `not judged`, `not captured`), and
a `first fail ↓` link when any AC failed. Each judged AC wears a PASS, FAIL or
UNCLEAR badge, a left rule in its colour, and its reason clamped to three lines
with a `show full reason` toggle when it overflows.

Print the URL — the port is in `~/.skadi/henneth/.henneth-port` (boot `/henneth`
first if it is absent): `http://localhost:<port>/ithildin-<slug>.html`.

### 3. Report

Lead with the tally. Name each failed AC with its reason, then each unclear one,
then each AC that has no proof and why. The verdicts are your reading of one
screenshot each, not a test run: say so, and do not call the work verified on
their strength alone. When the user confirms or overrules a verdict, set
`verdictBy: human` (and the new `verdict`) and render again.

## The video

The report can carry one screen recording. Give the manifest `video` (a path to
an `.mp4`) and, per AC, `at` (seconds into the recording where that AC begins).
The page embeds the video once, pinned at the top, and each AC with an `at`
gets a `▶ m:ss` button that seeks the player there and plays it. A `video` that
names an absent file draws a missing block carrying `videoHint`, with no
buttons; a negative, non-finite or non-numeric `at` stops the render and names
the AC.

Seeking needs the server to answer HTTP range requests. Henneth does, since
`hooks/mirror-server.py` serves `206 Partial Content`; opened straight from disk
(`file://`) the page seeks without a server.

**How the recording works.** `ithildin-record.py` wraps
`xcrun simctl io booted recordVideo`. The simulator writes a frame only when the
screen changes, so the raw file stops at the last change and runs shorter than
the session; `stop` repeats the last frame up to the real duration and converts
to an H.264 `.mp4` browsers play. Without that, an AC marked after the final
change would seek past the end.

**Not yet built:** recording on Android, whose `screenrecord` stops at 3
minutes and needs its own answer, and on the web. Splitting the recording into
per-AC clips stays a possible later option: the `at` times are what such a
split would cut on.

## Notes

- **Shots and the video land in the report folder**, copied beside the page, so
  the page is self-contained and can be zipped and sent.
- **Re-running a slug clears its image folder** before copying, so a stale shot
  never outlives a failed re-capture.
- **Headless browser / Flutter requirements** are Fëanor's — see its *Notes*.
