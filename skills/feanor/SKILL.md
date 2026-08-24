---
name: feanor
description: Use when the user wants to align a web page to a visual reference — whether phrased as /feanor <target> <spec> [--max N] [--viewport WxH], or in plain words such as "make this page match the mockup", "align this to the design", "get the page to look like this screenshot". Both a target page and a reference image must be in hand. Aligns a web page to a visual spec by an automatic render→compare→mend loop. <target> is the page being mended (a served http(s):// URL — a dev server or Henneth-served page — that renders from source in the working tree); <spec> is the ideal to match (a PNG, or an HTML page rendered to one). Each pass shoots the target to a PNG via headless Chrome/Edge, reads it beside the spec, names the visual deltas, and edits the source to close them. Exits early when aligned or when progress stalls; a hard --max (default 3) is the backstop, and hitting it fails loud with the remaining gaps. Renders into the Henneth window so convergence is watchable. Targets a web page (headless Chrome/Edge) or a Flutter app already running on a booted emulator/simulator — captured via feanor-flutter-shot, never auto-launched: you boot and navigate, it shoots and mends.
purpose: Aligns a web page or app view to a visual reference through an automatic screenshot-compare-and-edit loop.
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

**Vision alone cannot be trusted on a same-hue-family color regression.** A
holistic side-by-side read reliably catches a wrong hue (orange where the spec
is blue) but not a wrong *shade* within the same family — `warning.dark`
(#E65100) standing in for `warning.main` (#ED6C02) reads as "the right orange"
at a glance, especially on a small element (an icon, a status dot) where the
eye has little area to judge against. Worse, sibling elements that share a
color *family* — an icon, its label text, a button — do not necessarily share
the same design-token *variant*: one real case used three distinct tokens
(`warning.main` for the icon, `warning.main160Percent` for the text and
button) that all read as "the same orange" on sight. Whenever an element
carries real semantic or status color weight — not decorative color — sample
it, do not just look at it:

    ~/.claude/hooks/feanor-sample-color.sh "<pass-or-spec.png>" <x> <y> <w> <h>

returns the region's most-saturated pixel as `#RRGGBB R,G,B` — the pixel that
carries the region's real color, past whatever background or anti-aliasing
surrounds it. Sample each semantically-colored element **independently**
(icon, text, button — never assume a sibling shares its neighbour's sample),
against both the spec and the pass, and compare hex values directly rather
than trusting that "same family" means "same token."

**The full-resolution, un-resized, un-fuzzed side-by-side read is the primary
check, every pass — never a fallback.** A resize-to-match-frame-plus-fuzz pixel
score (e.g. `magick compare -fuzz 10%`) blurs a real structural rearrangement —
a 2-column grid collapsed to 1, a field twice the spec's width, a label moved from
inline to above its box — into a diff that looks small in aggregate; the metric
cannot tell "blurry anti-aliasing" from "an entire section rearranged" when both
read as a similar overall color distribution. Any such score, if computed at all,
is a **secondary sanity signal only** — it is never sufficient on its own to
declare `ALIGNED`. And do not carry a prior pass's "accepted cause" explanation
for a diff region forward onto a new pass's diff in that same region without
re-deriving it fresh — reusing a stale explanation is how a real regression
keeps getting waved through as "the same known gap."

**A screen is more than its loudest region — take a named inventory of every
top-level region before naming a single delta, and give each region its own
line.** The holistic read is honest about what it saw and silent about what it
never looked at: when one region carries a structurally obvious gap — a pane
that does not fill its width, a section rendered in the wrong place — attention
settles there, the delta list fills with what that region owes, and the quiet
regions are discharged by silence rather than by inspection. One real case lost
an 8pt top padding on a list's first item for exactly that reason, beside a pane
that was visibly failing to fill the screen; it surfaced only when a human asked
twice whether the list had been looked at. Before ordering deltas by how much
they move the eye, name the regions as the layout itself divides them — an app
bar, a left list, a hero card, a history row — and write a line per region
against **both** images, even where that line reads "matches". A region bearing
no line was not checked. Where a region's suspected delta is one of spacing or
proportion the eye is at its weakest, so cut the region out of both images and
measure it rather than looking harder:

    ~/.claude/hooks/feanor-crop.sh "<pass-or-spec.png>" <x> <y> <w> <h> "<out.png>"

writes the region to its own PNG. Read at full resolution, a gap the whole-screen
view rendered as a few pixels becomes a proportion statable as a number — measure
it as a fraction of a stable parent in both images, per the compare step's
proportion rule below (one such case measured the spec's padding at 18% of the
item's height against the build's 7%).

## The loop

### 0. Resolve the spec image once

If `<spec>` is a PNG, it is the spec image — copy it into the Henneth folder
(`$HOME/.skadi/henneth/`) as `feanor-spec.png` so it stands in the window
beside each pass. If `<spec>` is an HTML page or URL, shoot it once into that folder
at the chosen viewport:

    ~/.claude/hooks/feanor-shot.sh "<spec-url>" \
      "$HOME/.skadi/henneth/feanor-spec.png" "<WxH>"

Read `feanor-spec.png`; this is the fixed light every pass measures against.

### 1..max — render, compare, mend

For each pass `n` (1 to `--max`):

1. **Render the target.** Shoot `<target>` to the Henneth folder as
   `feanor-pass-<n>.png` (`feanor-pass-1.png` on the first pass, and so on):

       ~/.claude/hooks/feanor-shot.sh "<target-url>" \
         "$HOME/.skadi/henneth/feanor-pass-<n>.png" "<WxH>"

   If the hook exits non-zero, **stop and fail loud** — there is no image to align
   to, and three blind passes are worse than none.

   For a **Flutter** target, shoot the running device instead of a URL (the viewport
   is the device's, so `--viewport` does not apply):

       ~/.claude/hooks/feanor-flutter-shot.sh \
         "$HOME/.skadi/henneth/feanor-pass-<n>.png" [<deviceId>]

   The shot includes the OS status/nav bars — name deltas against the **app content
   region**, not the system chrome.

2. **Compare.** Read the spec image and `feanor-pass-<n>.png`, full resolution,
   un-resized, un-fuzzed, side by side. Name the visual deltas as a concrete
   checklist — colour, layout, proportion, spacing, presence of elements,
   typography. Order them by how much they move the eye.

   - **Sample a region's boundary, not only its interior.** When checking a
     region's fill or shape, also sample near its true edge — the screen edge, or
     the edge of its stated container (e.g. pixels at `x=2`, `x=max-2`, `y=max-2`)
     — in addition to a point well inside it. A color-correct interior does not
     imply a color-correct or shape-correct edge: an inset card with rounded
     corners and an edge-to-edge flush rectangle can sample identically at their
     centers and only diverge at the boundary (a border, an inset margin, a
     rounding radius).
   - **When the spec comes from a design tool with an MCP, cross-check structure
     there before trusting the screenshot alone.** For suspected structural
     differences — insets, margins, container shape, sizing — prefer a
     structured-layout read (e.g. Figma's `get_design_context`, which returns the
     node tree with its actual layout classes/values, such as a wrapper carrying
     `pb-[8px] px-[8px]` around a child with `rounded-[8px]`) over `get_metadata`
     or the screenshot alone. Insets, margins, and rounding are stated there as
     explicit values — exactly what a screenshot glance or a bare geometry dump
     both under-report.
   - **For any composite region with multiple independently-styled
     children — an app-bar's slots, a banner's icon+text+button, a row of
     icon buttons, a tab bar — enumerate each child by name rather than
     trusting a holistic read.** A fixed small set of parts sharing one
     region or one visual theme is exactly where a side-by-side read misses
     one — attention gets captured by whichever delta is most salient
     elsewhere on the screen, and a small, spatially separate or
     visually-similar part (a corner icon, a banner's reminder text) never
     earns its own forced look. "Check for missing elements" as a general
     instruction is not enough — proven insufficient by exactly this kind of
     miss, twice over: once for a toolbar's slots, again for a status
     banner's icon/text/button trio, where even a corrective pass sampled
     only the icon and wrongly assumed the text and button shared its color.
     List what occupies each named child in both images, independently of
     whatever delta already dominated the pass — and when the children carry
     semantic color, sample each one per the pixel-sampling rule above rather
     than assuming siblings match.
   - **When a rendered element's source carries an explicit numeric size
     constraint — a `minimumSize`, a literal width or height, a hardcoded
     padding value — that is not obviously derived from the design system's
     spacing scale, verify its actual proportion, not just its screenshot
     appearance.** A screenshot comparison can pass — colour, structure,
     presence all read correct — while a magic number silently distorts one
     element's scale: a button forced 36% wider than its icon-and-text content
     needed (`minimumSize: Size(212, 36)`) still reads as "a button in the
     right place" at a glance. Measure the element's width or height as a
     **fraction of a stable parent** — a card, a row, the screen edge — in both
     spec and build, since absolute pixels do not compare meaningfully across
     differently scaled reference images. Flag a roughly >20% relative
     divergence between the two fractions as worth a second look — that gap is
     the signal a magic number was eyeballed rather than measured when the
     widget was first built.

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

## Beyond the pixel — what ALIGNED does not prove

`ALIGNED` means the reflection matches; it does not mean the task is done. Two
failure modes sit outside anything a screenshot can show, and both surface only
once the loop is embedded in a larger, scoped change (e.g. "fix this one screen's
offline mode" touching shared widgets):

- **A scope-gated edit leaking into an unscoped sibling.** When a mend is meant to
  fire only under some condition (an `isOfflineMode` branch, a feature flag) but
  the edit lands in a shared, const-constructed, or otherwise unconditional
  widget, the change silently reaches screens the task never named — and the
  before/after screenshots of the *target* screen still read `ALIGNED`, because
  the leak is invisible from there. Before declaring the surrounding task done,
  grep the diff for the task's scope-gating condition and confirm every touched
  file that could leak actually gates on it.
- **A structural move breaking a test that located the old structure.** Relocating
  or restructuring a widget (out of an `AppBar` into the body, a re-parented
  grid) can silently break a test that found it by ancestry or position (e.g.
  `find.descendant(of: find.byType(AppBar), matching: find.byType(TextField))`)
  rather than by a stable key — and no visual check will ever catch it. Run any
  test file whose target widget's structure changed, not just a static-analysis
  pass, before calling the surrounding task done.

Fëanor itself stays scoped to visual alignment — these checks belong to whatever
task wraps the Fëanor loop, and its own Compliance Review step (where the
project runs one) is the natural place they land. Naming them here is a
reminder, not a mandate for Fëanor to run them itself.

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
- **ImageMagick required for pixel sampling and region crops.**
  `feanor-sample-color.sh` and `feanor-crop.sh` both need `magick` (or the legacy
  `convert`) on PATH. Absent both, set `FEANOR_MAGICK` to a binary, or each fails
  loud rather than returning a guessed colour or an empty crop.
- **Perceptual, not pixel-perfect.** Vision closes layout, proportion, and presence
  reliably, and colour too *across* hue families (orange vs. blue); it cannot
  reliably *see* a 2px gap, and it cannot reliably catch a same-hue-family shade
  regression (a `.dark` token standing in for `.main`) or a sibling that quietly
  carries a different token variant of the same family — see the oracle section's
  pixel-sampling rule above for what closes the colour gap, and its
  region-inventory rule for what closes the spacing one (crop the region out and
  measure a proportion, rather than asking the eye to judge a few pixels). The
  loop converges to *the eye's match*, which for a mockup is the true target —
  but do not expect a ruler-exact result.
- **The cap fails loud, alignment does not.** A `CAP` exit always names what remains;
  an `ALIGNED` exit owes nothing. The verdict always carries its why.
- **Flutter never auto-launches.** The Flutter adapter only *captures* a device you
  have already booted and navigated — it never starts or kills one. Absent a booted
  device it fails loud (boot one yourself) rather than aligning to nothing.
