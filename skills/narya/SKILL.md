---
name: narya
description: Use when the user runs /narya [start|reload|restart|status|stop|log], or asks in plain words to "hot reload", "reload the app", "push that change to the simulator", "restart the running app". Keeps a Flutter app alive on a booted emulator/simulator through a long-lived `flutter run --machine` daemon, so a source edit reaches the running app in about a second instead of a 60-90s rebuild — and without losing the screen you navigated to. Any caller may poke it: you in chat, /feanor between mends, /manwe before a shot. It never boots a device and never drives a tap; navigation stays yours.
purpose: Hot-reloads a running Flutter app on demand through a standing daemon.
user_invocable: true
---

# Narya — the Kindler

Narya keeps the flame alight. One `flutter run --machine` daemon stands behind a
named pipe; every later turn, session or skill writes one line into it and the
running app takes the change. The rebuild-install-launch cycle is paid once, at
`start`, and never again while the daemon lives.

The gain is not only the seconds. A relaunch drops the app at its first screen,
so every pass costs the navigation back to where the work is. A reload does not.

## Verbs

Every verb runs through one hook:

    ~/.claude/hooks/flutter-daemon.sh <verb> [flags]

| Verb | What it does |
|---|---|
| `start` | Builds, installs, launches, and leaves the daemon standing. Pays the full build once. |
| `reload` | Hot reload — Dart source only. Under a second. This is the bare `/narya` default. |
| `restart` | Hot restart — re-runs `main()`, loses app state, keeps the daemon and the binary. |
| `status` | Is the flame alive, against which device, with which appId. |
| `stop` | Closes the pipe, reaps the daemon, clears the state. |
| `log` | The daemon's own transcript — where a failed build explains itself. |

Flags: `--project <dir>` (default: the nearest ancestor of the cwd bearing a
`pubspec.yaml`), and on `start` also `-d <device>`, `--flavor <f>`, `-t <entry>`,
`--timeout <s>`, and anything after `--` passed to `flutter run` verbatim.

One daemon per project directory, so a bare `/narya reload` from anywhere inside
the tree finds its own.

## Choosing the verb — the judgment the hook cannot make

Read the edit you just made, then pick:

- **`reload`** — a widget's build method, a style, a string, a pure function body.
  Nearly every UI mend is this.
- **`restart`** — `main()` itself, a top-level or `static` initializer, an enum's
  shape, a global's default, a provider registered at startup, a `const` the tree
  bakes in. Hot reload will report success and change nothing.
- **A real rebuild** (`stop`, then `start`) — native code, a platform channel,
  `pubspec.yaml` dependencies, assets or fonts newly declared, anything under
  `ios/` or `android/`. The daemon holds a binary that no longer matches the source.

When in doubt, reach for `restart`: a second of lost app state is cheaper than
comparing a screenshot against a stale binary and calling it aligned.

## Starting it

`start` needs a booted device — Narya boots none. Ask for one if none is up, and
name the device when more than one is attached (`flutter devices` lists them):

    ~/.claude/hooks/flutter-daemon.sh start -d <device-id> --flavor <f> -t lib/main_<f>.dart -- --debug

The first build is the slow one; report the wait plainly rather than letting it
look like a hang. If it outlasts `--timeout` the daemon is left standing, and a
later `status` picks the app up once it starts.

## Reading the outcome

The exit code is the contract; a caller's loop branches on it, not on the prose.

| Code | Meaning | What to do |
|---|---|---|
| 0 | done | Carry on — the running app now matches the source. |
| 1 | the state directory or its pipe could not be laid down | A filesystem fault; read the message. |
| 2 | bad arguments | Fix the call. |
| 3 | flutter not found | Neither `flutter` nor `fvm` is on PATH. |
| 4 | no daemon for this project | `start` one, or name the project with `--project`. |
| 5 | the daemon cannot be reached | It died (a simulator reboot, a force-quit), or it lives with nothing reading its pipe. **`stop`, then `start`** — `start` alone would find a wedged daemon alive and do nothing. |
| 6 | alive, but the app has not started | Still building — read `log`, then `status`. |
| 7 | the reload failed or went unanswered | **The app is stale.** Never compare a render against it; read `log`, mend, and reload again — or `restart`. |

A `7` matters most. A reload that fails silently is worse than a slow rebuild,
because everything downstream then weighs a screenshot of the old binary.

## What Narya does not do

- **It boots no device.** The emulator or simulator is yours to raise.
- **It drives no tap.** Navigation is yours; the reload holds the screen you are
  already on, which is the whole point.
- **It survives the session, not the device.** A simulator reboot or a force-quit
  leaves a corpse; `status` names it rather than letting a reload poke at nothing.
