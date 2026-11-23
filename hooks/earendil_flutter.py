"""The FLUTTER block of /earendil: the project-wide dimensions both platforms share.

sdk · version · deps · assets · codegen · entry · obfuscate · doctor
"""

import functools
import json
import re
from pathlib import Path

from earendil_common import (
    FAIL, NA, PASS, WARN, Finding, anchor, build_scripts, git_state, line_of, read_text, run_command,
)

SEMVER = re.compile(r"(\d+)\.(\d+)\.(\d+)")
VERSION_KEY = re.compile(r"^version:\s*['\"]?([^\s'\"#]+)['\"]?\s*(?:#.*)?$", re.MULTILINE)
VERSION_VALUE = re.compile(r"^(\d+\.\d+\.\d+)(?:\+(\d+))?$")
GENERATED_SUFFIXES = (".g.dart", ".freezed.dart", ".gr.dart", ".config.dart")
ENV_FILE_FLAG = re.compile(r"--dart-define-from-file[= ]\s*([^\s'\"\\]+)")
TARGET_FLAG = re.compile(r"(?:\s-t|--target)[= ]\s*([^\s'\"\\]+\.dart)")
PLATFORM_HEADINGS = ("Android toolchain", "Android Studio", "Xcode", "Chrome", "Visual Studio", "Linux toolchain")
LISTED_NAMES_SHOWN = 3
DYNAMIC_PATH = re.compile(r"[$%`{]")
OFFLINE = re.compile(r"Failed host lookup|SocketException|Could not resolve host|No address associated|Network is unreachable", re.IGNORECASE)
PUB_CAUSE = re.compile(r"^(Because |version solving|Error |Git error|fatal:|Could not )")
JAVA_BUILD = re.compile(r"Java version[^\n]*?\(build (\d+)(?:\.(\d+))?")


def semver(text):
    match = SEMVER.match(text.strip())
    return tuple(int(part) for part in match.groups()) if match else None


def satisfies(version, constraint):
    """Does `version` meet a pub constraint (`^x.y.z`, `>=a <b`, `any`)? Unreadable → True."""
    actual, text = semver(version), constraint.strip()
    if actual is None or text in ("", "any"):
        return True
    if text.startswith("^"):
        low = semver(text[1:])
        return True if low is None else low <= actual < ((low[0] + 1, 0, 0) if low[0] else (0, low[1] + 1, 0))
    for operator, bound in re.findall(r"(>=|<=|>|<|=)?\s*(\d+\.\d+\.\d+)", text):
        if not compare(actual, operator or "=", semver(bound)):
            return False
    return True


def compare(actual, operator, bound):
    return {">=": actual >= bound, "<=": actual <= bound, ">": actual > bound, "<": actual < bound, "=": actual == bound}[operator]


def top_section(text, key):
    """(line number, line) pairs of the lines under a top-level `key:` of a YAML file."""
    lines, inside, found = text.splitlines(), False, []
    for number, line in enumerate(lines, 1):
        if re.match(rf"^{re.escape(key)}:", line):
            inside = True
        elif inside and line.strip() and not line.startswith((" ", "\t", "#")):
            break
        elif inside:
            found.append((number, line))
    return found


def pubspec_version(root):
    """(name, build or None) from pubspec.yaml's `version:`, or None when unreadable."""
    match = VERSION_KEY.search(read_text(Path(root) / "pubspec.yaml"))
    parsed = VERSION_VALUE.match(match.group(1)) if match else None
    return parsed.groups() if parsed else None


def flutter_binary(root):
    pinned = Path(root) / ".fvm" / "flutter_sdk" / "bin" / "flutter"
    return str(pinned) if pinned.exists() else "flutter"


def fvm_pin(root):
    for rel, key in ((".fvmrc", "flutter"), (".fvm/fvm_config.json", "flutterSdkVersion")):
        try:
            value = json.loads(read_text(Path(root) / rel) or "{}").get(key, "")
        except ValueError:
            value = ""
        if semver(str(value)):
            return str(value)
    return ""


def environment_constraint(root, key):
    """(constraint, line number) for `environment: <key>:` in pubspec.yaml."""
    for number, line in top_section(read_text(Path(root) / "pubspec.yaml"), "environment"):
        match = re.match(rf"^\s+{key}:\s*['\"]?([^'\"#]+?)['\"]?\s*(#.*)?$", line)
        if match:
            return match.group(1), number
    return "", 0


