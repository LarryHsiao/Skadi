---
name: publish
description: Build Flutter release archives for selected platforms and collect into build/publish/. macOS builds are signed (Developer ID) and notarized via Apple's notary service. Use /publish [platform...] to build. Default platforms: android ios.
user_invocable: true
args: "[platform...]"
---

# Build Flutter Release Archives

Builds Flutter release archives for one or more platforms and collects them into `build/publish/`.

## Arguments

`/publish [platform...]`

- `platform`: one or more of `android`, `ios`, `web`, `macos`, `windows`, `linux`
- If omitted, defaults to `android ios`
- Invalid platform names are rejected with an error listing valid options

## Workflow

### 1. Verify Flutter project

Check that `pubspec.yaml` exists in the current directory:

```bash
ls pubspec.yaml
```

If missing, stop:

> Not a Flutter project — pubspec.yaml not found.

### 2. Parse and validate platforms

Extract platform names from arguments. If none provided, use `android ios`.

Validate each against: `android`, `ios`, `web`, `macos`, `windows`, `linux`.

If any is invalid:

> Invalid platform: "FOO". Valid platforms: android, ios, web, macos, windows, linux

Stop if any platform is invalid.

### 3. Confirm before building

Use AskUserQuestion to confirm:

```
question: "Build release archives for: PLATFORM_LIST?"
options:
  - label: "Build"
    description: "Run fvm flutter build for each platform"
```

Stop if rejected.

### 4. Prepare output directory

```bash
rm -rf build/publish
mkdir -p build/publish
```

### 4.5. Resolve Apple credentials (macOS only — skip if `macos` is not in the platform list)

The macOS path signs and notarizes the .app (Developer ID), so it needs Apple credentials. Resolve them up front so the run fails fast when the vault or keychain is not ready, rather than after every other platform has built. Always route through `~/.claude/hooks/secret.sh` per the CLAUDE.md secrets rule.

Canonical vault item: `apple-notarization` (login: Apple ID + app-specific password) — shared with `/publish-macos`.

```bash
APPLE_ID="$(~/.claude/hooks/secret.sh apple-notarization username)"
APPLE_APP_PASSWORD="$(~/.claude/hooks/secret.sh apple-notarization password)"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
```

If `APPLE_TEAM_ID` is empty, fall back to the Flutter project's Xcode settings:

```bash
APPLE_TEAM_ID=$(xcodebuild -showBuildSettings -project macos/Runner.xcodeproj 2>/dev/null \
  | awk '/^[[:space:]]*DEVELOPMENT_TEAM = / {print $3; exit}')
```

If any of `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` is still empty:

> macOS sign + notarize requires APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD. Add a vault item named `apple-notarization` (login fields: Apple ID + app-specific password), or set `DEVELOPMENT_TEAM` in `macos/Runner.xcodeproj`.

Resolve the signing identity from the keychain by team ID:

```bash
SIGNING_IDENTITY=$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" \
  | grep "$APPLE_TEAM_ID" \
  | head -n 1 \
  | sed -E 's/.*"(.+)".*/\1/')
```

If empty:

> No `Developer ID Application` keychain identity found for team $APPLE_TEAM_ID. Install the Developer ID certificate and re-run.

If `bw` is installed but locked and the env-var fallback is also empty, surface the same message `/publish-macos` uses — `bw unlock`, set `BW_SESSION`, restart `bw serve --port 8087 &`, then re-run.

### 5. Build each platform

Run sequentially. Stop and report on first failure.

**android:**

```bash
fvm flutter build appbundle --release
```

**ios:**

```bash
fvm flutter build ipa --release
```

**web:**

```bash
fvm flutter build web --release
```

**macos:**

```bash
fvm flutter build macos --release
```

**windows:**

```bash
fvm flutter build windows --release
```

**linux:**

```bash
fvm flutter build linux --release
```

### 5.5. Sign and notarize (macOS only — skip if `macos` is not in the platform list)

After the macOS build succeeds, re-sign the .app with Developer ID and the hardened runtime, zip it for submission, run the notary service to completion, and staple the ticket onto the .app. The .app is signed in place; step 6 carries the stapled artifact into `build/publish/`. The submission zip stays alongside as a second deliverable — a stapled .app inside a zip is the standard distribution form, since unzipping preserves the staple.

```bash
APP_PATH=$(ls -d "build/macos/Build/Products/Release/"*.app | head -n 1)
APP_NAME=$(basename "$APP_PATH" .app)

codesign --deep --force --options runtime --timestamp \
  --sign "$SIGNING_IDENTITY" \
  "$APP_PATH"

codesign --verify --strict --verbose=2 "$APP_PATH"

ditto -c -k --keepParent "$APP_PATH" "build/publish/${APP_NAME}.zip"

xcrun notarytool submit "build/publish/${APP_NAME}.zip" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --wait

xcrun stapler staple "$APP_PATH"

rm -f "build/publish/${APP_NAME}.zip"
ditto -c -k --keepParent "$APP_PATH" "build/publish/${APP_NAME}.zip"
```

The final `ditto` re-zips the now-stapled .app so the zip in `build/publish/` carries the staple too.

Stop on notarization failure and surface the submission log:

```bash
xcrun notarytool log <submission-id> \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD"
```

Note: `codesign --deep` is the simple path and works for most Flutter macOS apps. Apps with deeply nested third-party frameworks may need each bundle signed individually before the .app — refine here if a project trips that edge.

### 6. Collect archives into build/publish/

**android:**

```bash
cp build/app/outputs/bundle/release/app-release.aab build/publish/
```

**ios:**

```bash
cp build/ios/ipa/*.ipa build/publish/
```

**web:**

```bash
cp -r build/web build/publish/web
```

**macos:**

```bash
cp -r "build/macos/Build/Products/Release/"*.app build/publish/
```

**windows:**

```bash
cp -r build/windows/x64/runner/Release build/publish/windows
```

**linux:**

```bash
cp -r build/linux/x64/release/bundle build/publish/linux
```

### 7. Report results

List contents of `build/publish/` and show a summary:

```
Build complete — N platform(s):
  android  →  build/publish/app-release.aab
  ios      →  build/publish/MyApp.ipa

All archives collected in build/publish/
```

## Rules

- Verify `pubspec.yaml` exists before doing anything else
- Always use `fvm flutter`, never bare `flutter`
- Build platforms sequentially — stop immediately on first failure
- Always clean and recreate `build/publish/` at the start
- macOS path signs the .app with Developer ID, hardened runtime, then notarizes and staples; other platforms are not signed
- Resolve Apple credentials via `~/.claude/hooks/secret.sh` (vault item `apple-notarization`); never read tokens directly from env
- Do not bump versions, upload to any store, or modify project files — `/publish-macos` is the skill for version bumps and store uploads
