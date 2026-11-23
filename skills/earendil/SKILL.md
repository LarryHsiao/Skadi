---
name: earendil
description: Use when the user runs /earendil [android|ios] [--no-flutter] [--no-commands], or asks in plain words for a "pre-flight check", "release readiness", "is the build config healthy", "check my signing and obfuscation", "will this Android/iOS build ship". Inspects a Flutter project (both android/ and ios/), or a native Android or native iOS project, and reports build identity, version, release signing, shrinking/obfuscation, services files, toolchain and dependency health as one table ending in PASS or HOLD. Read-only — it never builds, signs or edits anything. The platform comes from the argument, else from which directories exist.
purpose: Pre-flight check of a mobile project's build config and health, ending in PASS or HOLD.
user_invocable: true
args: "[android|ios] [--no-flutter] [--no-commands]"
stage: merge
---

# Earendil — the pre-flight check

Earendil sets sail only when the ship is ready. One run reads the project's
build configuration, reports what would break or embarrass a release, and
ends in `PASS` or `HOLD`. It reads; it does not fix. `/publish-flutter` builds
the archives afterwards.

## Run

```bash
~/.claude/hooks/earendil.py [android|ios] [--no-flutter] [--no-commands]
```

The hook works from the current directory and walks up to the nearest project
root, so it may be run from `lib/`, `android/` or any subfolder. A Flutter root
wins over a native folder inside it, so a run from `android/` still reports the
whole Flutter project. Show its report as printed;
do not re-draw the table. Then, verdict first, say in one or two lines what
holds the release back and which row to open first.

| Argument | Effect |
|---|---|
| `android` / `ios` | Only that platform. Refused (exit 2) when its directory is absent. |
| `--no-flutter` | Skip the `FLUTTER` block (the shared, project-wide rows). |
| `--no-commands` | Files only: skip `flutter doctor`, `flutter pub get --dry-run`, `java`, `security`, `xcodebuild`, `pod`. Use offline, or when speed matters. |

With commands on, a run takes about 15 seconds (`flutter doctor -v` is most of
it). Exit status: `0` PASS, `1` HOLD, `2` not a mobile project or platform absent.

## What it detects

| Root contains | Kind | Blocks |
|---|---|---|
| `pubspec.yaml` with `sdk: flutter` | Flutter | `FLUTTER`, `ANDROID` (`android/`), `IOS` (`ios/`) |
| `settings.gradle(.kts)` | native Android | `ANDROID` |
| `*.xcodeproj` / `*.xcworkspace` | native iOS | `IOS` |

A Flutter project missing one platform directory shows that block as `n/a`,
not as a failure. Nothing detected → exit 2 with a plain message.

## Reading the report

`✅` pass · `⚠️` warn (the build runs, but look) · `🚫` fail (holds the release) ·
`➖` not applicable (not counted). One `🚫` anywhere gives `HOLD`; warnings alone
give `PASS`. A `file:line` under a row is where to open first. A `🚫` is raised
only when the project's files plainly state the fault; a value an `.xcconfig`, a
convention plugin or CI might supply reads `⚠️`, because a false hold stops a
healthy release.

| Block | Rows |
|---|---|
| `FLUTTER` | `sdk` (Flutter/Dart vs `environment:`, FVM pin) · `version` (`x.y.z+n`, build above the last tag) · `deps` (lock, `pub get --dry-run`, git/path deps) · `assets` · `codegen` (`*.g.dart`, `l10n`) · `entry` (`lib/main*.dart`, env files named in build scripts) · `obfuscate` · `doctor` |
| `ANDROID` | `identity` · `sdk` · `version` · `release` (not signed with the debug key) · `key` (key.properties complete — property names are read from the signing block — and keystore exists) · `secrets` (not tracked or unignored) · `minify` (R8, rules file) · `symbols` · `services` (google-services.json package) · `toolchain` (AGP / Gradle / JDK) · `plugins` (plugin minSdk floor) · `doctor` |
| `IOS` | `identity` · `version` · `signing` · `keychain` · `profile` (manual signing: installed, not expired) · `export` · `services` (GoogleService-Info.plist) · `toolchain` · `pods` · `plist` (usage strings for camera, mic, … — a `⚠️`, since they matter only if the app calls that API) · `strip` · `doctor` |

## What it cannot see

Say these when they bear on the answer, rather than reporting a clean row as proof.

- **Gradle is read as text, not run.** A value computed in a script, or set per
  flavor, reads as unknown. `.xcconfig` build settings are not read either.
- **Obfuscation is a heuristic.** `--obfuscate` lives in the build command, so the
  row searches `Makefile`, CI files, `fastlane/` and `scripts/`. `⚠️` means
  "not found there", not "absent" — a flag typed by hand is invisible.
- **R8 default is unverified.** An unset `isMinifyEnabled` warns and says so.
- **JDK:** in a Flutter project it is the JDK `flutter doctor -v` reports (the one
  Flutter builds with, which may differ from `PATH`'s `java`), and a shortfall is a
  `🚫`. In a native project it is `JAVA_HOME`, then `PATH`, and a shortfall is only
  a `⚠️`, because Android Studio may build with its own JDK.
- **Signing in Gradle is matched by pattern.** `signingConfigs.<name>` references in
  the release build type are collected; a fallback to the debug key is a `⚠️`, the
  debug key alone a `🚫`, and a release type that names no config reads `⚠️`.
- **Signing secrets are never printed.** `key.properties` is checked for presence
  of its four keys only. Keystore certificate expiry is not checked (it needs the
  store password). iOS profile expiry is read for manual signing only.
- **AGP table:** the AGP→Gradle minimums are from the Android developer site as of
  2026-11-23 (`hooks/earendil_android.py`). A newer AGP reads `n/a`; refresh the
  table from [about-agp](https://developer.android.com/build/releases/about-agp).
- **Keychain, profile and Xcode rows are macOS only;** elsewhere they read `n/a`.
  The hook is untested on Windows: verify with `py hooks\earendil.py --no-commands`
  from a Flutter project root.
- **Multiple app targets** (extensions): iOS settings come from the first non-test
  app target's Release configuration.

## Judgment

- A `🚫` on `services` (package or bundle id mismatch) is the common cause of a
  release that builds and then crashes on Firebase init; fix it before anything else.
- `release` signed with the debug key is a hold even when the build succeeds: the
  Play Store rejects it.
- `⚠️` on `obfuscate` or `minify` is a policy choice for some apps. Report it; do
  not offer to "fix" it unasked.
- To change anything it found, edit the named file in the project, then re-run
  `/earendil`. This skill makes no edits and sends nothing.
