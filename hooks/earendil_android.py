"""The ANDROID block of /earendil: build identity, release signing, shrinking, toolchain.

Gradle is read as text with regular expressions, not evaluated. A value the
text does not state outright (computed, or read from a property file the check
cannot see) reads as unknown, and unknown is reported as such, never guessed.
Key material is checked for presence only; no value is ever printed.
"""

import json
import os
import re
from pathlib import Path

import earendil_flutter
from earendil_common import (
    FAIL, NA, PASS, WARN, Finding, anchor, extract_block, git_state, line_of,
    parse_properties, read_text, run_command,
)

# Minimum Gradle per Android Gradle Plugin, from
# https://developer.android.com/build/releases/about-agp (read 2026-11-23).
# An AGP newer than this table reads as `n/a`, never as a pass.
AGP_MIN_GRADLE = {
    "7.0": "7.0", "7.1": "7.2", "7.2": "7.3.3", "7.3": "7.4", "7.4": "7.5",
    "8.0": "8.0", "8.1": "8.0", "8.2": "8.2", "8.3": "8.4", "8.4": "8.6", "8.5": "8.7", "8.6": "8.7",
    "8.7": "8.9", "8.8": "8.10.2", "8.9": "8.11.1", "8.10": "8.11.1", "8.11": "8.13", "8.12": "8.13",
    "8.13": "8.13", "9.0": "9.1.0", "9.1": "9.3.1", "9.2": "9.4.1", "9.3": "9.5.0", "9.4": "9.6.0", "9.5": "9.6.0",
}
JDK_FOR_AGP_8_UP, JDK_FOR_AGP_7 = 17, 11
APP_PLUGIN = re.compile(r"android[._-]?application", re.IGNORECASE)
CATALOG_AGP = re.compile(r"^\s*(?:agp|androidGradlePlugin|android-gradle-plugin)\s*=\s*\"([\d.]+)\"", re.MULTILINE)
REQUIRED_KEYS = ("storeFile", "storePassword", "keyAlias", "keyPassword")
RELEASE_HEADER = r"(?:getByName\(\s*[\"']release[\"']\s*\)|create\(\s*[\"']release[\"']\s*\)|\brelease)\s*\{"
SIGNING_NAME = re.compile(r"signingConfigs\s*(?:\.getByName\(\s*[\"'](\w+)[\"']\s*\)|\[\s*[\"'](\w+)[\"']\s*\]|\.(\w+))")
LEVEL = r"\s*=?\s*(\d+|flutter\.\w+)"
KEYSTORE_PATHSPECS = ("*.jks", "*.keystore")
LISTED_SHOWN = 3


def gradle_file(module):
    for name in ("build.gradle.kts", "build.gradle"):
        if (Path(module) / name).is_file():
            return Path(module) / name
    return None


def app_module(android_root):
    root = Path(android_root)
    subdirs = sorted(d for d in root.iterdir() if d.is_dir())
    for candidate in [root / "app", *subdirs, root]:
        file = gradle_file(candidate) if candidate.is_dir() else None
        if file and APP_PLUGIN.search(read_text(file)):
            return candidate
    return None


def setting(text, pattern):
    match = re.search(pattern, text)
    return match.group(1).strip() if match else ""


def identity_rows(text, module, root):
    file = gradle_file(module)
    app_id = setting(text, r"applicationId\s*=?\s*[\"']([^\"']+)[\"']")
    namespace = setting(text, r"namespace\s*=?\s*[\"']([^\"']+)[\"']")
    if app_id and not namespace:
        return [Finding(WARN, "identity", f"applicationId {app_id}, but no namespace (AGP 8 requires one)", anchor(root, file))]
    if app_id:
        return [Finding(PASS, "identity", f"applicationId {app_id} · namespace {namespace}")]
    if re.search(r"\bapplicationId\b", text):
        return [Finding(NA, "identity", "applicationId is computed in gradle — not a literal this check can read")]
    if namespace:
        return [Finding(PASS, "identity", f"applicationId defaults to namespace {namespace}")]
    return [Finding(WARN, "identity", "neither applicationId nor namespace found (a convention plugin may set them)", anchor(root, file))]


