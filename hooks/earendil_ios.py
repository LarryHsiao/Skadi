"""The IOS block of /earendil: build identity, release signing, pods, usage strings.

Build settings are read from `project.pbxproj` text (Release configurations of
the first non-test app target, over the project-level Release). Settings that
live only in an `.xcconfig` are not seen, and a value left as an unresolved
`$(...)` reference is reported as unresolved, not guessed. The keychain and
provisioning-profile rows run on macOS only; elsewhere they report `n/a`.
"""

import plistlib
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from xml.parsers.expat import ExpatError

import earendil_flutter
from earendil_common import (
    FAIL, NA, PASS, WARN, Finding, anchor, line_of, read_text, run_command,
)

PROFILE_WARN_DAYS = 30
EXPORT_METHODS = {"app-store", "app-store-connect", "ad-hoc", "enterprise", "development", "validation", "release-testing", "debugging"}
PROFILE_DIRS = ("~/Library/MobileDevice/Provisioning Profiles", "~/Library/Developer/Xcode/UserData/Provisioning Profiles")
CONFIG_BLOCK = re.compile(r"isa = XCBuildConfiguration;(.*?)\n\t\t\};", re.DOTALL)
SETTINGS_BLOCK = re.compile(r"buildSettings = \{(.*?)\n\t\t\t\};", re.DOTALL)
SETTING_LINE = re.compile(r"^\s*(\"?[A-Za-z_][\w\[\]=*\".-]*)\s*=\s*(.+?);\s*$")
REFERENCE = re.compile(r"^\$\((\w+)\)$")
DISTRIBUTION_IDENTITY = re.compile(r"\"(?:Apple|iPhone) Distribution: [^\"]*\(([A-Z0-9]{10})\)\"")
# Plugins that crash or get rejected without a usage string in Info.plist.
USAGE_KEYS = {
    "image_picker": ("NSPhotoLibraryUsageDescription", "NSCameraUsageDescription"),
    "camera": ("NSCameraUsageDescription", "NSMicrophoneUsageDescription"),
    "mobile_scanner": ("NSCameraUsageDescription",),
    "record": ("NSMicrophoneUsageDescription",),
    "geolocator": ("NSLocationWhenInUseUsageDescription",),
    "local_auth": ("NSFaceIDUsageDescription",),
    "flutter_contacts": ("NSContactsUsageDescription",),
    "speech_to_text": ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"),
}
LISTED_SHOWN = 3


def project_file(ios_root):
    for project in sorted(Path(ios_root).glob("*.xcodeproj")):
        if (project / "project.pbxproj").is_file():
            return project / "project.pbxproj"
    return None


def parse_settings(block):
    found = {}
    for line in block.splitlines():
        match = SETTING_LINE.match(line)
        if match:
            found[match.group(1).strip('"').split("[")[0]] = match.group(2).strip().strip('"')
    return found


def read_configs(pbx):
    """[(configuration name, settings)] for every XCBuildConfiguration in the project."""
    configs = []
    for body in CONFIG_BLOCK.findall(read_text(pbx)):
        name = re.search(r"\bname = ([^;]+);", body)
        block = SETTINGS_BLOCK.search(body)
        configs.append((name.group(1).strip() if name else "", parse_settings(block.group(1)) if block else {}))
    return configs


def release_settings(configs):
    """Project-level Release settings under the app target's; of several targets, the shortest bundle id."""
    releases = [settings for name, settings in configs if name.startswith("Release")]
    project = next((s for s in releases if "PRODUCT_BUNDLE_IDENTIFIER" not in s), {})
    apps = [s for s in releases if "PRODUCT_BUNDLE_IDENTIFIER" in s and "Tests" not in s["PRODUCT_BUNDLE_IDENTIFIER"]]
    app = min(apps, key=lambda s: len(s["PRODUCT_BUNDLE_IDENTIFIER"]), default=None)
    return {**project, **app} if app is not None else {}


def resolve(value, settings):
    for _ in range(3):
        match = REFERENCE.match(value)
        if not match or match.group(1) not in settings:
            break
        value = settings[match.group(1)]
    return value


