#!/usr/bin/env python3
"""earendil.py — pre-flight check for a Flutter or native mobile project.

    earendil.py [android|ios] [--root DIR] [--no-flutter] [--no-commands]

Detects the project kind (Flutter, native Android, native iOS), runs the
check groups that apply, prints one report, and ends in PASS or HOLD.
Read-only: it inspects files and runs only version and diagnostic commands
(`flutter --version`, `flutter doctor`, `flutter pub get --dry-run`, `java`,
`xcodebuild`, `pod`, `security`, `git`); it never builds, signs or edits.

Exit status: 0 PASS, 1 HOLD, 2 not a mobile project / platform absent.

Platforms: macOS and Linux. The keychain, provisioning-profile and Xcode rows
run on macOS only and report `n/a` elsewhere. Windows is untested — verify
with `py hooks\\earendil.py --no-commands` from a Flutter project root.
"""

import argparse
import re
import sys
from dataclasses import replace
from pathlib import Path

import earendil_android
import earendil_flutter
import earendil_ios
from earendil_common import FAIL, NA, PASS, WARN, Finding, Project, count_by, read_text

ROOT_SEARCH_DEPTH = 8
FLUTTER_SDK_LINE = re.compile(r"^\s+sdk:\s*flutter\s*$", re.MULTILINE)
KIND_LABEL = {"flutter": "Flutter", "android": "native Android", "ios": "native iOS", "both": "native Android + iOS"}
MARK = {PASS: "✅", WARN: "⚠️", FAIL: "🚫", NA: "➖"}
DIM_WIDTH = 10


def is_flutter(root):
    return FLUTTER_SDK_LINE.search(read_text(Path(root) / "pubspec.yaml")) is not None


def native_android(root):
    return any((Path(root) / name).is_file() for name in ("settings.gradle", "settings.gradle.kts"))


def native_ios(root):
    return any(Path(root).glob("*.xcodeproj")) or any(Path(root).glob("*.xcworkspace"))


def find_root(start):
    """Nearest project root at or above `start`; a Flutter root beats a native folder inside it."""
    here = Path(start).resolve()
    marked = [c for c in [here, *here.parents][:ROOT_SEARCH_DEPTH] if is_flutter(c) or native_android(c) or native_ios(c)]
    flutter = next((c for c in marked if is_flutter(c)), None)
    return flutter or (marked[0] if marked else None)


def detect(root):
    root = Path(root)
    if is_flutter(root):
        android, ios = root / "android", root / "ios"
        return Project("flutter", root, android if android.is_dir() else None, ios if ios.is_dir() else None)
    android = root if native_android(root) else None
    ios = root if native_ios(root) else None
    return Project("native", root, android, ios) if (android or ios) else None


def select(project, platform):
    """Narrow the project to one platform; ValueError when its directory is absent."""
    if platform is None:
        return project
    if getattr(project, f"{platform}_root") is None:
        raise ValueError(f"no {platform} project found under {project.root}")
    other = {"android": "ios_root", "ios": "android_root"}[platform]
    return replace(project, **{other: None}, selected=platform)


def kind_label(project):
    if project.kind == "flutter":
        return KIND_LABEL["flutter"]
    both = project.android_root is not None and project.ios_root is not None
    return KIND_LABEL["both" if both else ("android" if project.android_root else "ios")]


def verdict(sections):
    """(PASS|HOLD, failing, warnings, counted rows) — n/a rows are not counted."""
    findings = [f for _, rows in sections for f in rows]
    counts = count_by(findings)
    total = counts[PASS] + counts[WARN] + counts[FAIL]
    return ("HOLD" if counts[FAIL] else "PASS"), counts[FAIL], counts[WARN], total


def tally(rows):
    counts = count_by(rows)
    parts = [f"{counts[PASS]} pass"] if counts[PASS] else []
    parts += [f"{counts[WARN]} warn"] if counts[WARN] else []
    parts += [f"{counts[FAIL]} fail"] if counts[FAIL] else []
    return " · ".join(parts)


def render_row(row):
    lines = [f" {MARK[row.status]} {row.dim:<{DIM_WIDTH}} {row.text}"]
    if row.anchor:
        lines.append(f"{'':{DIM_WIDTH + 5}}{row.anchor}")
    return lines


def render_section(title, rows):
    heading = f"{title:<62}{tally(rows)}".rstrip()
    return [heading, *[line for row in rows for line in render_row(row)], ""]


def render(title, kind, sections):
    lines = [f"Earendil — {title}", f"kind: {kind}", ""]
    for name, rows in sections:
        lines += render_section(name, rows)
    status, failing, warnings, total = verdict(sections)
    if status == "PASS":
        suffix = f", {warnings} warning{'s' if warnings != 1 else ''}" if warnings else ""
        lines.append(f"Verdict: PASS — {total} checks, 0 failing{suffix}")
        return "\n".join(lines)
    lines.append(f"Verdict: HOLD — {failing} failing, {warnings} warning{'s' if warnings != 1 else ''}")
    failed = [f for _, rows in sections for f in rows if f.status == FAIL]
    lines += [f"  {n}. {f.anchor or f.dim}   {f.text}" for n, f in enumerate(failed, 1)]
    return "\n".join(lines)


def title_of(project):
    parsed = earendil_flutter.pubspec_version(project.root) if project.kind == "flutter" else None
    if project.kind != "flutter" or parsed is None:
        return project.root.name
    name = re.search(r"^name:\s*(\S+)", read_text(project.root / "pubspec.yaml"), re.MULTILINE)
    version = parsed[0] + (f"+{parsed[1]}" if parsed[1] else "")
    return f"{name.group(1) if name else project.root.name} {version}"


def platform_section(project, platform, commands, doctor):
    """(heading, rows) for one platform; None when a native project simply lacks it."""
    root = getattr(project, f"{platform}_root")
    module = {"android": earendil_android, "ios": earendil_ios}[platform]
    if project.kind != "flutter":
        return (platform.upper(), module.check(project, commands, doctor)) if root else None
    if root is None:
        return (platform.upper(), [Finding(NA, "platform", f"no {platform}/ directory")])
    return (f"{platform.upper()}  ({platform}/)", module.check(project, commands, doctor))


def build_sections(project, commands, with_flutter=True):
    """The check groups that apply, in report order."""
    sections, doctor = [], None
    if project.kind == "flutter":
        binary = earendil_flutter.flutter_binary(project.root)
        doctor = earendil_flutter.run_doctor(project.root, binary, commands)
        if with_flutter:
            sections.append(("FLUTTER", earendil_flutter.check(project, commands, doctor)))
    wanted = [project.selected] if project.selected else ["android", "ios"]
    built = [platform_section(project, platform, commands, doctor) for platform in wanted]
    return sections + [section for section in built if section]


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="earendil", description=__doc__.split("\n")[0])
    parser.add_argument("platform", nargs="?", choices=["android", "ios"])
    parser.add_argument("--root", default=".")
    parser.add_argument("--no-flutter", action="store_true")
    parser.add_argument("--no-commands", action="store_true")
    return parser.parse_args(argv)


def main(argv, out=print):
    args = parse_args(argv)
    root = find_root(args.root)
    project = detect(root) if root else None
    if project is None:
        out("Earendil: no Flutter, Android or iOS project found at or above " + str(Path(args.root).resolve()))
        return 2
    try:
        project = select(project, args.platform)
    except ValueError as error:
        out(f"Earendil: {error}")
        return 2
    sections = build_sections(project, not args.no_commands, not args.no_flutter)
    out(render(title_of(project), kind_label(project), sections))
    return 0 if verdict(sections)[0] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
