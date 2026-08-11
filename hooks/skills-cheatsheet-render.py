#!/usr/bin/env python3
"""skills-cheatsheet-render.py <skills-dir> <dest-file>

Renders a quick-browse HTML cheatsheet of every skadi skill's name and purpose,
parsed from each <skills-dir>/*/SKILL.md's leading frontmatter, into one
self-contained page at <dest-file>. Drop <dest-file> under Henneth's watched
folder (~/.skadi/henneth/) to serve it at its own stable URL.
"""
import re
import sys
from pathlib import Path

FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)

# A clipboard, matching the emoji-favicon convention pulse-scan.py's dashboard uses.
FAVICON_EMOJI = "%F0%9F%93%8B"

OTHER_GROUP = "Other"

# Purpose groups, in browsing order. A skill not listed here falls into
# OTHER_GROUP rather than breaking the render — new skills land there until
# this map is updated.
GROUP_ORDER = [
    "Plan & Council",
    "Forge & Mend",
    "Review & Gate",
    "Dashboards & Previews",
    "Trackers & Reports",
    "Comms",
    "Git & Repo",
    "Release",
    "Maintenance & Utility",
    OTHER_GROUP,
]

SKILL_GROUPS = {
    "council": "Plan & Council",
    "glorfindel": "Plan & Council",
    "rumil": "Plan & Council",
    "galadriel": "Plan & Council",
    "celebrimbor": "Forge & Mend",
    "aule": "Forge & Mend",
    "anduin": "Forge & Mend",
    "narvi": "Forge & Mend",
    "durin": "Forge & Mend",
    "moria": "Forge & Mend",
    "rhovanion": "Forge & Mend",
    "working": "Forge & Mend",
    "amon-sul": "Forge & Mend",
    "mithrandir": "Review & Gate",
    "nazgul": "Review & Gate",
    "argonath": "Review & Gate",
    "lindir": "Review & Gate",
    "mandos": "Review & Gate",
    "fidelity": "Review & Gate",
    "board": "Dashboards & Previews",
    "henneth": "Dashboards & Previews",
    "growth": "Dashboards & Previews",
    "este": "Dashboards & Previews",
    "minuial": "Dashboards & Previews",
    "manwe": "Review & Gate",
    "daily": "Trackers & Reports",
    "jira": "Trackers & Reports",
    "prs": "Trackers & Reports",
    "mrs": "Trackers & Reports",
    "palantir": "Trackers & Reports",
    "eod": "Trackers & Reports",
    "amon-din": "Trackers & Reports",
    "gwaihir": "Comms",
    "triage": "Comms",
    "vor": "Comms",
    "branch": "Git & Repo",
    "commit": "Git & Repo",
    "stage": "Git & Repo",
    "summary": "Git & Repo",
    "git-reset": "Git & Repo",
    "celebrant": "Git & Repo",
    "publish": "Release",
    "publish-macos": "Release",
    "cleanup-dev": "Maintenance & Utility",
    "preflight": "Maintenance & Utility",
    "focus": "Maintenance & Utility",
    "handoff": "Maintenance & Utility",
    "remember": "Maintenance & Utility",
    "feanor": "Maintenance & Utility",
    "scribe": "Maintenance & Utility",
}


def group_of(name):
    return SKILL_GROUPS.get(name, OTHER_GROUP)


def parse_skill(path):
    """(name, description, purpose) from a SKILL.md's leading frontmatter, or None.

    `purpose` is None when the frontmatter carries no `purpose:` line — older
    or third-party skills fall back to a truncated `description` for display.

    Only the block between the first pair of `---` lines counts — several
    SKILL.md files (e.g. amon-din) show example `name:`/`description:` pairs
    further down in prose, and those must not be mistaken for the real ones.
    """
    text = path.read_text(encoding="utf-8")
    match = FRONTMATTER_RE.match(text)
    if not match:
        return None
    name = description = purpose = None
    for line in match.group(1).splitlines():
        if line.startswith("name:"):
            name = line[len("name:"):].strip()
        elif line.startswith("description:"):
            description = line[len("description:"):].strip()
        elif line.startswith("purpose:"):
            purpose = line[len("purpose:"):].strip()
    if not name or not description:
        return None
    return name, description, purpose


def collect(skills_dir):
    skills = []
    for skill_md in sorted(Path(skills_dir).glob("*/SKILL.md")):
        parsed = parse_skill(skill_md)
        if parsed:
            skills.append(parsed)
    return sorted(skills, key=lambda s: s[0].lower())


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


CARD_DESC_LIMIT = 110


def short_desc(desc, limit=CARD_DESC_LIMIT):
    """desc, cut to limit at the last word boundary, ellipsis if it was cut."""
    if len(desc) <= limit:
        return desc
    cut = desc[:limit].rsplit(" ", 1)[0]
    return cut + "…"


