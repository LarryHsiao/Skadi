#!/usr/bin/env python3
"""skills-cheatsheet-render.py <skills-dir> <dest-file>

Renders a quick-browse HTML cheatsheet of every skadi skill's name and purpose,
parsed from each <skills-dir>/*/SKILL.md's leading frontmatter, into one
self-contained page at <dest-file>. Drop <dest-file> under Henneth's watched
folder (~/.skadi/henneth/) to serve it at its own stable URL.

A card expands on click to show the skill's full description and its invocation
grammar. No SKILL.md declares that grammar in frontmatter, so it is read out of
prose — see `invocations`, and `hooks/test_skills_cheatsheet.py` for the shapes
that reading must survive.
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


# Skills whose road is also drawn as a handbook chapter. The handbook rides the
# situation board's server (default port 10000), while this page is served by
# Henneth — so the link must cross ports, as the handbook's own cheatsheet entry
# already does in the other direction. A card links nothing when the board is
# not up; the chapter is still reachable through ./handbook.sh.
BOARD_URL = "http://localhost:10000"
SKILL_DIAGRAMS = {
    "rumil": ("rumil-flow.html", "The Rúmil Road"),
}


def group_of(name):
    return SKILL_GROUPS.get(name, OTHER_GROUP)


def diagram_html(name):
    """The link to a skill's handbook chapter, or "" for a skill without one."""
    chapter = SKILL_DIAGRAMS.get(name)
    if not chapter:
        return ""
    page, title = chapter
    return '<p class="diagram">&#9636; <a href="%s/handbook/%s" target="_blank" rel="noopener">%s</a> — handbook chapter</p>' % (
        BOARD_URL, esc(page), esc(title),
    )


# A form list in a description ends at a sentence break, or at the em dash
# several descriptions use to introduce what the skill then does. The lookbehind
# spares an ellipsis inside a form — `/amon-din remove <id>...` ends in a period
# and a space without the sentence being over.
SENTENCE_BREAK = re.compile(r"(?<!\.)\. ")
EM_DASH_BREAK = " — "

# English connectives that never open an argument. A description often runs the
# grammar straight into its prose with no comma between — "/branch [target]
# [strategy] to switch to a target branch" — and without this list the prose is
# swallowed into the form, showing the reader a grammar no one wrote.
STOP_WORDS = (
    "to|or|and|for|with|when|while|at|in|on|of|from|into|over|per|before|after|"
    "so|that|if|as|by|the|a|an|is|are|it|its|this|these|then|says|asks"
)

# The pieces an argument is built from: a placeholder, a bracketed optional, a
# flag, an ellipsis, or a bare subcommand.
ATOM = r"(?:<[^>]+>|\[[^\]]*\]|--?[\w-]+|=|\.\.\.|[A-Za-z@][\w.:@-]*)"

# One argument is a run of atoms with no space between them, so the glued
# shapes survive whole — `<id>[:<label>]...` and `--project=<KEY>` are each one
# argument, and a rule that demanded whitespace would cut them at the seam. The
# lookahead keeps a run from starting on a connective, which is where prose
# begins.
ARGUMENT = r"(?!(?:" + STOP_WORDS + r")\b)" + ATOM + r"+"


def form_pattern(name):
    """A skill's invocation form: its slash-name, then whatever arguments follow.

    The lookbehind keeps the slash from matching inside a path — `/publish` in
    "collect into build/publish/" is not an invocation, and reading it as one
    hides the real clause further down the same description.
    """
    return re.compile(r"(?<![\w/])" + re.escape("/" + name) + r"(?:\s+" + ARGUMENT + r")*")


def _dedupe(forms):
    """The forms, first occurrence order kept."""
    seen = set()
    return [f for f in forms if not (f in seen or seen.add(f))]


def _run_of_forms(pattern, description):
    """The stretch of description holding the form list, or "" when it names none.

    Bounded at the sentence break or em dash that ends the list, so a later
    mention of the same skill in prose cannot be read as another form.
    """
    first = pattern.search(description)
    if not first:
        return ""
    run = description[first.start():]
    stops = [len(run)]
    sentence = SENTENCE_BREAK.search(run)
    if sentence:
        stops.append(sentence.start())
    dash = run.find(EM_DASH_BREAK)
    if dash >= 0:
        stops.append(dash)
    return run[:min(stops)]


def _forms_from_description(name, description):
    """Every `/<name> …` form in the description's leading run."""
    pattern = form_pattern(name)
    return [m.group(0).strip() for m in pattern.finditer(_run_of_forms(pattern, description))]


def _forms_from_body(name, body):
    """Usage lines — a body line whose first token is the skill's own slash."""
    pattern = form_pattern(name)
    forms = []
    for line in body.splitlines():
        stripped = line.strip().lstrip("-*` ")
        if not stripped.startswith("/" + name):
            continue
        match = pattern.match(stripped)
        if match:
            forms.append(match.group(0).strip())
    return forms


def invocations(name, description, body):
    """Every documented invocation form for a skill, in the order found.

    The description is read first — it is the curated summary, and 39 of the 51
    skills open with the form list. A body usage block answers only when the
    description carries none, since a block further down may be a stale example.
    Returns [] when neither documents a grammar: a card that shows nothing is
    honest, where one showing a guess is not.
    """
    forms = _forms_from_description(name, description) or _forms_from_body(name, body)
    return _dedupe(forms)


