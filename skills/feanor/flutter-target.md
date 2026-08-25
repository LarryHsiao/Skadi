# Targeting Flutter

Read this before your first pass whenever `<target>` is a **Flutter app**
already running on a booted emulator/simulator, rather than a browser-loadable
URL. It has no bearing on a web target — skip it there.

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