def identity_rows(settings, root, ios_root):
    bundle, target = settings.get("PRODUCT_BUNDLE_IDENTIFIER", ""), settings.get("IPHONEOS_DEPLOYMENT_TARGET", "?")
    if not bundle:
        return [Finding(WARN, "identity", "no app target with a Release PRODUCT_BUNDLE_IDENTIFIER in the project (an .xcconfig may set it)", anchor(root, project_file(ios_root) or ios_root))]
    return [Finding(PASS, "identity", f"bundle id {bundle} · deployment target {target}")]


def load_plist(path):
    try:
        return plistlib.loads(Path(path).read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError, ExpatError):
        return {}


def info_plist_path(ios_root, settings):
    return Path(ios_root) / settings.get("INFOPLIST_FILE", "Runner/Info.plist").replace("$(SRCROOT)/", "")


def version_values(settings, ios_root):
    plist = load_plist(info_plist_path(ios_root, settings))
    short = resolve(str(plist.get("CFBundleShortVersionString") or settings.get("MARKETING_VERSION", "")), settings)
    build = resolve(str(plist.get("CFBundleVersion") or settings.get("CURRENT_PROJECT_VERSION", "")), settings)
    return short, build


def version_problems(short, build, pubspec):
    """(literal mismatches against pubspec, references left unresolved)."""
    flutter_refs = {"$(FLUTTER_BUILD_NAME)", "$(FLUTTER_BUILD_NUMBER)"}
    mismatches = []
    if pubspec and short and not short.startswith("$(") and short != pubspec[0]:
        mismatches.append(f"version {short} ≠ pubspec {pubspec[0]}")
    if pubspec and pubspec[1] and build and not build.startswith("$(") and build != pubspec[1]:
        mismatches.append(f"build {build} ≠ pubspec {pubspec[1]}")
    allowed = flutter_refs if pubspec else set()
    unresolved = [f"{label} {value}" for label, value in (("version", short), ("build", build)) if value.startswith("$(") and value not in allowed]
    return mismatches, unresolved


def version_rows(settings, ios_root, pubspec, root):
    plist = info_plist_path(ios_root, settings)
    short, build = version_values(settings, ios_root)
    if not short and not build:
        return [Finding(WARN, "version", "no version found (Info.plist missing or empty, no MARKETING_VERSION in the project)", anchor(root, plist))]
    mismatches, unresolved = version_problems(short, build, pubspec)
    if mismatches:
        return [Finding(FAIL, "version", "; ".join(mismatches), anchor(root, plist))]
    if unresolved:
        return [Finding(WARN, "version", f"{', '.join(unresolved)} is an unresolved reference (an .xcconfig may supply it)", anchor(root, plist))]
    detail = f"read from pubspec ({pubspec[0]}+{pubspec[1] or '?'})" if short.startswith("$(") else f"{short} ({build})"
    return [Finding(PASS, "version", detail)]


def is_manual(settings):
    return settings.get("CODE_SIGN_STYLE", "Automatic") == "Manual"


def signing_rows(settings, root, ios_root):
    pbx = project_file(ios_root) or ios_root
    team = settings.get("DEVELOPMENT_TEAM", "")
    if not team:
        return [Finding(WARN, "signing", "no DEVELOPMENT_TEAM in the Release configuration (an .xcconfig may set it)", anchor(root, pbx))]
    if not is_manual(settings):
        return [Finding(PASS, "signing", f"team {team} · automatic signing")]
    identity, profile = settings.get("CODE_SIGN_IDENTITY", ""), settings.get("PROVISIONING_PROFILE_SPECIFIER", "")
    if identity and "Distribution" not in identity:
        return [Finding(FAIL, "signing", f"manual signing with identity '{identity}', not a Distribution identity", anchor(root, pbx))]
    if not identity or not profile:
        missing = "identity" if not identity else "provisioning profile"
        return [Finding(WARN, "signing", f"manual signing, but the {missing} is not set in the project (an .xcconfig may set it)", anchor(root, pbx))]
    return [Finding(PASS, "signing", f"team {team} · manual · {identity} · profile '{profile}'")]


def distribution_teams(listing):
    return set(DISTRIBUTION_IDENTITY.findall(listing or ""))