def sdk_rows(text):
    levels = {name: setting(text, rf"{name}(?:Version)?{LEVEL}") for name in ("minSdk", "targetSdk", "compileSdk")}
    missing = [name for name, value in levels.items() if not value]
    if missing:
        return [Finding(WARN, "sdk", f"not stated in gradle: {', '.join(missing)}")]
    return [Finding(PASS, "sdk", " · ".join(f"{name} {value}" for name, value in levels.items()))]


def literal_mismatch(code, name, pubspec):
    wrong = []
    if code.isdigit() and pubspec[1] and code != pubspec[1]:
        wrong.append(f"versionCode {code} ≠ pubspec build {pubspec[1]}")
    if name[:1] in "\"'" and name.strip("\"'") != pubspec[0]:
        wrong.append(f"versionName {name.strip(chr(34) + chr(39))} ≠ pubspec {pubspec[0]}")
    return wrong


def version_rows(text, pubspec, module, root):
    file = gradle_file(module)
    code = setting(text, r"versionCode\s*=?\s*([^\s}/]+)")
    name = setting(text, r"versionName\s*=?\s*(\"[^\"]*\"|'[^']*'|[^\s}/]+)")
    if not code or not name:
        return [Finding(WARN, "version", "versionCode or versionName not set here (defaults apply unless a plugin sets them)", anchor(root, file))]
    if pubspec is None:
        return [Finding(PASS, "version", f"versionCode {code} · versionName {name}")]
    wrong = literal_mismatch(code, name, pubspec)
    if wrong:
        return [Finding(FAIL, "version", "; ".join(wrong), anchor(root, file, line_of(text, r"versionCode")))]
    return [Finding(PASS, "version", f"follow pubspec ({pubspec[0]}+{pubspec[1] or '?'})")]


def release_block(text):
    return extract_block(extract_block(text, r"buildTypes\s*\{"), RELEASE_HEADER)


def signing_defined_rows(text, name, file, root):
    block = extract_block(text, r"signingConfigs\s*\{")
    if not block:
        return [Finding(WARN, "release", f"signingConfigs.{name} is not defined in this file (a plugin may define it)", anchor(root, file))]
    if not re.search(rf"[\"']{name}[\"']|\b{name}\s*\{{", block):
        return [Finding(FAIL, "release", f"signingConfigs.{name} is not defined", anchor(root, file))]
    return [Finding(PASS, "release", f"release signs with signingConfigs.{name}")]


def release_rows(text, module, root):
    file, release = gradle_file(module), release_block(text)
    if not release:
        return [Finding(WARN, "release", "no release build type configured in this file", anchor(root, file))]
    names = [next(group for group in found.groups() if group) for found in SIGNING_NAME.finditer(release)]
    line = line_of(text, r"\brelease\s*\{")
    if not names:
        return [Finding(WARN, "release", "release build type sets no signingConfig here (an unsigned APK will not install; check it is set elsewhere)", anchor(root, file, line))]
    others = [name for name in names if name != "debug"]
    if not others:
        debug_line = line_of(text, r"signingConfig\s*=?\s*signingConfigs[^\n]*debug")
        return [Finding(FAIL, "release", "release build is signed with the debug key", anchor(root, file, debug_line))]
    if "debug" in names:
        return [Finding(WARN, "release", "release can fall back to the debug key (a branch references signingConfigs.debug)", anchor(root, file, line))]
    return signing_defined_rows(text, others[0], file, root)


def keystore_exists(value, android_root, module):
    candidates = [Path(value), Path(android_root) / value, Path(module) / value]
    return any(path.is_file() for path in candidates)


