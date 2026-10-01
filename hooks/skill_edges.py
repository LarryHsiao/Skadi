#!/usr/bin/env python3
"""Read the composition edges each SKILL.md declares, and check them.

A skill may carry two one-line frontmatter keys:

    stage: forge
    composes: commit:dispatch, mithrandir:companion+mend|weighed again

`stage` names the lane the skill stands in on the fellowship graph; `composes`
lists the skills it relates to, in order. An entry is `<skill>:<kind>`, then an
optional `+mend` (the one red review cycle) and an optional `|<label>`; the
kinds are the chapter's own — `dispatch` (calls it) and `companion` (names it,
does not call it). Both keys are one line because every other reader of this
frontmatter is line-based, so a label may not hold a comma.

`check` reports every way a declaration can disagree with the tree as one
plain sentence; an empty list means the declared graph can be drawn as is.
"""

import re
import sys
from dataclasses import dataclass
from pathlib import Path

FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)

STAGES = ("vigil", "intake", "plan", "forge", "weigh", "merge", "watch", "desk")
KINDS = ("dispatch", "companion")


@dataclass(frozen=True)
class Edge:
    target: str
    kind: str
    mend: bool = False
    label: str = ""


@dataclass(frozen=True)
class Skill:
    name: str
    stage: str | None
    composes: tuple
    body: str


def _edge(entry):
    head, _, label = entry.strip().partition("|")
    target, sep, kind = head.partition(":")
    kind, plus, flag = kind.partition("+")
    if not sep or not target.strip() or not kind.strip() or (plus and flag.strip() != "mend"):
        raise ValueError(f"composes entry {entry!r} must read <skill>:<kind>[+mend][|label]")
    return Edge(target.strip(), kind.strip(), mend=bool(plus), label=label.strip())


def parse_declaration(frontmatter):
    """(stage, [Edge, ...]) from a frontmatter block's text."""
    stage = None
    edges = []
    seen = set()
    for line in frontmatter.splitlines():
        key = line.partition(":")[0]
        if key not in ("stage", "composes"):
            continue
        if key in seen:
            raise ValueError(f"frontmatter declares {key!r} twice")
        seen.add(key)
        value = line[len(key) + 1:]
        if key == "stage":
            stage = value.strip() or None
        else:
            edges = [_edge(e) for e in value.split(",") if e.strip()]
    return stage, edges


def load(skills_dir):
    """{name: Skill} for every SKILL.md under `skills_dir`.

    The key is the directory name — what the skill is invoked by — because a
    frontmatter `name:` may differ from it (`reset` carries `git-reset`). A file
    with no frontmatter still loads, with no stage, so `check` names it.
    """
    found = {}
    for path in sorted(Path(skills_dir).glob("*/SKILL.md")):
        text = path.read_text(encoding="utf-8")
        match = FRONTMATTER_RE.match(text)
        stage, edges = parse_declaration(match.group(1)) if match else (None, [])
        body = text[match.end():] if match else text
        found[path.parent.name] = Skill(path.parent.name, stage, tuple(edges), body)
    return found


def _mentions(body, target):
    """True when the body names the skill as `/name` or in bold as `**Name**`."""
    slash = rf"(?<![\w/.~-])/{re.escape(target)}(?![\w-])"
    bold = rf"\*\*{re.escape(target)}\*\*"
    return re.search(slash, body) is not None or re.search(bold, body, re.I) is not None


def _edge_problems(skill, skills):
    problems = []
    seen = set()
    for edge in skill.composes:
        target, kind = edge.target, edge.kind
        where = f"{skill.name} -> {target}"
        if target == skill.name:
            problems.append(f"{where}: a skill cannot compose itself")
        elif target not in skills:
            problems.append(f"{where}: no skill named {target!r}")
        elif not _mentions(skill.body, target):
            problems.append(f"{where}: declared, but {skill.name}'s body never mentions /{target}")
        if kind not in KINDS:
            problems.append(f"{where}: unknown kind {kind!r}, expected one of {KINDS}")
        if target in seen:
            problems.append(f"{where}: declared twice")
        seen.add(target)
    return problems


def _is_one_cycle(successors):
    """True when `successors` ({node: [next, ...]}) is a single closed ring."""
    nodes = set(successors) | {t for targets in successors.values() for t in targets}
    if set(successors) != nodes or any(len(t) != 1 for t in successors.values()):
        return False
    start = next(iter(nodes))
    walked = [start]
    here = successors[start][0]
    while here != start and here not in walked:
        walked.append(here)
        here = successors[here][0]
    return here == start and len(walked) == len(nodes)


def _mend_problems(skills):
    successors = {}
    for skill in skills.values():
        for edge in skill.composes:
            if edge.mend:
                successors.setdefault(skill.name, []).append(edge.target)
    if not successors or _is_one_cycle(successors):
        return []
    return [f"mend edges do not form one closed cycle: from {sorted(successors)}"]


def check(skills):
    problems = _mend_problems(skills)
    for skill in skills.values():
        if skill.stage is None:
            problems.append(f"{skill.name}: has no stage")
        elif skill.stage not in STAGES:
            problems.append(f"{skill.name}: unknown stage {skill.stage!r}, expected one of {STAGES}")
        problems.extend(_edge_problems(skill, skills))
    return problems


def main(argv):
    skills_dir = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parent.parent / "skills"
    problems = check(load(skills_dir))
    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