def machine_versions(output):
    try:
        data = json.loads(output[output.index("{"): output.rindex("}") + 1])
    except ValueError:
        return "", ""
    return data.get("frameworkVersion", ""), data.get("dartSdkVersion", "")


def sdk_rows(root, commands):
    if not commands:
        return [Finding(NA, "sdk", "skipped (--no-commands)")]
    code, output = run_command([flutter_binary(root), "--version", "--machine"], cwd=root)
    framework, dart = machine_versions(output) if code == 0 else ("", "")
    if not framework:
        return [Finding(FAIL, "sdk", "flutter not usable: " + (output.strip().splitlines() or ["no output"])[0])]
    for key, version in (("sdk", dart), ("flutter", framework)):
        constraint, line = environment_constraint(root, key)
        if constraint and not satisfies(version, constraint):
            text = f"{key} {version} does not satisfy pubspec environment {constraint}"
            return [Finding(FAIL, "sdk", text, anchor(root, Path(root) / "pubspec.yaml", line))]
    pin = fvm_pin(root)
    if pin and semver(framework) != semver(pin):
        return [Finding(WARN, "sdk", f"FVM pin {pin}, but Flutter {framework} is in use (run `fvm use`)")]
    return [Finding(PASS, "sdk", f"Flutter {framework} · Dart {semver_text(dart)}")]


def semver_text(version):
    parsed = semver(version)
    return ".".join(str(part) for part in parsed) if parsed else version


def tag_build_number(root):
    code, output = run_command(["git", "-C", str(root), "describe", "--tags", "--abbrev=0"])
    match = re.search(r"\+(\d+)$", output.strip()) if code == 0 else None
    return (output.strip(), int(match.group(1))) if match else ("", 0)


def version_rows(root):
    pubspec = Path(root) / "pubspec.yaml"
    parsed = pubspec_version(root)
    line = line_of(read_text(pubspec), r"^version:")
    if parsed is None:
        text = "version in pubspec.yaml is malformed (want x.y.z+n)" if line else "no version in pubspec.yaml"
        return [Finding(FAIL, "version", text, anchor(root, pubspec, line))]
    name, build = parsed
    if build is None:
        return [Finding(WARN, "version", f"{name} has no +build number", anchor(root, pubspec, line))]
    tag, tag_build = tag_build_number(root)
    if tag and int(build) <= tag_build:
        return [Finding(WARN, "version", f"build number {build} does not exceed tag {tag}", anchor(root, pubspec, line))]
    return [Finding(PASS, "version", f"{name}+{build} parses" + (f" · up from {tag}" if tag else ""))]


def dependency_blocks(root):
    """(name, line number, block text) for each entry under `dependencies:`."""
    blocks, current = [], None
    for number, line in top_section(read_text(Path(root) / "pubspec.yaml"), "dependencies"):
        entry = re.match(r"^  ([A-Za-z_][\w-]*):", line)
        if entry:
            current = [entry.group(1), number, line]
            blocks.append(current)
        elif current is not None:
            current[2] += "\n" + line
    return blocks


def dependency_source_rows(root):
    rows, pubspec = [], Path(root) / "pubspec.yaml"
    for name, number, block in dependency_blocks(root):
        if re.search(r"^\s+git:", block, re.MULTILINE) and "ref:" not in block:
            rows.append(Finding(WARN, "deps", f"git dependency `{name}` has no ref (follows the branch head)", anchor(root, pubspec, number)))
        if re.search(r"^\s+path:", block, re.MULTILINE):
            rows.append(Finding(WARN, "deps", f"path dependency `{name}` is absent on other machines and CI", anchor(root, pubspec, number)))
    return rows


def lock_rows(root):
    root = Path(root)
    config = root / ".dart_tool" / "package_config.json"
    if not (root / "pubspec.lock").exists():
        return [Finding(WARN, "deps", "pubspec.lock is missing", "pubspec.lock")]
    if not config.exists():
        return [Finding(WARN, "deps", "pub get has not run (no .dart_tool/package_config.json)")]
    if config.stat().st_mtime < (root / "pubspec.yaml").stat().st_mtime:
        return [Finding(WARN, "deps", "pubspec.yaml changed since the last pub get")]
    return []


