# Flutter Style Guide

## Tooling

- Always use `fvm` for the Flutter SDK. Run commands as `fvm flutter <cmd>` so they target the project's pinned SDK version.

## Running the App

The assistant must **not** launch the app itself. A `flutter run` started from the assistant is a dead session: its stdin is unreachable, so no hot reload (`r`) or hot restart (`R`) can ever be sent — every code change would demand a full relaunch. Worse, each launch reinstalls and restarts the app on the device, trampling whatever session the user has open mid-test.

The same hands-off rule covers the emulator and every process around it. The user boots and owns the emulator; the assistant must **never** kill it, nor `adb`, nor the running app, nor any `dart`/`flutter` process the user started — an unbidden kill tramples the user's live session and hot-reload state. Launch and kill alike happen only at the user's explicit ask.

What the assistant does instead:

- **Ask the user to run it**, handing them the exact command — e.g. `fvm flutter run -d <device-id>` (device ids via `fvm flutter devices`). The user's own terminal holds the stdin; hot reload stays in their hands.
- **Arm a passive log watcher** — that is the assistant's whole share of the run. `adb logcat` filtered to the failure signatures (Crashlytics banners, exceptions, the widget under suspicion) reads without touching; it works regardless of who launched the app and survives the user's restarts.

The division of labour is plain: the user drives the app and the emulator; the assistant watches the log and reads the wreckage.

## Dependencies

- When the user asks to "update" a dependency that is pinned to a source reference (git branch, tag, commit, or path) rather than a semver version, the version string won't change — the underlying ref will. Run `dart pub upgrade <package>` (prefix with `fvm` if the project uses FVM) so pub fetches the latest commit on that ref instead of reusing the cached one. Example: a library the project references via `master` adds a new commit — `pub get` alone will keep the cached commit; `pub upgrade <package>` pulls the new one.

## Code Generation

- When editing a class marked `@freezed` — or any class whose companion files come from `build_runner` (`.freezed.dart`, `.g.dart`, `.gr.dart`, and the like) — never hand-edit the generated file or have the assistant rewrite it. Run the build itself: `fvm dart run build_runner build --delete-conflicting-outputs` (or `watch` during active work). The generator's output is the source of truth; an AI-stitched substitute drifts in shape — copyWith signatures, `fromJson` dispatch, union helpers — and the next legitimate build overwrites it, silently undoing the patch.

## Main-Thread Discipline

The UI thread paints frames every 16 ms. Any work that holds it past that mark drops a frame, and the user sees it. Two rules decide where work belongs.

- **IO is `async`; CPU is `Isolate`.** For IO-bound work — network calls, disk reads, sqlite queries — `async`/`await` suffices. Dart yields the event loop at every `await`, so the UI keeps painting while the IO is in flight. For CPU-bound work — parsing a large JSON map, decoding an image, crypto, transforming a long list — `async` does **not** save you. An `async` function running a tight loop still pins the main isolate. Lift such work onto another isolate via `compute()` for one-shot jobs, or `Isolate.spawn` for long-lived workers.

  ```dart
  // Wrong — parse runs on the UI isolate, blocks the frame.
  final users = (jsonDecode(body) as List).map(JsonUser.new).toList();

  // Right — parse runs on a worker isolate, UI keeps painting.
  final users = await compute(_parseUsers, body);

  List<User> _parseUsers(String body) =>
      (jsonDecode(body) as List).map(JsonUser.new).toList();
  ```

  The threshold is empirical: if a profile-mode run shows a frame drop on the work, it was CPU work that should have been off-thread. When in doubt, measure with the DevTools timeline before deciding.

- **State management does not absolve blocking.** Riverpod's `FutureProvider` / `AsyncValue`, flutter_bloc's `Cubit` / `Bloc`, raw `StreamBuilder` — these are *presentation* conventions for displaying an in-flight async value without manual `setState` plumbing. They do not move work off the main thread. A `FutureProvider` whose body parses a 5 MB payload on the main isolate blocks just as hard as a bare `setState` would. The off-thread decision is upstream of the observer pattern, not absorbed by it.

## Routing

Before any routing change — adding a route, listening to the current path, popping to a named root, wiring a deep link — read the project's routing setup first. The router (`go_router`, `auto_route`, `Navigator 2.0`, or whatever the project stands on) carries the conventions for path matching, guards, and nested shells; touching navigation without that grounding ends in duplication.

The common slip: a nested `Navigator` raised inside a page to handle in-page transitions when the router already exposes a nested route, a shell, or `StatefulShellRoute`. The private navigator carries its own stack, its own back behaviour, its own URL detachment — and the page that bore it gains nothing the router did not already offer.

A second slip: a page that listens for the current path by string-matching a hardcoded literal — `if (location == '/home/settings')`, `if (uri.path.startsWith('/cart'))`. The literal binds the page to one mount point; move the route under a parent, rename a segment, or reuse the page elsewhere, and the listener falls silent — no warning, just dead behaviour. Read the page's own route from the router's context (`GoRouterState.of(context).matchedLocation`, `context.routeData`, or the equivalent the project stands on), or watch for the change you care about, not the path that happens to carry it.

When the router already supports the shape, lean on it; when it does not, extend the router rather than forking a private navigator inside a page.