def parse_skill(path):
    """(name, description, purpose, invocations) from a SKILL.md, or None.

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
    return name, description, purpose, invocations(name, description, text[match.end():])


def collect(skills_dir):
    skills = []
    for skill_md in sorted(Path(skills_dir).glob("*/SKILL.md")):
        parsed = parse_skill(skill_md)
        if parsed:
            skills.append(parsed)
    return sorted(skills, key=lambda s: s[0].lower())


def esc(s):
    """HTML-escape, quotes included — the result fills double-quoted attributes.

    Six descriptions carry a literal quote; unescaped, it closed `data-hay`
    early and the rest of the sentence was parsed as bogus attributes, taking
    the filter's search text with it.
    """
    return (
        s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
    )


CARD_DESC_LIMIT = 110


def short_desc(desc, limit=CARD_DESC_LIMIT):
    """desc, cut to limit at the last word boundary, ellipsis if it was cut."""
    if len(desc) <= limit:
        return desc
    cut = desc[:limit].rsplit(" ", 1)[0]
    return cut + "…"


NO_PARAMS = "no parameters documented"


def params_html(forms):
    """The parameters block — the real grammar, or an admission that none was found."""
    if not forms:
        return '<p class="ghost">%s</p>' % NO_PARAMS
    return '<div class="prec">%s</div>' % esc("\n".join(forms))


def card_html(name, description, purpose, forms):
    """One card: the collapsed line, and the body a click reveals.

    The body ships in the HTML rather than being fetched — the page is
    generated and served from disk, so there is nothing to fetch from.
    """
    display = purpose if purpose else description
    hay = " ".join(filter(None, [name, description, purpose])).lower()
    return (
        '<div class="card" data-hay="%s" role="button" tabindex="0" aria-expanded="false">'
        '<span class="chev">&rsaquo;</span>'
        '<div class="nm">/%s</div><div class="ds">%s</div>'
        '<div class="body" hidden>'
        '<div class="lbl">Parameters</div>%s'
        '<div class="lbl">What it does</div><p class="full">%s</p>%s'
        "</div></div>"
        % (esc(hay), esc(name), esc(short_desc(display)), params_html(forms),
           esc(description), diagram_html(name))
    )


def groups_html(skills):
    buckets = {}
    for skill in skills:
        buckets.setdefault(group_of(skill[0]), []).append(skill)
    sections = []
    for group in GROUP_ORDER:
        members = buckets.get(group)
        if not members:
            continue
        cards = "\n".join(card_html(*member) for member in members)
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
  .card {
    border: 1px solid var(--line); border-radius: 6px; background: var(--raise);
    padding: 0.6rem 0.8rem; cursor: pointer; position: relative;
  }
  .card:hover { border-color: var(--accent); }
  .card.hidden { display: none; }
  /* The open card takes the whole row, so its neighbours never shuffle sideways. */
  .card.open { grid-column: 1 / -1; background: var(--panel); border-color: var(--accent); cursor: default; }
  .nm { font-family: ui-monospace, Menlo, monospace; font-size: 0.85rem; color: var(--blue); margin-bottom: 0.25rem; }
  .ds { font-size: 0.82rem; line-height: 1.45; }
  .card.open .ds { color: #6b5c45; }
  .chev { position: absolute; top: 0.55rem; right: 0.7rem; color: var(--accent); font-size: 0.75rem; }
  .body { margin-top: 0.7rem; border-top: 1px dashed var(--line); padding-top: 0.7rem; }
  .lbl {
    font-family: ui-monospace, Menlo, monospace; font-size: 0.7rem; color: var(--accent);
    letter-spacing: 0.04em; text-transform: uppercase; margin: 0 0 0.25rem;
  }
  .body .lbl + * { margin-top: 0; margin-bottom: 0.7rem; }
  .full { font-size: 0.85rem; line-height: 1.5; margin: 0; }
  .ghost { color: #9b8b70; font-style: italic; font-size: 0.85rem; margin: 0; }
  .diagram { font-size: 0.82rem; margin: 0.7rem 0 0; }
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
  const CHEVRON = { open: "⌄", closed: "›" };
  function setOpen(card, on) {
    card.classList.toggle("open", on);
    card.querySelector(".body").hidden = !on;
    card.querySelector(".chev").textContent = on ? CHEVRON.open : CHEVRON.closed;
    card.setAttribute("aria-expanded", String(on));
  }
  // One card open at a time: a second open card pushes the first far off screen.
  function toggle(card) {
    const wasOpen = card.classList.contains("open");
    for (const c of cards) setOpen(c, false);
    setOpen(card, !wasOpen);
  }
  for (const c of cards) {
    c.addEventListener("click", () => toggle(c));
    c.addEventListener("keydown", (e) => {
      if (e.key !== "Enter" && e.key !== " ") return;
      e.preventDefault();   // Space would scroll the page out from under the card
      toggle(c);
    });
  }

  function filter() {
    const term = q.value.trim().toLowerCase();
    let shown = 0;
    for (const g of groups) {
      let shownInGroup = 0;
      for (const c of g.querySelectorAll(".card")) {
        const hit = !term || c.dataset.hay.includes(term);
        c.classList.toggle("hidden", !hit);
        // An open card filtered away would stay open off-screen.
        if (!hit) setOpen(c, false);
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