def dry_run_rows(root, binary):
    code, output = run_command([binary, "pub", "get", "--dry-run"], cwd=root)
    if code == 0:
        return []
    if code is None:
        return [Finding(WARN, "deps", f"could not run pub get --dry-run: {output}")]
    if OFFLINE.search(output):
        return [Finding(WARN, "deps", "pub get --dry-run could not reach the package server (offline?)")]
    return [Finding(FAIL, "deps", f"pub get --dry-run fails: {pub_failure_reason(output)}")]


def pub_failure_reason(output):
    """The first line that states a cause; pub's closing summary only says it failed."""
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    return next((line for line in lines if PUB_CAUSE.match(line)), lines[-1] if lines else "no output")


def deps_rows(root, binary, commands):
    rows = lock_rows(root) + dependency_source_rows(root) + (dry_run_rows(root, binary) if commands else [])
    if rows:
        return rows
    return [Finding(PASS, "deps", "pubspec.lock in step" + (" · pub get --dry-run resolves" if commands else ""))]


def declared_assets(root):
    """((path, line) of declared asset files and dirs, (path, line) of declared fonts)."""
    assets, fonts, in_assets = [], [], False
    for number, line in top_section(read_text(Path(root) / "pubspec.yaml"), "flutter"):
        if re.match(r"^  assets:\s*$", line):
            in_assets = True
            continue
        item = re.match(r"^    -\s+(?:path:\s*)?['\"]?([^'\"#\s]+)", line) if in_assets else None
        font = re.match(r"^\s+-?\s*asset:\s*['\"]?([^'\"#\s]+)", line)
        if item:
            assets.append((item.group(1), number))
        elif font:
            fonts.append((font.group(1), number))
        elif line.strip() and not line.startswith("    "):
            in_assets = False
    return assets, fonts


def undeclared_assets(root, declared):
    base = Path(root) / "assets"
    if not base.is_dir():
        return []
    files = {entry for entry, _ in declared if not entry.endswith("/")}
    dirs = {entry for entry, _ in declared if entry.endswith("/")}
    found = (p.relative_to(root).as_posix() for p in sorted(base.rglob("*")) if p.is_file() and not p.name.startswith("."))
    return [rel for rel in found if rel not in files and rel.rsplit("/", 1)[0] + "/" not in dirs]


def listed(names):
    shown = ", ".join(names[:LISTED_NAMES_SHOWN])
    return shown + (f" and {len(names) - LISTED_NAMES_SHOWN} more" if len(names) > LISTED_NAMES_SHOWN else "")


def assets_rows(root):
    assets, fonts = declared_assets(root)
    entries = assets + fonts
    missing = [(p, n) for p, n in entries if not ((Path(root) / p).is_dir() if p.endswith("/") else (Path(root) / p).is_file())]
    extra = undeclared_assets(root, assets)
    rows = []
    if missing:
        rows.append(Finding(FAIL, "assets", f"declared but absent: {listed([p for p, _ in missing])}", anchor(root, Path(root) / "pubspec.yaml", missing[0][1])))
    if extra:
        rows.append(Finding(WARN, "assets", f"{len(extra)} file(s) under assets/ not declared: {listed(extra)}"))
    if not rows and entries:
        rows.append(Finding(PASS, "assets", f"{len(entries)} declared path(s) exist"))
    return rows


def stale_generated(root):
    stale = []
    for path in sorted((Path(root) / "lib").rglob("*.dart")):
        suffix = next((s for s in GENERATED_SUFFIXES if path.name.endswith(s)), "")
        source = path.with_name(path.name[: -len(suffix)] + ".dart") if suffix else None
        if source and source.exists() and source.stat().st_mtime > path.stat().st_mtime:
            stale.append(path.relative_to(root).as_posix())
    return stale


def stale_l10n(root):
    config = read_text(Path(root) / "l10n.yaml")
    if not config:
        return None
    arb = re.search(r"^arb-dir:\s*(\S+)", config, re.MULTILINE)
    out = re.search(r"^output-dir:\s*(\S+)", config, re.MULTILINE)
    sources = list((Path(root) / (arb.group(1) if arb else "lib/l10n")).glob("*.arb"))
    outputs = [p for p in (Path(root) / (out.group(1) if out else ".dart_tool/flutter_gen/gen_l10n")).glob("*.dart")]
    newest_source = max((p.stat().st_mtime for p in sources), default=0)
    return newest_source > max((p.stat().st_mtime for p in outputs), default=0)


