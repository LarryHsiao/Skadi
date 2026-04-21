---
name: publish-macos
description: Bump version, commit, push, build a native macOS Xcode project, export a signed .app, package as DMG (via create-dmg) or notarized .app, then tag the commit. Use /publish-macos [scheme] [--no-bump]. Auto-detects scheme if omitted.
user_invocable: true
args: "[scheme] [--no-bump]"
---

# Build Native macOS Release

Bumps the version, commits, pushes, then builds a native macOS Xcode project, exports a signed `.app`, and packages it as a DMG or notarized `.app` into `build/publish/`. Tags the commit with the new version on success.

## Arguments

`/publish-macos [scheme] [--no-bump]`

- `scheme`: Xcode scheme to build. If omitted, auto-detected from the project.
- `--no-bump`: Skip version bump, commit, push, and tagging. Build only.

## Workflow

### 1. Verify Xcode project

Check for `.xcworkspace` first, then `.xcodeproj`:

```bash
ls *.xcworkspace 2>/dev/null || ls *.xcodeproj 2>/dev/null
```

If neither found, stop:

> Not a native macOS project — no .xcworkspace or .xcodeproj found.

### 2. Detect scheme

If no scheme argument provided, list available schemes:

```bash
xcodebuild -list 2>/dev/null
```

Pick the first scheme that is not a test scheme (does not end in `Tests` or `UITests`).
If multiple non-test schemes exist, use AskUserQuestion to let the user pick.

### 3. Bump version (skip if `--no-bump`)

Read the current marketing version:

```bash
agvtool what-marketing-version -terse1 | tail -n 1 | tr -d ' '
```

If `agvtool` reports that versioning isn't configured, stop:

> `agvtool` is not configured for this project. Enable Apple Generic Versioning in build settings, or re-run with `--no-bump`.

Ask via AskUserQuestion which part to bump:

```
question: "Current version: CURRENT. Which part to bump?"
options:
  - label: "Patch"    description: "X.Y.Z → X.Y.(Z+1)"
  - label: "Minor"    description: "X.Y.Z → X.(Y+1).0"
  - label: "Major"    description: "X.Y.Z → (X+1).0.0"
```

Compute `NEW_VERSION` from the choice. Apply it:

```bash
agvtool new-marketing-version NEW_VERSION
agvtool next-version -all
```

Confirm via AskUserQuestion:

```
question: "Bumped to NEW_VERSION. Commit and push?"
options:
  - label: "Commit and push"  description: "rtk git add -A && rtk git commit && rtk git push"
  - label: "Stop"             description: "Leave the working tree dirty and exit"
```

Stop if rejected.

If accepted:

```bash
rtk git add -A
rtk git commit -m "chore: bump version to NEW_VERSION"
rtk git push
```

Remember `NEW_VERSION` for step 11.

### 4. Confirm before building

Use AskUserQuestion:

```
question: "Build release archive for scheme: SCHEME?"
options:
  - label: "Build"
    description: "xcodebuild archive → export → package"
```

Stop if rejected.

### 5. Prepare output directory

```bash
rm -rf build/publish
mkdir -p build/publish
```

### 6. Archive

Use `-workspace` if a `.xcworkspace` exists, otherwise `-project`:

```bash
# with workspace:
xcodebuild archive \
  -workspace *.xcworkspace \
  -scheme SCHEME \
  -configuration Release \
  -archivePath build/publish/SCHEME.xcarchive \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  | xcpretty || cat

# with project only:
xcodebuild archive \
  -project *.xcodeproj \
  -scheme SCHEME \
  -configuration Release \
  -archivePath build/publish/SCHEME.xcarchive \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  | xcpretty || cat
```

Stop on failure and show the last 30 lines of output.

### 7. Export .app

Create a minimal `ExportOptions.plist`:

```bash
cat > /tmp/ExportOptions.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>mac-application</string>
</dict>
</plist>
EOF
```

