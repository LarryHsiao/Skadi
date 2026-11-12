#!/usr/bin/env python3
"""Lint the skills against the handbook.

    handbook_skills.py                     check the committed tree
    handbook_skills.py <skills-dir> <handbook-dir>

Two things must hold, and each failure prints one sentence and exits 1:

  - every skill under `skills/` is named as `/name` on some handbook page;
  - every `/name` the handbook writes is a skill or listed in NOT_SKILLS.

A path such as `docs/workflow` or `~/.claude/hooks` is not a `/name`: the
slash must open a word, and nothing path-like may follow it.
"""

import re
import sys
from pathlib import Path

# Slash-names the handbook writes that are no directory under skills/.
NOT_SKILLS = {
    "clear",      # Claude Code built-in
    "loop",       # Claude Code built-in
    "statusline", # Claude Code built-in
    "install",    # lives in .claude/skills/, not skills/
    "name",       # a placeholder in a usage example
}
TAG_RE = re.compile(r"<[^>]+>")
# A name is three or more characters, hyphens only between them. A trailing
# period ends a sentence, but a period before a word (`/x.sh`) is a file.
SLASH_NAME_RE = re.compile(r"(?<![\w/.~-])/([a-z](?:[a-z0-9]|-(?=[a-z0-9])){2,})(?![\w/]|-\w|\.\w)")


def _named(handbook_text):
    return set(SLASH_NAME_RE.findall(TAG_RE.sub(" ", handbook_text)))


def problems(skill_names, handbook_text, not_skills):
    named = _named(handbook_text)
    missing = [f"{name}: no handbook page names /{name}" for name in sorted(skill_names - named)]
    stale = [f"handbook names /{name}, which is no skill" for name in sorted(named - skill_names - not_skills)]
    return missing + stale


def check(skills_dir, handbook_dir):
    skill_names = {path.parent.name for path in Path(skills_dir).glob("*/SKILL.md")}
    pages = sorted(Path(handbook_dir).glob("*.html"))
    text = "\n".join(page.read_text(encoding="utf-8") for page in pages)
    return problems(skill_names, text, NOT_SKILLS)


def main(argv):
    root = Path(__file__).resolve().parent.parent
    skills_dir = Path(argv[1]) if len(argv) > 2 else root / "skills"
    handbook_dir = Path(argv[2]) if len(argv) > 2 else root / "handbook"
    found = check(skills_dir, handbook_dir)
    for problem in found:
        print(problem)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