def card_html(name, description, purpose):
    display = purpose if purpose else description
    hay = " ".join(filter(None, [name, description, purpose])).lower()
    return (
        '<div class="card" data-hay="%s">'
        '<div class="nm">/%s</div><div class="ds" title="%s">%s</div></div>'
        % (esc(hay), esc(name), esc(description), esc(short_desc(display)))
    )


def groups_html(skills):
    buckets = {}
    for name, description, purpose in skills:
        buckets.setdefault(group_of(name), []).append((name, description, purpose))
    sections = []
    for group in GROUP_ORDER:
        members = buckets.get(group)
        if not members:
            continue
        cards = "\n".join(card_html(name, description, purpose) for name, description, purpose in members)
        sections.append(
            '<div class="group" data-group="%s">'
            '<h2 class="grp-hd">%s <span class="grp-count">%d</span></h2>'
            '<div class="grid">\n%s\n</div></div>'
            % (esc(group), esc(group), len(members), cards)
        )
    return "\n".join(sections)


def render(skills):
    count = len(skills)
    return """<meta charset="utf-8">
<link rel="stylesheet" href="skadi-theme.css">
<title>Skadi Skills Cheatsheet</title>
<link rel="icon" href="data:image/svg+xml,<svg xmlns=%%22http://www.w3.org/2000/svg%%22 viewBox=%%220 0 16 16%%22><text y=%%2213%%22 font-size=%%2214%%22>%(favicon)s</text></svg>">
<style>
  body { padding: 1.6rem 2rem; max-width: 1180px; margin: 0 auto; }
  #q {
    width: 100%%; box-sizing: border-box; padding: 0.5rem 0.7rem; margin: 0.8rem 0 1.1rem;
    border: 1px solid var(--line); border-radius: 6px; background: var(--panel);
    color: var(--ink); font-size: 0.9rem;
  }
  .count { color: var(--accent); font-size: 0.75rem; margin-bottom: 1rem; font-family: ui-monospace, Menlo, monospace; }
  .group { margin-bottom: 1.6rem; }
  .group.hidden { display: none; }
  .grp-hd {
    font-size: 0.95rem; margin: 0 0 0.6rem; padding-bottom: 0.3rem;
    border-bottom: 1px solid var(--line);
  }
  .grp-count { color: var(--accent); font-size: 0.75rem; font-weight: normal; font-family: ui-monospace, Menlo, monospace; }
  .grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 0.6rem; }
  @media (max-width: 860px) { .grid { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
  @media (max-width: 480px) { .grid { grid-template-columns: 1fr; } }
  .card { border: 1px solid var(--line); border-radius: 6px; background: var(--raise); padding: 0.6rem 0.8rem; }
  .card.hidden { display: none; }
  .nm { font-family: ui-monospace, Menlo, monospace; font-size: 0.85rem; color: var(--blue); margin-bottom: 0.25rem; }
  .ds { font-size: 0.82rem; line-height: 1.45; }
  .empty { color: var(--accent); font-style: italic; padding: 2rem; text-align: center; }
</style>
<h1>Skadi Skills Cheatsheet</h1>
<p class="sub">%(count)d skill%(plural)s, grouped by purpose — the custom skills authored in this repo.</p>
<input id="q" type="search" placeholder="Filter by name or purpose&hellip;" autofocus>
<div class="count" id="count"></div>
<div id="groups">
%(groups)s
</div>
<div class="empty" id="empty" style="display:none">No skill matches.</div>
<script>
  const q = document.getElementById("q");
  const groups = [...document.querySelectorAll(".group")];
  const cards = [...document.querySelectorAll(".card")];
  const count = document.getElementById("count");
  const empty = document.getElementById("empty");
  function filter() {
    const term = q.value.trim().toLowerCase();
    let shown = 0;
    for (const g of groups) {
      let shownInGroup = 0;
      for (const c of g.querySelectorAll(".card")) {
        const hit = !term || c.dataset.hay.includes(term);
        c.classList.toggle("hidden", !hit);
        if (hit) { shown++; shownInGroup++; }
      }
      g.classList.toggle("hidden", shownInGroup === 0);
    }
    count.textContent = shown + " / " + cards.length + " shown";
    empty.style.display = shown ? "none" : "block";
  }
  q.addEventListener("input", filter);
  filter();
</script>
""" % {
        "favicon": FAVICON_EMOJI,
        "count": count,
        "plural": "" if count == 1 else "s",
        "groups": groups_html(skills),
    }


def main(argv):
    if len(argv) != 3:
        print("usage: skills-cheatsheet-render.py <skills-dir> <dest-file>", file=sys.stderr)
        return 2
    skills_dir, dest = argv[1], Path(argv[2])
    skills = collect(skills_dir)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(render(skills), encoding="utf-8")
    print("rendered %d skill(s) -> %s" % (len(skills), dest))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
