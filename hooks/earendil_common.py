"""Shared vocabulary and file helpers for /earendil's check groups.

Every helper reads; none writes. A file that is absent or unreadable reads as
empty text, so a check names the gap instead of raising.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

PASS, WARN, FAIL, NA = "pass", "warn", "fail", "na"
COMMAND_TIMEOUT_SECONDS = 120
BUILD_SCRIPT_GLOBS = (
    "Makefile", "*.mk", "*.sh", ".gitlab-ci.yml", ".github/workflows/*.yml",
    ".github/workflows/*.yaml", "fastlane/*", "scripts/*", "tool/*", "codemagic.yaml",
)


@dataclass(frozen=True)
class Finding:
    status: str
    dim: str
    text: str
    anchor: str = ""


@dataclass(frozen=True)
class Project:
    kind: str  # "flutter" | "native"
    root: Path
    android_root: Path | None
    ios_root: Path | None
    selected: str | None = None  # "android" | "ios" when the caller named one


def read_text(path):
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def line_of(text, pattern):
    """1-based line of the first regex match, or 0 when there is none."""
    match = re.search(pattern, text, re.MULTILINE)
    return text.count("\n", 0, match.start()) + 1 if match else 0


def anchor(root, path, line=0):
    try:
        shown = Path(path).resolve().relative_to(Path(root).resolve())
    except ValueError:
        shown = Path(path)
    return f"{shown}:{line}" if line else str(shown)


def run_command(argv, cwd=None):
    """(exit code, combined output); (None, reason) when it cannot run at all."""
    if shutil.which(argv[0]) is None:
        return None, f"{argv[0]} not found"
    try:
        done = subprocess.run(
            argv, cwd=cwd, capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=COMMAND_TIMEOUT_SECONDS
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, str(error)
    return done.returncode, (done.stdout or "") + (done.stderr or "")


def git_state(root, relpath):
    """(tracked, ignored) for a path, or (None, None) outside a git work tree."""
    inside, _ = run_command(["git", "-C", str(root), "rev-parse", "--is-inside-work-tree"])
    if inside != 0:
        return None, None
    tracked, _ = run_command(["git", "-C", str(root), "ls-files", "--error-unmatch", relpath])
    ignored, _ = run_command(["git", "-C", str(root), "check-ignore", "-q", relpath])
    return tracked == 0, ignored == 0


def parse_properties(text):
    """key=value lines of a .properties file; comments and blanks skipped."""
    pairs = {}
    for raw in text.splitlines():
        line = raw.strip()
        if line and not line.startswith(("#", "!")) and "=" in line:
            key, _, value = line.partition("=")
            pairs[key.strip()] = value.strip()
    return pairs


def extract_block(text, header_pattern):
    """Body of the first `{ ... }` that follows a header match; '' when absent."""
    header = re.search(header_pattern, text)
    if not header:
        return ""
    start = text.find("{", header.end() - 1)
    if start < 0:
        return ""
    depth = 0
    for index in range(start, len(text)):
        depth += {"{": 1, "}": -1}.get(text[index], 0)
        if depth == 0:
            return text[start + 1:index]
    return ""


def build_scripts(root):
    """Files that may carry a `flutter build` command line, nearest first."""
    found = []
    for pattern in BUILD_SCRIPT_GLOBS:
        found.extend(path for path in sorted(Path(root).glob(pattern)) if path.is_file())
    return found


def count_by(findings):
    return {status: sum(1 for f in findings if f.status == status) for status in (PASS, WARN, FAIL)}
