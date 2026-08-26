# Targeting Flutter

Read this before your first pass whenever `<target>` is a **Flutter app**
already running on a booted emulator/simulator, rather than a browser-loadable
URL. It has no bearing on a web target — skip it there.

The loop is the same — render, compare, mend — but the render is a screenshot of a
**running** app, so the mend must reach that running app before the next shot.
The honest division of hands:

- **You** — boot the emulator/simulator and navigate to the target screen. Both
  are yours; Fëanor raises no device and drives no tap.
- **Fëanor** — starts the reload daemon if none stands, shoots the device
  (`feanor-flutter-shot.sh`), names the deltas against the app content region
  (ignoring the OS status/nav bars in the shot), edits the Dart, **reloads through
  the daemon itself**, and shoots again.

## The daemon between passes

`~/.claude/hooks/flutter-daemon.sh` (the `/narya` skill) holds a
`flutter run --machine` session behind a named pipe, so a mend reaches the device
in about a second and the screen you navigated to is kept. Start it once, before
the first pass:

    ~/.claude/hooks/flutter-daemon.sh status || \
      ~/.claude/hooks/flutter-daemon.sh start -d <device-id>

Then, in place of the old prompt-and-wait, close each mend with:

    ~/.claude/hooks/flutter-daemon.sh reload

**Read its exit code before shooting.** `0` means the running app now matches the
source. Anything else means it does not:

- `7` — the reload failed or went unanswered. **Do not shoot.** A screenshot of a
  stale binary reads as a mend that did nothing, and the next pass will chase a
  delta it has already closed. Read `log`, then reload again or `restart`.
- `5` — the daemon cannot be reached: it died (a simulator reboot, a force-quit),
  or it lives with nothing reading its pipe. `stop`, then `start` — `start` alone
  would find a wedged daemon alive and do nothing. The app comes back at its first
  screen either way, so navigation is owed.
- `6` — still building. Wait and re-check rather than shooting.

## When a reload will not carry the mend

Hot reload covers Dart source only. Reach for `restart` when the mend touched
`main()`, a top-level or `static` initializer, an enum's shape, or a global's
default — and for a genuine rebuild (`stop`, then `start`) when it touched native
code, `pubspec.yaml`, or newly declared assets and fonts. Both lose the screen,
so say so plainly and ask for the navigation back before the next shot.

The failure to guard against is not the slow one: it is a reload that reports
success while the binary the eye weighs is the old one.

## Without the daemon

If no daemon stands and one cannot be started — you are driving `flutter run`
from your own terminal, or an IDE holds the session — the loop falls back to what
it was: after each mend, prompt for the hot reload and the navigation back, then
shoot. Say which mode you are in at the first pass, so the wait is expected
rather than mistaken for a hang.

When more than one device is attached, name its id — both hooks take it.
