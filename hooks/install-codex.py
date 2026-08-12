#!/usr/bin/env python3
"""Install Skadi-owned Codex artifacts without replacing user-owned config."""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path


START = "<!-- skadi:start -->"
END = "<!-- skadi:end -->"
MANIFEST = ".skadi-installed-files"
OWNED_PREFIXES = ("hooks/", "skills/", "docs/", "rules/")


def fail(message: str) -> None:
    raise SystemExit(f"install-codex: {message}")


if len(sys.argv) != 4:
    fail("expected <repo> <codex-root> <profile>")

repo = Path(sys.argv[1]).resolve()
root = Path(sys.argv[2]).expanduser().resolve()
profile = sys.argv[3]
renderer = repo / "hooks" / "render-codex-skill.py"
root.mkdir(parents=True, exist_ok=True)


def rendered_text(source: Path) -> str:
    text = source.read_text(encoding="utf-8")
    home = str(Path.home())
    replacements = (
        ("~/.claude-personal", f"{home}/.codex-personal"),
        ("~/.claude-work", f"{home}/.codex-work"),
        ("~/.claude", str(root)),
        ("{{CODEX_ROOT}}", str(root)),
        ("{{SKADI_PROFILE}}", profile),
    )
    for old, new in replacements:
        text = text.replace(old, new)
    return text


def write_text(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(rendered_text(source), encoding="utf-8")
    os.chmod(destination, stat.S_IMODE(source.stat().st_mode))
    print(f"installed:      {destination}")


def copy_or_render(source: Path, destination: Path) -> None:
    try:
        source.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        print(f"installed:      {destination}")
        return
    write_text(source, destination)


def merge_agents() -> None:
    destination = root / "AGENTS.md"
    body = (repo / "AGENTS.md").read_text(encoding="utf-8").rstrip()
    block = f"{START}\n{body}\n{END}"
    existing = destination.read_text(encoding="utf-8") if destination.exists() else ""
    if (START in existing) != (END in existing):
        fail(f"unbalanced Skadi markers in {destination}")
    if START in existing:
        before, remainder = existing.split(START, 1)
        _, after = remainder.split(END, 1)
        merged = before.rstrip() + "\n\n" + block + after
    elif existing.strip():
        merged = existing.rstrip() + "\n\n" + block + "\n"
    else:
        merged = block + "\n"
    destination.write_text(merged, encoding="utf-8")
    print(f"merged:         {destination}")


def merge_hooks() -> None:
    destination = root / "hooks.json"
    source = json.loads(rendered_text(repo / "codex" / "hooks.json"))
    if destination.exists():
        try:
            current = json.loads(destination.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            fail(f"cannot preserve invalid {destination}: {error}")
    else:
        current = {}
    current.setdefault("description", "Lifecycle hooks for this Codex home.")
    current_hooks = current.setdefault("hooks", {})
    for event, skadi_groups in source["hooks"].items():
        retained = []
        for group in current_hooks.get(event, []):
            handlers = [
                handler
                for handler in group.get("hooks", [])
                if "codex-hook-adapter.sh" not in handler.get("command", "")
            ]
            if handlers:
                preserved = dict(group)
                preserved["hooks"] = handlers
                retained.append(preserved)
        current_hooks[event] = retained + skadi_groups
    destination.write_text(json.dumps(current, indent=2) + "\n", encoding="utf-8")
    print(f"merged:         {destination}")


previous: set[str] = set()
manifest_path = root / MANIFEST
if manifest_path.exists():
    previous = {line.strip() for line in manifest_path.read_text().splitlines() if line.strip()}

installed: set[str] = set()


def mark(destination: Path) -> None:
    installed.add(destination.relative_to(root).as_posix())


merge_agents()
merge_hooks()

rules_destination = root / "rules" / "skadi.rules"
write_text(repo / "codex" / "rules" / "skadi.rules", rules_destination)
mark(rules_destination)

for tree_name in ("hooks", "docs"):
    source_root = repo / tree_name
    for source_path in sorted(source_root.rglob("*")):
        if not source_path.is_file() or any(part.startswith(".") for part in source_path.relative_to(source_root).parts):
            continue
        destination = root / tree_name / source_path.relative_to(source_root)
        copy_or_render(source_path, destination)
        mark(destination)

skills_root = repo / "skills"
for source_path in sorted(skills_root.rglob("*")):
    if not source_path.is_file() or any(part.startswith(".") for part in source_path.relative_to(skills_root).parts):
        continue
    destination = root / "skills" / source_path.relative_to(skills_root)
    subprocess.run(
        [sys.executable, str(renderer), str(source_path), str(destination), str(root), profile],
        check=True,
    )
    print(f"installed:      {destination}")
    mark(destination)

for relative in sorted(previous - installed):
    if not relative.startswith(OWNED_PREFIXES) or ".." in Path(relative).parts:
        fail(f"refusing unsafe manifest entry: {relative}")
    stale = root / relative
    if stale.is_file() or stale.is_symlink():
        stale.unlink()
        print(f"pruned:         {stale}")

for directory in sorted((root / prefix.rstrip("/") for prefix in OWNED_PREFIXES), reverse=True):
    if not directory.exists():
        continue
    for candidate in sorted((path for path in directory.rglob("*") if path.is_dir()), reverse=True):
        try:
            candidate.rmdir()
        except OSError:
            pass

manifest_path.write_text("\n".join(sorted(installed)) + "\n", encoding="utf-8")
print(f"manifest:       {manifest_path}")

config = root / "config.toml"
override = root / "AGENTS.override.md"
if override.exists():
    print(
        f"warning: {override} takes precedence over AGENTS.md; include Skadi's managed block there or remove the override",
        file=sys.stderr,
    )
if config.exists() and "hooks = false" in config.read_text(encoding="utf-8"):
    print(f"warning: hooks appear disabled in {config}; enable [features].hooks and review them with /hooks", file=sys.stderr)
else:
    print("next: review and trust the installed hooks with /hooks in a new Codex session")