def codegen_rows(root):
    stale, l10n = stale_generated(root), stale_l10n(root)
    if stale:
        return [Finding(WARN, "codegen", f"{len(stale)} generated file(s) older than source: {listed(stale)} (run build_runner)")]
    if l10n:
        return [Finding(WARN, "codegen", "l10n output older than the .arb files (run flutter gen-l10n)")]
    has_generated = any(p.name.endswith(GENERATED_SUFFIXES) for p in (Path(root) / "lib").rglob("*.dart"))
    return [Finding(PASS, "codegen", "generated files current")] if (has_generated or l10n is not None) else []


def referenced_files(root):
    """(path, script, line) for each literal env file or entry target a build script names."""
    found = []
    for script in build_scripts(root):
        for number, line in enumerate(read_text(script).splitlines(), 1):
            for pattern in (ENV_FILE_FLAG, TARGET_FLAG):
                found += [(m, script, number) for m in pattern.findall(line) if not DYNAMIC_PATH.search(m)]
    return found


def missing_reference_row(root, path, script, line):
    _, ignored = git_state(root, path)
    note = " (gitignored — CI may write it)" if ignored else ""
    return Finding(WARN if ignored else FAIL, "entry", f"{path} named in a build script but absent{note}", anchor(root, script, line))


def entry_rows(root):
    mains = sorted((Path(root) / "lib").glob("main*.dart"))
    if not mains:
        return [Finding(FAIL, "entry", "no lib/main*.dart entry point", "lib/")]
    missing = [(p, s, n) for p, s, n in referenced_files(root) if not (Path(root) / p).exists()]
    if missing:
        return [missing_reference_row(root, p, s, n) for p, s, n in missing]
    return [Finding(PASS, "entry", " · ".join(f"lib/{m.name}" for m in mains[:LISTED_NAMES_SHOWN]) + " present")]


def obfuscate_rows(root):
    scripts = build_scripts(root)
    for script in scripts:
        line = line_of(read_text(script), r"--obfuscate")
        if line:
            return [Finding(PASS, "obfuscate", "--obfuscate passed to the build", anchor(root, script, line))]
    where = listed([s.relative_to(root).as_posix() for s in scripts]) if scripts else ""
    text = f"no --obfuscate in {where}" if where else "no build scripts found to scan"
    return [Finding(WARN, "obfuscate", f"{text} — Dart symbols ship readable unless the flag is typed by hand")]


def parse_doctor(output):
    """{heading: marker} from `flutter doctor` lines such as `[✓] Flutter (Channel…)`."""
    found = {}
    for line in output.splitlines():
        match = re.match(r"^\[(.)\] (.+)$", line)
        if match:
            found[re.split(r" \(| - ", match.group(2))[0].strip()] = match.group(1)
    return found


@functools.lru_cache(maxsize=None)
def doctor_output(root, binary):
    """`flutter doctor -v` text, run once per project; '' when it cannot run."""
    code, output = run_command([binary, "doctor", "-v"], cwd=root)
    return output if code is not None else ""


def run_doctor(root, binary, commands):
    output = doctor_output(str(root), binary) if commands else ""
    return parse_doctor(output) if output else None


def jdk_from_doctor(output):
    """Major version of the JDK Flutter itself builds with (it may differ from PATH's java)."""
    match = JAVA_BUILD.search(output)
    if not match:
        return 0
    return int(match.group(2)) if match.group(1) == "1" and match.group(2) else int(match.group(1))


def doctor_jdk(root, binary):
    return jdk_from_doctor(doctor_output(str(root), binary))


def doctor_rows(report):
    if report is None:
        return [Finding(NA, "doctor", "not run (--no-commands, or flutter unavailable)")]
    own = {name: mark for name, mark in report.items() if not name.startswith(PLATFORM_HEADINGS)}
    if own.get("Flutter") == "✗":
        return [Finding(FAIL, "doctor", "flutter doctor reports an error for Flutter itself")]
    flagged = [name for name, mark in own.items() if mark != "✓"]
    if flagged:
        return [Finding(WARN, "doctor", f"flutter doctor flags: {', '.join(flagged)}")]
    return [Finding(PASS, "doctor", ", ".join(own) + " OK")]


def check(project, commands, doctor):
    root, binary = project.root, flutter_binary(project.root)
    return (
        sdk_rows(root, commands) + version_rows(root) + deps_rows(root, binary, commands)
        + assets_rows(root) + codegen_rows(root) + entry_rows(root) + obfuscate_rows(root)
        + doctor_rows(doctor)
    )
