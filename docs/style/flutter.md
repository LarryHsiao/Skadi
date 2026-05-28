# Flutter Style Guide

## Tooling

- Always use `fvm` for the Flutter SDK. Run commands as `fvm flutter <cmd>` so they target the project's pinned SDK version.

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

When the router already supports the shape, lean on it; when it does not, extend the router rather than forking a private navigator inside a page.
