---
name: ithildin
description: Use when the user runs /ithildin <ACs or a plan file>, or asks in plain words to "capture proof for each acceptance criterion", "screenshot every AC", "make a report that proves the AC". Takes a list of acceptance criteria, shoots one screenshot of the running app for each, and renders one HTML report into Henneth with a row per AC and a plain missing-proof row for any capture that failed. Never drives the app — the user navigates, it captures. Built on Fëanor's shot hooks.
purpose: Captures one screenshot per acceptance criterion and renders an HTML proof report.
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

## The run

### 1. Capture, one AC at a time

For each AC, in order:

1. Say which AC is next and ask the user to put the app on the screen that
   proves it. Wait for their word.
2. Shoot it into the scratchpad as `ac-<n>.png`:

       ~/.claude/hooks/feanor-flutter-shot.sh <scratchpad>/ac-<n>.png [<deviceId>]
       ~/.claude/hooks/feanor-shot.sh <url> <scratchpad>/ac-<n>.png

   Run it bare so its permission entry matches. A non-zero exit is a failed
   capture: note the AC's `hint` (what the user must do for the shot to work)
   and go on to the next AC. Never retry silently, and never substitute another
   AC's image.
3. Read the image once to confirm it shows the screen the AC names. A shot of
   the wrong screen is a failed capture, not proof.

### 2. Render the report

Write a manifest to the scratchpad and render it:

    ~/.claude/hooks/ithildin-report.py <manifest.json>

Manifest fields are in the hook's docstring: `slug`, `title`, optional `lede`,
optional `video` and `videoHint`, and per AC `text`, `shot`, `hint` and optional
`at` and `notes`. The hook writes
`ithildin-<slug>.html` and copies the shots into an `ithildin-<slug>/` folder
beside it in `~/.skadi/henneth/`. An AC with no shot draws a dashed
missing-proof row carrying its hint, and the page opens with a count
(`2 of 3 captured`).

Print the URL — the port is in `~/.skadi/henneth/.henneth-port` (boot `/henneth`
first if it is absent): `http://localhost:<port>/ithildin-<slug>.html`.

### 3. Report

Lead with the tally. Name each AC that has no proof and why. Do not call the
work verified on the strength of this report: it holds pictures, not verdicts.

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

**Not yet built:** the recording itself. Nothing here starts or stops a screen
recording, or reads the start time of each AC off one. For now the user supplies
the `.mp4` and the `at` times. A recording hook for the iOS Simulator
(`xcrun simctl io booted recordVideo`) is the planned next layer; Android's
`screenrecord` stops at 3 minutes, which needs its own answer. Splitting the
recording into per-AC clips stays a possible later option: the `at` times are
what such a split would cut on.

## Notes

- **Shots and the video land in the report folder**, copied beside the page, so
  the page is self-contained and can be zipped and sent.
- **Re-running a slug clears its image folder** before copying, so a stale shot
  never outlives a failed re-capture.
- **Headless browser / Flutter requirements** are Fëanor's — see its *Notes*.