def required_keys(signing_block):
    """Property names the signing block reads; the Flutter-docs four when it names none."""
    found = [a or b for a, b in re.findall(r"\[\s*[\"'](\w+)[\"']\s*\]|getProperty\(\s*[\"'](\w+)[\"']", signing_block)]
    return tuple(dict.fromkeys(found)) or REQUIRED_KEYS


def store_key(keys):
    return next((key for key in keys if "storefile" in key.lower().replace("_", "")), "storeFile")


def key_property_rows(props_file, android_root, module, root, keys):
    props = parse_properties(read_text(props_file))
    missing = [key for key in keys if not props.get(key)]
    if missing:
        return [Finding(FAIL, "key", f"key.properties lacks a value for: {', '.join(missing)}", anchor(root, props_file))]
    store = props.get(store_key(keys), "")
    if store and not keystore_exists(store, android_root, module):
        return [Finding(FAIL, "key", f"keystore {Path(store).name} named in key.properties does not exist", anchor(root, props_file))]
    exists = f" · {Path(store).name} exists" if store else ""
    return [Finding(PASS, "key", f"key.properties complete ({len(keys)} of {len(keys)} keys set){exists}")]


def key_rows(text, android_root, module, root):
    signing = extract_block(text, r"signingConfigs\s*\{")
    if "key.properties" not in text and "keystoreProperties" not in text:
        env = "getenv" in signing
        return [Finding(NA, "key", "signing values come from environment variables — not verifiable from files")] if env else []
    props = next((p for p in (Path(android_root) / "key.properties", Path(module) / "key.properties") if p.is_file()), None)
    if props is None:
        return [Finding(WARN, "key", "key.properties is not present here (a CI job may write it)")]
    return key_property_rows(props, android_root, module, root, required_keys(signing))


def tracked_keystores(android_root, root):
    """Tracked key stores under android_root; a committed debug keystore is harmless and skipped."""
    code, output = run_command(["git", "-C", str(root), "ls-files", "--", *KEYSTORE_PATHSPECS])
    base = Path(android_root).resolve()
    return [
        line for line in output.splitlines()
        if code == 0 and (Path(root).resolve() / line).resolve().is_relative_to(base)
        and not Path(line).name.lower().startswith("debug")
    ]


def secrets_rows(android_root, root):
    props = Path(android_root) / "key.properties"
    try:
        rel = props.resolve().relative_to(Path(root).resolve()).as_posix()
    except ValueError:
        return []
    tracked, ignored = git_state(root, rel)
    if tracked is None:
        return []
    rows = []
    if tracked:
        rows.append(Finding(FAIL, "secrets", "key.properties is tracked by git", rel))
    elif props.exists() and not ignored:
        rows.append(Finding(WARN, "secrets", "key.properties is not in .gitignore", rel))
    stored = tracked_keystores(android_root, root)
    if stored:
        rows.append(Finding(FAIL, "secrets", f"keystore tracked by git: {', '.join(stored[:LISTED_SHOWN])}", stored[0]))
    if not rows and (props.exists() or any(Path(android_root).rglob("*.jks"))):
        rows.append(Finding(PASS, "secrets", "key material is untracked and ignored"))
    return rows


def minify_rows(text, module, root):
    release, file = release_block(text), gradle_file(module)
    state = setting(release, r"(?:isMinifyEnabled|minifyEnabled)\s*=?\s*(true|false)")
    rows = []
    if state != "true":
        reason = "is off" if state == "false" else "is not set (whether Flutter's plugin enables it was not verified)"
        rows.append(Finding(WARN, "minify", f"R8/ProGuard {reason} in the release build type", anchor(root, file)))
    named = re.findall(r"[\"']([^\"']+\.pro)[\"']", release)
    absent = [n for n in named if not (Path(module) / n).is_file()]
    if absent:
        rows.append(Finding(WARN, "minify", f"proguard rules file named but absent: {', '.join(absent)}", anchor(root, file)))
    return rows or [Finding(PASS, "minify", "R8 on" + (" · rules file present" if named else ""))]