def keychain_rows(settings, listing):
    if listing is None:
        return [Finding(NA, "keychain", "macOS only (or --no-commands)")]
    team = settings.get("DEVELOPMENT_TEAM", "")
    if not team:
        return []
    if team in distribution_teams(listing):
        return [Finding(PASS, "keychain", f"Distribution identity for team {team} is in the keychain")]
    if is_manual(settings):
        return [Finding(FAIL, "keychain", f"no valid Distribution identity for team {team} in the keychain")]
    return [Finding(WARN, "keychain", f"no Distribution identity for team {team} in the keychain (Xcode may fetch one at export)")]


def profile_rows(settings, profiles, now):
    if not is_manual(settings):
        return []
    if profiles is None:
        return [Finding(NA, "profile", "macOS only (or --no-commands)")]
    wanted = settings.get("PROVISIONING_PROFILE_SPECIFIER", "")
    matching = [p for p in profiles if wanted in (p.get("Name"), p.get("UUID")) and p.get("ExpirationDate")]
    found = max(matching, key=lambda p: p["ExpirationDate"], default=None)
    if found is None:
        return [Finding(FAIL, "profile", f"provisioning profile '{wanted}' is not installed")]
    left = (found["ExpirationDate"] - now).days
    date = found["ExpirationDate"].date()
    if found["ExpirationDate"] < now:
        return [Finding(FAIL, "profile", f"profile '{wanted}' expired on {date}")]
    status = WARN if left < PROFILE_WARN_DAYS else PASS
    return [Finding(status, "profile", f"profile '{wanted}' expires {date} ({left} days)")]


def export_rows(ios_root, settings, root):
    files = sorted(Path(ios_root).glob("ExportOptions*.plist")) + sorted(Path(root).glob("ExportOptions*.plist"))
    if not files:
        return [Finding(NA, "export", "no ExportOptions plist (flutter build ipa writes its own)")]
    options, team = load_plist(files[0]), settings.get("DEVELOPMENT_TEAM", "")
    method = options.get("method", "")
    if method not in EXPORT_METHODS:
        return [Finding(WARN, "export", f"ExportOptions method '{method}' is not a known export method", anchor(root, files[0]))]
    if team and options.get("teamID") not in (None, team):
        return [Finding(WARN, "export", f"ExportOptions teamID {options.get('teamID')} ≠ project team {team}", anchor(root, files[0]))]
    return [Finding(PASS, "export", f"ExportOptions {method} · team {options.get('teamID', team)}")]


def uses_firebase(ios_root, root):
    return "Firebase" in read_text(Path(ios_root) / "Podfile.lock") or "firebase_core" in read_text(Path(root) / "pubspec.lock")


def services_rows(ios_root, settings, root):
    if not uses_firebase(ios_root, root):
        return []
    bundle = settings.get("PRODUCT_BUNDLE_IDENTIFIER", "")
    files = [f for f in sorted(Path(ios_root).rglob("GoogleService-Info.plist")) if "Pods" not in f.parts]
    if not files:
        return [Finding(FAIL, "services", "Firebase is linked but GoogleService-Info.plist is absent", anchor(root, Path(ios_root) / "Runner" / "GoogleService-Info.plist"))]
    if any(load_plist(f).get("BUNDLE_ID") == bundle for f in files):
        return [Finding(PASS, "services", f"GoogleService-Info.plist BUNDLE_ID matches {bundle}")]
    return [Finding(FAIL, "services", f"BUNDLE_ID {load_plist(files[0]).get('BUNDLE_ID', '?')} ≠ bundle id {bundle}", anchor(root, files[0], line_of(read_text(files[0]), "BUNDLE_ID")))]


def toolchain_rows(has_podfile, xcode_output, pod_output, ran=True):
    if not ran:
        return [Finding(NA, "toolchain", "macOS only (or --no-commands)")]
    xcode = re.search(r"Xcode\s+(\S+)", xcode_output or "")
    if not xcode:
        return [Finding(FAIL, "toolchain", "xcodebuild not found or not usable")]
    pods = (pod_output or "").strip()
    if has_podfile and not pods:
        return [Finding(FAIL, "toolchain", "CocoaPods not found, but the project has a Podfile")]
    return [Finding(PASS, "toolchain", f"Xcode {xcode.group(1)}" + (f" · CocoaPods {pods}" if pods else ""))]


