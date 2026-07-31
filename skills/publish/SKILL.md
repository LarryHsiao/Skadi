---
name: publish
description: Build Flutter release archives for selected platforms and collect into build/publish/. macOS builds are signed (Developer ID) and notarized via Apple's notary service. Use /publish [platform...] to build. Default platforms: android ios.
purpose: Builds Flutter release archives for selected platforms.
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
APP_PATH=$(/bin/ls -d "build/macos/Build/Products/Release/"*.app | head -n 1)
APP_NAME=$(basename "$APP_PATH" .app)
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist")

# Strip xattrs that Finder/Spotlight may have attached to the build product.
# codesign rejects `com.apple.FinderInfo` on inner resources; a single stray
# xattr breaks deep-verify — failing notarisation, or slipping past it and
# tripping AMFI at launch with the unhelpful "can't be opened" dialog.
xattr -cr "$APP_PATH"

# Embed the project's Developer ID provisioning profile if one is supplied.
# Flutter's build phase drops in a development profile (Mac Team Provisioning
# Profile) that demands `get-task-allow=true` and conflicts with Developer ID
# entitlements; replace it. If the project doesn't ship a profile, the .app
# is signed without one and the entitlements path below strips the keys that
# would otherwise need a profile to authorize.
if [ -f macos/Runner/embedded.provisionprofile ]; then
  cp macos/Runner/embedded.provisionprofile "$APP_PATH/Contents/embedded.provisionprofile"
else
  rm -f "$APP_PATH/Contents/embedded.provisionprofile"
fi

# Generate signing entitlements from the project's Release.entitlements.
# `--preserve-metadata=entitlements` is unsafe because Flutter's build phase
# signs with a development profile that bakes in `get-task-allow` —
# preserving it would carry that forward and notary will refuse.
#
# Two paths, gated by whether the project supplies a Developer ID profile:
#
#   With profile (sandboxed apps that need keychain-access-groups, etc.):
#     • Keep `keychain-access-groups` (substituted) — the embedded profile
#       authorizes the team-prefixed group.
#     • Inject `com.apple.application-identifier` matching the bundle id
#       under the team prefix — AMFI cross-checks this against the profile.
#
#   Without profile (simpler apps; default Flutter macOS shape):
#     • Strip `keychain-access-groups` and `com.apple.application-identifier`
#       — without a profile to vouch for them, AMFI rejects launch with
#       POSIX 163 and a generic "can't be opened" dialog.
#     • Apps still get the default keychain group `<TEAM_ID>.<BUNDLE_ID>`
#       implicitly via flutter_secure_storage's defaults, but only when the
#       app holds the entitlement, so dropping the entitlement also drops
#       keychain access for sandboxed apps.
#
# `com.apple.developer.team-identifier` is auto-derived by codesign from
# the signing cert and need not be declared in the entitlements file.
ENTITLEMENTS_FILE=$(mktemp)
sed "s|\$(AppIdentifierPrefix)|${APPLE_TEAM_ID}.|g" macos/Runner/Release.entitlements > "$ENTITLEMENTS_FILE"
/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.team-identifier" "$ENTITLEMENTS_FILE" 2>/dev/null
if [ -f "$APP_PATH/Contents/embedded.provisionprofile" ]; then
  /usr/libexec/PlistBuddy -c "Delete :com.apple.application-identifier" "$ENTITLEMENTS_FILE" 2>/dev/null
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string ${APPLE_TEAM_ID}.${BUNDLE_ID}" "$ENTITLEMENTS_FILE"
else
  /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$ENTITLEMENTS_FILE" 2>/dev/null
  /usr/libexec/PlistBuddy -c "Delete :com.apple.application-identifier" "$ENTITLEMENTS_FILE" 2>/dev/null
fi

codesign --deep --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS_FILE" \
  --sign "$SIGNING_IDENTITY" \
  "$APP_PATH"

rm -f "$ENTITLEMENTS_FILE"

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

# Strip xattrs from the staged copy. cp -R preserves source xattrs, and any
# `com.apple.FinderInfo` blob will trip codesign deep-verify on the user's
# machine after install — the failure surfaces as a generic "can't be
# opened" dialog with no Gatekeeper text, since AMFI rejects launch
# silently when nested signatures fail.
xattr -cr build/publish/dmg-stage/

if command -v create-dmg >/dev/null 2>&1; then
  # Note: do NOT pre-stage `Applications` here — `--app-drop-link` makes
  # create-dmg write its own, and a pre-existing one fails with
  # `ln: ...: File exists` and forces the fallback path.
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
# positioned icons) but a valid notarizable image. The Applications
# symlink is staged here, only for the fallback, since hdiutil does not
# add a drop-link of its own.
if [ "${DMG_FAILED:-0}" = "1" ]; then
  ln -sfn /Applications build/publish/dmg-stage/Applications
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

codesign --sign "$SIGNING_IDENTITY" --timestamp \
  "build/publish/${APP_NAME}.dmg"

xcrun notarytool submit "build/publish/${APP_NAME}.dmg" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --wait

xcrun stapler staple "build/publish/${APP_NAME}.dmg"

spctl -a -vv -t open --context context:primary-signature \
  "build/publish/${APP_NAME}.dmg"
```

The `codesign` step is load-bearing: notary will accept an unsigned DMG (it verifies the signed content within), and `stapler` will attach a ticket — but Gatekeeper at *open* time evaluates the disk image's own signature, and an unsigned DMG fails with `source=no usable signature` even with a valid staple. The trailing `spctl` check fails fast if any link in the chain (sign → notarize → staple) was skipped or broken.

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