```bash
xcodebuild -exportArchive \
  -archivePath build/publish/SCHEME.xcarchive \
  -exportPath build/publish/export \
  -exportOptionsPlist /tmp/ExportOptions.plist
```

Stop on failure.

### 8. Check for create-dmg

```bash
which create-dmg
```

**If found:** proceed to step 9 (DMG packaging).

**If not found:** inform the user:

> `create-dmg` not found. Install it with:
>
> ```
> brew install create-dmg
> ```
>
> Then re-run `/publish-macos` to get a DMG.
>
> Alternatively, the exported `.app` at `build/publish/export/SCHEME.app` is ready for notarization.

Then use AskUserQuestion:

```
question: "create-dmg not installed. How do you want to proceed?"
options:
  - label: "Notarize .app"
    description: "Submit the exported .app to Apple notarization and staple"
  - label: "Stop here"
    description: "Keep the exported .app and exit"
```

If "Stop here": report location of `.app` and exit (no tag).
If "Notarize .app": skip step 9 and go to step 10.

### 9. Package as DMG

```bash
create-dmg \
  --volname "SCHEME" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --app-drop-link 450 185 \
  "build/publish/SCHEME.dmg" \
  "build/publish/export/"
```

Stop on failure. Then go to step 11.

### 10. Notarize .app (fallback path)

Resolve credentials in this order for each of `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`:

1. **Bitwarden (`bw`)** — if `bw` is installed and the vault is unlocked, search for an item named `Apple Notarization`:
   ```bash
   bw get item "Apple Notarization"
   ```
   Extract `APPLE_ID` from `login.username`, `APPLE_APP_PASSWORD` from `login.password`, and `APPLE_TEAM_ID` from the custom field named `team_id`.

2. **Memory** — check saved memory for stored Apple notarization credentials.

3. **Env vars** — fall back to `$APPLE_ID`, `$APPLE_TEAM_ID`, `$APPLE_APP_PASSWORD`.

If `bw` is installed but the vault is locked (`bw status` returns `locked`), inform the user:

> Bitwarden vault is locked. Run `bw unlock` and set `BW_SESSION`, or provide credentials another way.

If any value is missing after all three checks, stop:

> Notarization requires APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD.
> Provide them via Bitwarden, memory, or env vars.

Zip the `.app`:

```bash
ditto -c -k --keepParent \
  "build/publish/export/SCHEME.app" \
  "build/publish/SCHEME.zip"
```

Submit for notarization:

```bash
xcrun notarytool submit "build/publish/SCHEME.zip" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --wait
```

Staple:

```bash
xcrun stapler staple "build/publish/export/SCHEME.app"
```

### 11. Tag the commit (skip if `--no-bump`)

Only when step 3 ran and the DMG (or notarized `.app`) was produced:

```bash
rtk git tag "vNEW_VERSION"
rtk git push origin "vNEW_VERSION"
```

If tagging fails (e.g. tag already exists), report the error — do not delete the DMG.

### 12. Report results

```
Build complete:
  version  →  NEW_VERSION                         ← if bumped
  archive  →  build/publish/SCHEME.xcarchive
  app      →  build/publish/export/SCHEME.app
  dmg      →  build/publish/SCHEME.dmg            ← if DMG path taken
  zip      →  build/publish/SCHEME.zip            ← if notarization path taken
  tag      →  vNEW_VERSION pushed to origin       ← if bumped

All artifacts in build/publish/
```

## Rules

- Prefer `.xcworkspace` over `.xcodeproj` when both exist
- Always use `xcpretty` for archive output if available (`which xcpretty`), fallback to raw output
- Stop on first failure; show last 30 lines of build log
- Version bump runs before the build; tag runs only after the DMG (or notarized `.app`) is produced
- When `--no-bump` is passed, skip version bump, commit, push, and tag — build only
- Never modify other project files beyond what `agvtool` touches
- Notarization only runs when the user explicitly chooses it or when called with no DMG tool available
