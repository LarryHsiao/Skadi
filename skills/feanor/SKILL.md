---
name: feanor
description: Use when the user wants to align a web page to a visual reference — whether phrased as /feanor <target> <spec> [--max N] [--viewport WxH], or in plain words such as "make this page match the mockup", "align this to the design", "get the page to look like this screenshot". Both a target page and a reference image must be in hand. Aligns a web page to a visual spec by an automatic render→compare→mend loop. <target> is the page being mended (a served http(s):// URL — a dev server or Henneth-served page — that renders from source in the working tree); <spec> is the ideal to match (a PNG, or an HTML page rendered to one). Each pass shoots the target to a PNG via headless Chrome/Edge, reads it beside the spec, names the visual deltas, and edits the source to close them. Exits early when aligned or when progress stalls; a hard --max (default 3) is the backstop, and hitting it fails loud with the remaining gaps. Renders into the Henneth window so convergence is watchable. Targets a web page (headless Chrome/Edge) or a Flutter app already running on a booted emulator/simulator — captured via feanor-flutter-shot, never auto-launched: you boot and navigate, it shoots and mends.
user_invocable: true
---

# Fëanor

Who caught the light of the Trees in the Silmarils. This skill catches a visual
spec in a built page — rendering the page, holding it beside the ideal, naming the
gap, and mending it, pass after pass, until the reflection matches the light or the
passes run out.

The loop is the whole point: the work that a user once drove by hand — *look,
adjust, look again* — Fëanor drives itself, with the eye that judges and the hand
that mends both Claude's, and a hard cap so it never runs away.

## What it needs

- **`<target>`** — the page being mended, as a **browser-loadable URL**. A running
  dev server (`http://localhost:5173/...` for React/Vite), a Henneth-served page, or
  a `file://` URL for a trivially-static page. The URL is only how the page is
  *rendered*; the source Fëanor *edits* is the project tree in the working directory
  that produces that page. Fëanor must know which source files back the page — infer
  from the route, or ask once.
- **`<target>` — Flutter** — alternatively, a **Flutter app already running** on a
  booted emulator/simulator. **You** boot the device and navigate to the target
  screen; Fëanor captures it with `feanor-flutter-shot.sh` and **never launches a
  device**. The source it edits is the Dart in the working tree that builds that
  screen. (See *Targeting Flutter* below for the per-pass dance.)
- **`<spec>`** — the ideal to align to. A **PNG** (used as-is) or an **HTML page /
  URL** (shot to a PNG first, via the same hook).
- **`--max N`** — the hard cap on passes. Default **3**. The cap is a backstop, not
  a target (see *The loop*).
- **`--viewport WxH`** — the shot viewport, default `1280x800`. For tight alignment,
  pass the spec image's own pixel size so target and spec are shot at one scale.

## The oracle

The comparison is **Claude's own sight**, not a pixel diff. A pixel diff is brittle
— a one-pixel shift or a font hinted differently screams *mismatch* where the eye
sees none — and worse, a number says only *how far*, never *which way*. Reading the
two images names **actionable deltas** — *"the header band is too tall, the accent
runs orange where the spec is amber, the card gutters are wider"* — and each delta
maps to an edit. That is what lets the loop converge instead of flail.

## The loop

### 0. Resolve the spec image once

If `<spec>` is a PNG, it is the spec image — copy it into the Henneth folder
(`$HOME/.claude/previews/henneth/`) as `feanor-spec.png` so it stands in the window
beside each pass. If `<spec>` is an HTML page or URL, shoot it once into that folder
at the chosen viewport:

    ~/.claude/hooks/feanor-shot.sh "<spec-url>" \
      "$HOME/.claude/previews/henneth/feanor-spec.png" "<WxH>"

Read `feanor-spec.png`; this is the fixed light every pass measures against.

### 1..max — render, compare, mend

For each pass `n` (1 to `--max`):

1. **Render the target.** Shoot `<target>` to the Henneth folder as
   `feanor-pass-<n>.png` (`feanor-pass-1.png` on the first pass, and so on):

       ~/.claude/hooks/feanor-shot.sh "<target-url>" \
         "$HOME/.claude/previews/henneth/feanor-pass-<n>.png" "<WxH>"

   If the hook exits non-zero, **stop and fail loud** — there is no image to align
   to, and three blind passes are worse than none.

   For a **Flutter** target, shoot the running device instead of a URL (the viewport
   is the device's, so `--viewport` does not apply):

       ~/.claude/hooks/feanor-flutter-shot.sh \
         "$HOME/.claude/previews/henneth/feanor-pass-<n>.png" [<deviceId>]

   The shot includes the OS status/nav bars — name deltas against the **app content
   region**, not the system chrome.

2. **Compare.** Read the spec image and `feanor-pass-<n>.png`. Name the visual
   deltas as a concrete checklist — colour, layout, proportion, spacing, presence of
   elements, typography. Order them by how much they move the eye.

3. **Decide the exit** (before any edit):
   - **Aligned** — no material deltas remain. Stop; report `ALIGNED` and the pass
     count.
   - **Stalled** — compare this pass's delta checklist against pass `n-1`'s (keep
     each pass's list in working context). Stalled when the count did **not** drop
     *and* no listed delta materially closed — the same gaps remain, or an edit
     merely traded one for another. More passes will not help. Stop; report
     `STALLED` with the standing deltas. (Pass 1 has no prior list, so it can only
     be ALIGNED or continue.)
   - else **continue** to the edit.

4. **Mend.** Edit the target's **source** in the working tree to close the named
   deltas — nothing more (no drive-by refactors; this is a surgical loop). Keep a
   short record, in your working context, of what each pass changed and why, so pass
   `n` does not undo pass `n-1`.

5. Let the rebuild reach the rendered surface before the next pass shoots it:
   - **Web** — a static `file://` page is already written (no wait); a dev server
     hot-reloads (a few seconds — if the next shot still shows the pre-edit state,
     wait briefly and re-shoot). Settle time is tunable via `FEANOR_SETTLE_MS`.
   - **Flutter** — the running app must pick up the Dart change by **hot reload**
     (your IDE on save, or `r` in your `flutter run`), and the device must be back
     on the target screen. Fëanor does not drive your `flutter run` session — so
     after the mend, prompt for the reload + navigate, then shoot. (See
     *Targeting Flutter*.)

### Exit

Report the verdict and **why** it stopped, never a bare "done":

- `ALIGNED` (pass k of N) — the reflection matches; list nothing owed.
- `STALLED` (pass k of N) — name the deltas that would not close, so the user knows
  what the eye cannot mend automatically (often sub-pixel precision the oracle
  cannot perceive).
- `CAP` (N of N, still closing) — **fail loud**: the passes ran out while progress
  was still being made. List the remaining deltas and suggest re-running with a
  higher `--max`.

## Watching it converge

Every shot lands in the Henneth window — `feanor-spec.png` and each
`feanor-pass-<n>.png` — so the spec and the passes sit side by side, newest first.
If Henneth is not running, hint the user to boot it with `/henneth`; the shots are
written all the same, and the loop never blocks on the window.

## Targeting Flutter

The loop is the same — render, compare, mend — but the render is a screenshot of a
**running** app, and the rebuild leans on your session, since Fëanor will neither
launch nor drive your device. The honest division of hands:

- **You** — boot the emulator/simulator, run the app (`flutter run` or your IDE), and
  navigate to the target screen. Keep hot-reload-on-save on where you can; it makes
  the loop nearly seamless.
- **Fëanor** — shoots the device (`feanor-flutter-shot.sh`), names the deltas against
  the app content region (ignoring the OS status/nav bars in the shot), edits the
  Dart, then asks you to hot-reload and return to the screen before the next shot.

So the Flutter loop is *true-but-attended*: faithful to the real device, but the
reload and navigation are yours between passes. When more than one device is
attached, name its id — the shot hook's optional second argument.

## Notes

- **Headless browser required.** The shot hook needs Chrome or Edge (Edge ships on
  Windows; Chrome on macOS). Absent both, set `FEANOR_BROWSER` to a binary, or the
  loop fails loud at the first render rather than aligning to a blank.
- **Perceptual, not pixel-perfect.** Vision closes colour, layout, proportion, and
  presence reliably; it cannot reliably *see* a 2px gap. The loop converges to *the
  eye's match*, which for a mockup is the true target — but do not expect a
  ruler-exact result.
- **The cap fails loud, alignment does not.** A `CAP` exit always names what remains;
  an `ALIGNED` exit owes nothing. The verdict always carries its why.
- **Flutter never auto-launches.** The Flutter adapter only *captures* a device you
  have already booted and navigated — it never starts or kills one. Absent a booted
  device it fails loud (boot one yourself) rather than aligning to nothing.
