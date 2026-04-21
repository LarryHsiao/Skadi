---
name: publish-macos
description: Build a native macOS Xcode project, export a signed .app, and package it as a DMG (via create-dmg) or notarized .app. Use /publish-macos [scheme] to build. Auto-detects scheme if omitted.
user_invocable: true
args: "[scheme]"
---

# Build Native macOS Release

Builds a native macOS Xcode project, exports a signed `.app`, then packages it as a DMG or notarized `.app` archive into `build/publish/`.

## Arguments

`/publish-macos [scheme]`

- `scheme`: Xcode scheme to build. If omitted, auto-detected from the project.

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

### 3. Confirm before building

Use AskUserQuestion:

```
question: "Build release archive for scheme: SCHEME?"
options:
  - label: "Build"
    description: "xcodebuild archive → export → package"
```

Stop if rejected.

### 4. Prepare output directory

```bash
rm -rf build/publish
mkdir -p build/publish
```

### 5. Archive

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

### 6. Export .app

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

### 7. Check for create-dmg

```bash
which create-dmg
```

**If found:** proceed to step 8 (DMG packaging).

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

If "Stop here": report location of `.app` and exit.
If "Notarize .app": skip to step 9.

### 8. Package as DMG

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

Stop on failure. Then go to step 10.

### 9. Notarize .app (fallback path)

Resolve credentials in this order for each of `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`:

1. **Memory** — check saved memory for stored Apple notarization credentials
2. **Env vars** — fall back to `$APPLE_ID`, `$APPLE_TEAM_ID`, `$APPLE_APP_PASSWORD`

If any value is missing after both checks, stop:

> Notarization requires APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD.
> Set them as env vars or ask me to remember them.

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

### 10. Report results

```
Build complete:
  archive  →  build/publish/SCHEME.xcarchive
  app      →  build/publish/export/SCHEME.app
  dmg      →  build/publish/SCHEME.dmg        ← if DMG path taken
  zip      →  build/publish/SCHEME.zip        ← if notarization path taken

All artifacts in build/publish/
```

## Rules

- Prefer `.xcworkspace` over `.xcodeproj` when both exist
- Always use `xcpretty` for archive output if available (`which xcpretty`), fallback to raw output
- Stop on first failure; show last 30 lines of build log
- Never bump version, modify project files, or push anything
- Notarization only runs when the user explicitly chooses it or when called with no DMG tool available
