#!/usr/bin/env python3
"""skills-cheatsheet-render.py <skills-dir> <dest-file>

Renders a quick-browse HTML cheatsheet of every skadi skill's name and purpose,
parsed from each <skills-dir>/*/SKILL.md's leading frontmatter, into one
self-contained page at <dest-file>. Drop <dest-file> under Henneth's watched
folder (~/.claude/previews/henneth/) to serve it at its own stable URL.
"""
import re
import sys
from pathlib import Path

FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)

# A clipboard, matching the emoji-favicon convention pulse-scan.py's dashboard uses.
FAVICON_EMOJI = "%F0%9F%93%8B"


def parse_skill(path):
    """(name, description) from a SKILL.md's leading frontmatter block, or None.

    Only the block between the first pair of `---` lines counts — several
    SKILL.md files (e.g. amon-din) show example `name:`/`description:` pairs
    further down in prose, and those must not be mistaken for the real ones.
    """
    text = path.read_text(encoding="utf-8")
    match = FRONTMATTER_RE.match(text)
    if not match:
        return None
    name = description = None
    for line in match.group(1).splitlines():
        if line.startswith("name:"):
            name = line[len("name:"):].strip()
        elif line.startswith("description:"):
            description = line[len("description:"):].strip()
    if not name or not description:
        return None
    return name, description


def collect(skills_dir):
    skills = []
    for skill_md in sorted(Path(skills_dir).glob("*/SKILL.md")):
        parsed = parse_skill(skill_md)
        if parsed:
            skills.append(parsed)
    return sorted(skills, key=lambda s: s[0].lower())


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def render(skills):
    cards = "\n".join(
        '<div class="card" data-hay="%s">'
        '<div class="nm">/%s</div><div class="ds">%s</div></div>'
        % (esc(name.lower() + " " + desc.lower()), esc(name), esc(desc))
        for name, desc in skills
    )
    count = len(skills)
    return """<meta charset="utf-8">
<link rel="stylesheet" href="skadi-theme.css">
<title>Skadi Skills Cheatsheet</title>
<link rel="icon" href="data:image/svg+xml,<svg xmlns=%%22http://www.w3.org/2000/svg%%22 viewBox=%%220 0 16 16%%22><text y=%%2213%%22 font-size=%%2214%%22>%(favicon)s</text></svg>">
<style>
  body { padding: 1.6rem 2rem; max-width: 900px; margin: 0 auto; }
  #q {
    width: 100%%; box-sizing: border-box; padding: 0.5rem 0.7rem; margin: 0.8rem 0 1.1rem;
    border: 1px solid var(--line); border-radius: 6px; background: var(--panel);
    color: var(--ink); font-size: 0.9rem;
  }
  .count { color: var(--accent); font-size: 0.75rem; margin-bottom: 0.6rem; font-family: ui-monospace, Menlo, monospace; }
  .grid { display: flex; flex-direction: column; gap: 0.5rem; }
  .card { border: 1px solid var(--line); border-radius: 6px; background: var(--raise); padding: 0.6rem 0.8rem; }
  .card.hidden { display: none; }
  .nm { font-family: ui-monospace, Menlo, monospace; font-size: 0.85rem; color: var(--blue); margin-bottom: 0.25rem; }
  .ds { font-size: 0.82rem; line-height: 1.45; }
  .empty { color: var(--accent); font-style: italic; padding: 2rem; text-align: center; }
</style>
<h1>Skadi Skills Cheatsheet</h1>
<p class="sub">%(count)d skill%(plural)s — the custom skills authored in this repo.</p>
<input id="q" type="search" placeholder="Filter by name or purpose&hellip;" autofocus>
<div class="count" id="count"></div>
<div class="grid" id="grid">
%(cards)s
</div>
<div class="empty" id="empty" style="display:none">No skill matches.</div>
<script>
  const q = document.getElementById("q");
  const cards = [...document.querySelectorAll(".card")];
  const count = document.getElementById("count");
  const empty = document.getElementById("empty");
  function filter() {
    const term = q.value.trim().toLowerCase();
    let shown = 0;
    for (const c of cards) {
      const hit = !term || c.dataset.hay.includes(term);
      c.classList.toggle("hidden", !hit);
      if (hit) shown++;
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
        "cards": cards,
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
