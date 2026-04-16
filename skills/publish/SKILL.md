---
name: publish
description: Build Flutter release archives for selected platforms and collect into build/publish/. Use /publish [platform...] to build. Default platforms: android ios.
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
- Do not sign, upload, bump versions, or modify any project files