def symbols_rows(text):
    if not re.search(r"externalNativeBuild|jniLibs|ndk\s*\{", text):
        return []
    if "debugSymbolLevel" in text:
        return [Finding(PASS, "symbols", "native debug symbols are bundled")]
    return [Finding(WARN, "symbols", "native code present but no ndk.debugSymbolLevel (Play shows unsymbolicated native crashes)")]


def package_names(raw):
    try:
        clients = json.loads(raw).get("client", [])
    except (ValueError, AttributeError):
        return None
    return [c.get("client_info", {}).get("android_client_info", {}).get("package_name", "") for c in clients]


def services_rows(text, module, root):
    if "google-services" not in text:
        return []
    app_id = setting(text, r"applicationId\s*=?\s*[\"']([^\"']+)[\"']") or setting(text, r"namespace\s*=?\s*[\"']([^\"']+)[\"']")
    files = [f for f in sorted(Path(module).rglob("google-services.json")) if "build" not in f.relative_to(module).parts]
    if not files:
        return [Finding(FAIL, "services", "google-services plugin applied but google-services.json is absent", anchor(root, Path(module) / "google-services.json"))]
    for file in files:
        names = package_names(read_text(file))
        if names is not None and app_id in names:
            return [Finding(PASS, "services", f"google-services.json package matches {app_id}")]
    first = read_text(files[0])
    found = (package_names(first) or ["(unreadable)"])[0]
    return [Finding(FAIL, "services", f"package_name {found} ≠ applicationId {app_id}", anchor(root, files[0], line_of(first, r'"package_name"')))]


def version_tuple(text):
    parts = [int(p) for p in re.findall(r"\d+", text)[:3]]
    return tuple(parts + [0] * (3 - len(parts)))


def agp_requirements(agp):
    major, minor = (agp.split(".") + ["0"])[:2]
    minimum = AGP_MIN_GRADLE.get(f"{major}.{minor}")
    return None if minimum is None else (minimum, JDK_FOR_AGP_8_UP if int(major) >= 8 else JDK_FOR_AGP_7)


def java_major(output):
    match = re.search(r'version "(\d+)(?:\.(\d+))?', output)
    if not match:
        return 0
    return int(match.group(2)) if match.group(1) == "1" and match.group(2) else int(match.group(1))


def native_jdk():
    """Major JDK Gradle would pick in a native project: JAVA_HOME first, then PATH."""
    home = os.environ.get("JAVA_HOME", "")
    java = str(Path(home) / "bin" / "java") if home and (Path(home) / "bin" / "java").exists() else "java"
    return java_major(run_command([java, "-version"])[1])


def find_agp(android_root):
    pattern = re.compile(r"com\.android\.(?:application|library)[\"']\)?\s+version\s+[\"']([\d.]+)[\"']|com\.android\.tools\.build:gradle:([\d.]+)")
    for name in ("settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle"):
        match = pattern.search(read_text(Path(android_root) / name))
        if match:
            return match.group(1) or match.group(2)
    catalog = CATALOG_AGP.search(read_text(Path(android_root) / "gradle" / "libs.versions.toml"))
    return catalog.group(1) if catalog else ""


def wrapper_gradle(android_root):
    file = Path(android_root) / "gradle" / "wrapper" / "gradle-wrapper.properties"
    text = read_text(file)
    return setting(text, r"gradle-([\d.]+)-(?:bin|all)\.zip"), file, line_of(text, r"distributionUrl")


