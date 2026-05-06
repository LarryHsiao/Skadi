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

Resolve the signing identity from the keychain. List available identities first so the user can see what is installed regardless of the outcome, then filter — by team ID first, then by distribution type:

```bash
echo "Available codesigning identities:"
security find-identity -v -p codesigning

SIGNING_IDENTITY=$(security find-identity -v -p codesigning \
  | grep "(${APPLE_TEAM_ID})" \
  | grep "Developer ID Application" \
  | head -n 1 \
  | sed -E 's/.*"(.+)".*/\1/')
```

If `SIGNING_IDENTITY` is empty, the keychain list printed above shows what is installed. Name the failure mode plainly:

> No `Developer ID Application` keychain identity found for team $APPLE_TEAM_ID. Either no cert under that team, or the team's cert is of a different type (e.g. `Apple Development`, `Apple Distribution`). Install the Developer ID Application certificate (Apple Developer portal → Certificates → Developer ID Application) and re-run.

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
  --preserve-metadata=entitlements \
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

### 5.6. Package macOS as a DMG (default — skip if `macos` is not in the platform list)

After the .app is signed, notarized, and stapled, also produce a DMG so users get the standard macOS install experience (drag-to-Applications). The DMG itself is then notarized and stapled — the staple on the inner .app does not transfer to the DMG, and Gatekeeper assesses the downloaded DMG, not what's inside.

```bash
mkdir -p build/publish/dmg-stage
cp -R "$APP_PATH" build/publish/dmg-stage/
ln -sfn /Applications build/publish/dmg-stage/Applications

if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "${APP_NAME}" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --app-drop-link 450 185 \
    "build/publish/${APP_NAME}.dmg" \
    "build/publish/dmg-stage/" || DMG_FAILED=1
else
  DMG_FAILED=1
fi

# TCC fallback — if create-dmg trips on /Volumes (macOS Tahoe TCC) or
# isn't installed, fall back to a mount-free DMG. Plainer chrome (no
# positioned icons) but a valid notarizable image, and the Applications
# symlink keeps the install gesture intact.
if [ "${DMG_FAILED:-0}" = "1" ]; then
  hdiutil makehybrid -hfs -hfs-volume-name "${APP_NAME}" \
    -hfs-openfolder build/publish/dmg-stage \
    build/publish/dmg-stage \
    -o "build/publish/${APP_NAME}.tmp.dmg"
  hdiutil convert "build/publish/${APP_NAME}.tmp.dmg" \
    -format UDZO -imagekey zlib-level=9 \
    -o "build/publish/${APP_NAME}.dmg"
  rm -f "build/publish/${APP_NAME}.tmp.dmg"
fi

rm -rf build/publish/dmg-stage

xcrun notarytool submit "build/publish/${APP_NAME}.dmg" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --wait

xcrun stapler staple "build/publish/${APP_NAME}.dmg"
```

If the fallback path was used, mention it in the final report so the user knows the chrome was skipped.

### 5.7. Upload macOS artifacts to GitHub Releases (default — skip if `macos` is not in the platform list)

After notarize + staple, push the DMG (and the stapled zip alongside) to the GitHub release matching the project's current version. If the release does not exist yet, create it; if it does, replace the assets with `--clobber`.

```bash
PROJECT_VERSION=$(awk -F'[ +]' '/^version:/ {print $2; exit}' pubspec.yaml)
RELEASE_TAG="v${PROJECT_VERSION}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh not installed — skipping GitHub upload."
elif ! gh auth status >/dev/null 2>&1; then
  echo "gh not authenticated — skipping GitHub upload. Run \`gh auth login\` and re-run."
else
  if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
    gh release upload "$RELEASE_TAG" \
      "build/publish/${APP_NAME}.dmg" \
      "build/publish/${APP_NAME}.zip" \
      --clobber
  else
    gh release create "$RELEASE_TAG" \
      "build/publish/${APP_NAME}.dmg" \
      "build/publish/${APP_NAME}.zip" \
      --title "$RELEASE_TAG" \
      --generate-notes
  fi
fi
```

`pubspec.yaml`'s `version:` line carries `MAJOR.MINOR.PATCH+BUILD`; the tag drops the build suffix and prefixes `v`. If the project doesn't follow that shape, the tag derivation may need adjustment — surface the actual derived tag in the run log so the user can intercept.

Stop on `gh` failures; the DMG and zip remain in `build/publish/` for manual upload.

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
- macOS path also packages a DMG (with TCC fallback) and uploads both the DMG and stapled zip to the GitHub release matching `pubspec.yaml`'s version (`v<MAJOR.MINOR.PATCH>`); creates the release if absent, clobbers assets if present
- Resolve Apple credentials via `~/.claude/hooks/secret.sh` (vault item `apple-notarization`); never read tokens directly from env
- Do not bump versions or upload to other stores (App Store Connect, etc.) — `/publish-macos` is the skill for version bumps and Mac App Store uploads
