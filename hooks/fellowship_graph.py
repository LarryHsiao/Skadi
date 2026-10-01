#!/usr/bin/env python3
"""Generate chapter VI's Mermaid graph from the skills' own frontmatter.

    fellowship_graph.py                          rewrite handbook/skill-fellowship.html
    fellowship_graph.py <skills-dir> <html>      the same, for other paths
    fellowship_graph.py --check [...]            exit 1 if the page is out of step

The graph text keeps the shape the chapter's script parses back into its
network: one `subgraph <LANE>["title"]` per stage, one `ID["/name"]` per skill,
one `A --> B` or `A -.-> B` per edge, and a trailing `linkStyle` naming the mend
edges by index. Lane titles are the one hand-written part — they are bilingual
prose, not data — and live in LANES below.
"""

import re
import sys
from pathlib import Path

import skill_edges

LANES = {
    "vigil": "⟳ VIGIL — timers that ride a sweep · 巡守 — 按時驅動掃描",
    "intake": "I. INTAKE — what brings work in · 進料 — 工作從何而來",
    "plan": "II. PLAN · 規劃",
    "forge": "III. FORGE · 鍛造",
    "weigh": "IV. WEIGH · 衡量",
    "merge": "V. MERGE &amp; SHIP · 合流",
    "watch": "VI. WATCH · 守望",
    "desk": "Off the arc — the desk · 案頭 — 不在主線上的雜務",
}
BEGIN = "<!-- fellowship:begin -->"
END = "<!-- fellowship:end -->"
MEND_STYLE = "stroke:#9a3b2e,stroke-width:2px"
HEAD = "graph LR"


def _node_id(name):
    return name.upper().replace("-", "")


def _lane_order(members, skills):
    """Callers before callees within one lane, ties broken by name."""
    callers = {n: {m for m in members if any(e.target == n for e in skills[m].composes)} for n in members}
    placed = []
    while len(placed) < len(members):
        waiting = [n for n in sorted(members) if n not in placed]
        ready = [n for n in waiting if not callers[n] - set(placed) - {n}]
        placed.append((ready or waiting)[0])
    return placed


def _ordered_names(skills):
    names = []
    for stage in skill_edges.STAGES:
        members = [n for n, s in skills.items() if s.stage == stage]
        names.extend(_lane_order(members, skills))
    return names


def _edge_text(source, edge):
    arrow = "-.->" if edge.kind == "companion" else "-->"
    label = f'|"{edge.label}"|' if edge.label else ""
    return f"{_node_id(source)} {arrow}{label} {_node_id(edge.target)}"


def _edge_lines(skills, names):
    """Dispatch edges, then companion edges, then mend edges — and the mend count."""
    pairs = [(n, e) for n in names for e in skills[n].composes if e.target in skills]
    plain = [(n, e) for n, e in pairs if not e.mend]
    mend = [(n, e) for n, e in pairs if e.mend]
    ordered = (
        [p for p in plain if p[1].kind == "dispatch"]
        + [p for p in plain if p[1].kind == "companion"]
        + mend
    )
    return [_edge_text(n, e) for n, e in ordered], len(mend)


def _lane_block(stage, names, skills):
    members = [n for n in names if skills[n].stage == stage]
    lines = [f'    subgraph {stage.upper()}["{LANES[stage]}"]', "      direction TB"]
    lines += [f'      {_node_id(n)}["/{n}"]' for n in members]
    return lines + ["    end", ""]


def _isolates(skills):
    wired = {n for n, s in skills.items() if s.composes}
    wired |= {e.target for s in skills.values() for e in s.composes}
    return [n for n in sorted(skills) if n not in wired]


def render_graph(skills):
    unplaced = [n for n, s in skills.items() if s.stage not in skill_edges.STAGES]
    if unplaced:
        raise ValueError(f"skills with no known stage: {', '.join(sorted(unplaced))}")
    names = _ordered_names(skills)
    lines = [HEAD]
    for stage in skill_edges.STAGES:
        if any(skills[n].stage == stage for n in names):
            lines += _lane_block(stage, names, skills)
    edges, mend_count = _edge_lines(skills, names)
    lines += [f"    {e}" for e in edges] + [""]
    lines += _style_lines(skills, len(edges), mend_count)
    return "\n".join(lines).rstrip("\n")


def _style_lines(skills, edge_count, mend_count):
    lines = []
    isolates = _isolates(skills)
    if isolates:
        lines += ["    classDef isolate stroke-dasharray:4 3,stroke:#9a3b2e;"]
        lines += [f"    class {','.join(_node_id(n) for n in isolates)} isolate;", ""]
    if mend_count:
        first = edge_count - mend_count
        indices = ",".join(str(i) for i in range(first, edge_count))
        lines += [f"    linkStyle {indices} {MEND_STYLE};"]
    return lines


def splice(page, graph):
    start, stop = page.find(BEGIN), page.find(END)
    if start < 0 or stop < start:
        raise ValueError(f"page needs {BEGIN} … {END} around the graph")
    block = f'{BEGIN}\n<pre class="mermaid">\n{graph}\n</pre>\n'
    return page[:start] + block + page[stop:]


def render_alone(skills, lang):
    """The standalone skills as name spans, joined the way `lang` reads."""
    spans = [f'<span class="name">/{n}</span>' for n in _isolates(skills)]
    if len(spans) < 2:
        return "".join(spans)
    joiner, last = (", ", " and ") if lang == "en" else ("、", " 與 ")
    return joiner.join(spans[:-1]) + last + spans[-1]


def _fill(page, begin, end, body):
    start, stop = page.find(begin), page.find(end)
    if start < 0 or stop < start:
        raise ValueError(f"page needs {begin} … {end}")
    return page[: start + len(begin)] + body + page[stop:]


def generate(page, skills):
    page = splice(page, render_graph(skills))
    for lang in ("en", "zh"):
        begin, end = f"<!-- alone:{lang}:begin -->", f"<!-- alone:{lang}:end -->"
        page = _fill(page, begin, end, render_alone(skills, lang))
    return page


def main(argv):
    args = [a for a in argv[1:] if a != "--check"]
    repo = Path(__file__).resolve().parent.parent
    skills_dir = Path(args[0]) if args else repo / "skills"
    page_path = Path(args[1]) if len(args) > 1 else repo / "handbook" / "skill-fellowship.html"
    skills = skill_edges.load(skills_dir)
    problems = skill_edges.check(skills)
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    page = page_path.read_text(encoding="utf-8")
    updated = generate(page, skills)
    if "--check" in argv:
        return 0 if updated == page else 1
    page_path.write_text(updated, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