def pods_rows(ios_root):
    podfile, lock = Path(ios_root) / "Podfile", Path(ios_root) / "Podfile.lock"
    if not podfile.is_file():
        return []
    problems = []
    if not lock.is_file():
        problems.append("Podfile.lock is missing")
    elif lock.stat().st_mtime < podfile.stat().st_mtime:
        problems.append("Podfile changed since Podfile.lock")
    if not (Path(ios_root) / "Pods").is_dir():
        problems.append("Pods/ is missing")
    if problems:
        return [Finding(WARN, "pods", f"{'; '.join(problems)} (run pod install)")]
    return [Finding(PASS, "pods", "Podfile.lock current · Pods/ present")]


def usage_rows(ios_root, root):
    lock = read_text(Path(root) / "pubspec.lock")
    needed = {name: keys for name, keys in USAGE_KEYS.items() if re.search(rf"^  {name}:\s*$", lock, re.MULTILINE)}
    if not needed:
        return []
    plist_path = Path(ios_root) / "Runner" / "Info.plist"
    plist = load_plist(plist_path)
    missing = [f"{key} ({name})" for name, keys in needed.items() for key in keys if not str(plist.get(key, "")).strip()]
    if missing:
        return [Finding(WARN, "plist", f"missing or blank usage string: {', '.join(missing[:LISTED_SHOWN])} (needed only if the app calls that API)", anchor(root, plist_path))]
    return [Finding(PASS, "plist", f"usage strings present for {', '.join(needed)}")]


def strip_rows(settings):
    problems = []
    if settings.get("STRIP_INSTALLED_PRODUCT") == "NO":
        problems.append("STRIP_INSTALLED_PRODUCT is NO")
    if settings.get("DEBUG_INFORMATION_FORMAT") == "dwarf":
        problems.append("DEBUG_INFORMATION_FORMAT is dwarf (no dSYM for crash symbolication)")
    if problems:
        return [Finding(WARN, "strip", "; ".join(problems))]
    return [Finding(PASS, "strip", "symbols stripped · dSYM generated")]


def doctor_rows(report):
    mark = (report or {}).get("Xcode")
    if mark is None:
        return [Finding(NA, "doctor", "no Xcode row from flutter doctor")]
    status = {"✓": PASS, "!": WARN, "✗": FAIL}.get(mark, WARN)
    return [Finding(status, "doctor", "Xcode " + {PASS: "OK", WARN: "has warnings", FAIL: "reports an error"}[status])]


def load_profiles():
    profiles = []
    for directory in PROFILE_DIRS:
        for path in sorted(Path(directory).expanduser().glob("*.mobileprovision")):
            code, output = run_command(["security", "cms", "-D", "-i", str(path)])
            try:
                profiles.append(plistlib.loads(output.encode("utf-8"))) if code == 0 else None
            except (plistlib.InvalidFileException, ValueError, ExpatError):
                continue
    return profiles


def command_output(argv):
    code, output = run_command(argv)
    return output if code == 0 else None


def check(project, commands, doctor, now=None):
    root, ios_root = project.root, project.ios_root
    pbx = project_file(ios_root)
    if pbx is None:
        return [Finding(FAIL, "project", "no .xcodeproj found", anchor(root, ios_root))]
    settings = release_settings(read_configs(pbx))
    flutter = project.kind == "flutter"
    pubspec = earendil_flutter.pubspec_version(root) if flutter else None
    mac = commands and sys.platform == "darwin"
    now = now or datetime.now(timezone.utc).replace(tzinfo=None)
    keychain = command_output(["security", "find-identity", "-v", "-p", "codesigning"]) if mac else None
    toolchain = toolchain_rows((Path(ios_root) / "Podfile").is_file(), command_output(["xcodebuild", "-version"]) if mac else None, command_output(["pod", "--version"]) if mac else None, ran=mac)
    rows = (
        identity_rows(settings, root, ios_root) + version_rows(settings, ios_root, pubspec, root)
        + signing_rows(settings, root, ios_root) + keychain_rows(settings, keychain)
        + profile_rows(settings, load_profiles() if mac else None, now) + export_rows(ios_root, settings, root)
        + services_rows(ios_root, settings, root) + toolchain + pods_rows(ios_root)
        + (usage_rows(ios_root, root) if flutter else []) + strip_rows(settings)
    )
    return rows + (doctor_rows(doctor) if flutter else [])