def toolchain_rows(android_root, root, jdk, authoritative=True):
    """`authoritative` is False when the JDK came from JAVA_HOME/PATH, which a build may not use."""
    agp = find_agp(android_root)
    if not agp:
        return [Finding(NA, "toolchain", "Android Gradle Plugin version not found in settings.gradle, build.gradle or the version catalog")]
    required = agp_requirements(agp)
    if required is None:
        return [Finding(NA, "toolchain", f"AGP {agp} is newer than this check's table — nothing verified")]
    gradle, wrapper, line = wrapper_gradle(android_root)
    if gradle and version_tuple(gradle) < version_tuple(required[0]):
        return [Finding(FAIL, "toolchain", f"Gradle {gradle} is below the {required[0]} that AGP {agp} requires", anchor(root, wrapper, line))]
    if jdk and jdk < required[1]:
        note = "" if authoritative else " (from JAVA_HOME/PATH; Android Studio may build with its own JDK)"
        return [Finding(FAIL if authoritative else WARN, "toolchain", f"JDK {jdk} is below the {required[1]} that AGP {agp} requires{note}")]
    return [Finding(PASS, "toolchain", f"AGP {agp} · Gradle {gradle or '?'}" + (f" · JDK {jdk}" if jdk else "") + " — compatible")]


def plugin_floor_rows(text, root):
    floor = setting(text, rf"minSdk(?:Version)?{LEVEL}")
    meta = read_text(Path(root) / ".flutter-plugins-dependencies")
    if not floor.isdigit() or not meta:
        return []
    try:
        plugins = json.loads(meta).get("plugins", {}).get("android", [])
    except ValueError:
        return []
    needs = {}
    for plugin in plugins:
        if not plugin.get("path"):
            continue
        folder = Path(plugin["path"]) / "android"
        value = setting(read_text(gradle_file(folder)) if gradle_file(folder) else "", r"minSdk(?:Version)?\s*=?\s*(\d+)")
        if value.isdigit() and int(value) > int(floor):
            needs[plugin.get("name", "?")] = value
    if needs:
        shown = ", ".join(f"{name} needs {value}" for name, value in list(needs.items())[:LISTED_SHOWN])
        return [Finding(WARN, "plugins", f"{shown} — app declares minSdk {floor} (manifest merge may fail)")]
    return [Finding(PASS, "plugins", f"no plugin needs more than minSdk {floor} ({len(plugins)} checked)")]


def doctor_rows(report):
    mark = (report or {}).get("Android toolchain")
    if mark is None:
        return [Finding(NA, "doctor", "no Android toolchain row from flutter doctor")]
    status = {"✓": PASS, "!": WARN, "✗": FAIL}.get(mark, WARN)
    return [Finding(status, "doctor", "Android toolchain " + {PASS: "OK", WARN: "has warnings", FAIL: "reports an error"}[status])]


def jdk_in_use(project, commands):
    """(major, authoritative): Flutter's own JDK is authoritative; JAVA_HOME/PATH is a best guess."""
    if not commands:
        return 0, True
    if project.kind == "flutter":
        return earendil_flutter.doctor_jdk(project.root, earendil_flutter.flutter_binary(project.root)), True
    return native_jdk(), False


def check(project, commands, doctor):
    root, android_root = project.root, project.android_root
    module = app_module(android_root)
    if module is None:
        return [Finding(FAIL, "module", "no application module (com.android.application) found", anchor(root, android_root))]
    text = read_text(gradle_file(module))
    flutter = project.kind == "flutter"
    pubspec = earendil_flutter.pubspec_version(root) if flutter else None
    jdk, authoritative = jdk_in_use(project, commands)
    rows = (
        identity_rows(text, module, root) + sdk_rows(text) + version_rows(text, pubspec, module, root)
        + release_rows(text, module, root) + key_rows(text, android_root, module, root)
        + secrets_rows(android_root, root) + minify_rows(text, module, root) + symbols_rows(text)
        + services_rows(text, module, root) + toolchain_rows(android_root, root, jdk, authoritative)
    )
    return rows + (plugin_floor_rows(text, root) + doctor_rows(doctor) if flutter else [])
