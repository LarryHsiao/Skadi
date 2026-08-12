#!/usr/bin/env python3
"""Render one source skill resource into a Codex-compatible installed copy."""

from __future__ import annotations

import json
import os
import re
import shutil
import stat
import sys
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"render-codex-skill: {message}")


if len(sys.argv) != 5:
    fail("expected <source> <destination> <codex-root> <profile>")

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
codex_root = Path(sys.argv[3])
profile = sys.argv[4]

try:
    text = source.read_text(encoding="utf-8")
except UnicodeDecodeError:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    raise SystemExit(0)

home = str(Path.home())
paired = {
    "~/.claude-personal": f"{home}/.codex-personal",
    "~/.claude-work": f"{home}/.codex-work",
    "~/.claude": str(codex_root),
}
for old, new in paired.items():
    text = text.replace(old, new)

text = text.replace("CLAUDE_PROJECT_DIR", "CODEX_PROJECT_DIR")
text = text.replace("Claude Code", "Claude Code or Codex")
text = text.replace("claude.ai connector", "authenticated workspace connector")
text = text.replace("AskUserQuestion", "the structured user-input tool")
text = text.replace("via the Agent tool", "with a subagent")
text = text.replace("the Agent tool", "the subagent tool")
text = text.replace("ScheduleWakeup", "the in-chat scheduled-task tool")
text = re.sub(r"`model: (?:haiku|sonnet|opus|fable)`", "the appropriate current capability tier", text)
text = re.sub(r"model: (?:haiku|sonnet|opus|fable)", "model: strongest suitable current model", text)

skills_root = next((parent for parent in source.parents if parent.name == "skills"), None)
if skills_root is None:
    fail(f"source is not under a skills directory: {source}")
skill_names = sorted(
    ({path.name for path in skills_root.iterdir() if path.is_dir()} | {"install"}),
    key=len,
    reverse=True,
)
for name in skill_names:
    text = re.sub(rf"(?<![\w$])/{re.escape(name)}\b", f"${name}", text)

if source.name == "SKILL.md" and text.startswith("---\n"):
    end = text.find("\n---\n", 4)
    if end < 0:
        fail(f"unterminated frontmatter: {source}")
    frontmatter = text[4:end].splitlines()
    fields = {}
    for line in frontmatter:
        if line.startswith("name:") or line.startswith("description:"):
            key, value = line.split(":", 1)
            fields[key] = value.strip()
    if set(fields) != {"name", "description"}:
        fail(f"frontmatter must contain name and description: {source}")
    body = text[end + 5 :]
    codex_name = source.parent.name
    codex_description = fields["description"].replace("<", "[").replace(">", "]")
    if len(codex_description) > 1000:
        codex_description = codex_description[:999].rsplit(" ", 1)[0].rstrip(" ,;:-") + "…"
    compatibility = f"""
## Codex compatibility

- Invoke this workflow as `${source.parent.name}`. Any `/name` examples inherited
  from Claude mean the equivalent `$name` Codex skill.
- Resolve every named workflow-memory file through
  `{codex_root}/hooks/skadi-state.sh path {profile} \"$PWD\" <filename>`.
  This neutral per-profile store takes precedence over later references to
  Claude auto-memory or Codex chat memory.
- Use Codex's structured user-input and subagent tools where this skill names
  their Claude equivalents. If a scheduled-task capability is unavailable on
  the current surface, stop and give the manual rerun or desktop scheduling
  instruction; do not pretend a watch was armed.

"""
    rendered_frontmatter = (
        "name: " + json.dumps(codex_name, ensure_ascii=False) + "\n"
        "description: " + json.dumps(codex_description, ensure_ascii=False)
    )
    text = "---\n" + rendered_frontmatter + "\n---\n" + compatibility + body

destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(text, encoding="utf-8")
mode = source.stat().st_mode
os.chmod(destination, stat.S_IMODE(mode))
