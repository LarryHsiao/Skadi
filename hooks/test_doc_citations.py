#!/usr/bin/env python3
"""Guards the `galadriel-render.py:<line>` citations the skills' prose makes.

Several skill documents cite a line of the renderer as evidence for a claim
about it — "every checkbox line is collected as a step (galadriel-render.py:112)".
Nothing bound those numbers to the code, and they have drifted twice: a reader
following one landed on a blank line, on a `try:`, or ninety lines from the
function named beside it.

The binding is deliberately one-way. Each entry below names the construct a
citation must land on, never the line it sits at; the number is read out of the
prose. So when the renderer grows, this fails and the *prose* is corrected — the
table only changes when the code itself changes shape.
"""

import re
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
RENDERER = HERE / "galadriel-render.py"

# Both forms the prose uses: the full name, and the bare continuation a sentence
# reaches for when it cites a second line of the same file ("called from `:402`").
CITATION = re.compile(r"galadriel-render\.py:(\d+)|from `:(\d+)`")

# The documents whose citations describe the renderer as it stands now.
CITING_DOCS = ("skills/rumil/format.md", "skills/rumil/SKILL.md", "skills/galadriel/SKILL.md")

# (document, the phrase its citation follows, the construct that line must carry).
# The phrase is matched against whitespace-collapsed text, so a citation still
# resolves when markdown wraps it onto the next line.
CITATIONS = (
    ("skills/rumil/format.md", "decided by `inline()`", "const inline"),
    ("skills/rumil/format.md", "is collected as a step, whatever heading it sits under", "steps.append"),
    ("skills/rumil/format.md", "are dropped from the overview walk", "HEADING_LINE.match"),
    ("skills/rumil/format.md", "code, bold, italic and nothing else", "const inline"),
    ("skills/rumil/format.md", ", called from", "inline(p)"),
    ("skills/rumil/SKILL.md", "refuses any preview path resolving outside the plans folder", "base_dir not in target.parents"),
    ("skills/galadriel/SKILL.md", "refreshes when the bytes change", "fetch(location.href"),
)


def flat(path):
    """A document's text with every run of whitespace collapsed to one space."""
    return re.sub(r"\s+", " ", (REPO / path).read_text(encoding="utf-8"))


def cited_line(doc, phrase):
    """The line number the first citation after `phrase` names, or None if unfound."""
    text = flat(doc)
    start = text.find(phrase)
    if start < 0:
        return None
    match = CITATION.search(text, start)
    if not match:
        return None
    return int(match.group(1) or match.group(2))


class CitationTest(unittest.TestCase):
    def setUp(self):
        self.source = RENDERER.read_text(encoding="utf-8").splitlines()

    def test_every_citation_lands_on_what_its_sentence_claims(self):
        expected_astray = []
        astray = []
        for doc, phrase, construct in CITATIONS:
            line = cited_line(doc, phrase)
            if line is None:
                astray.append(f"{doc}: no citation found after {phrase!r}")
            elif not 1 <= line <= len(self.source):
                astray.append(f"{doc} cites :{line}, past the end of {RENDERER.name}")
            elif construct not in self.source[line - 1]:
                astray.append(
                    f"{doc} cites :{line} for {construct!r}, but that line reads "
                    f"{self.source[line - 1].strip()!r}"
                )
        self.assertEqual(expected_astray, astray)

    def test_every_construct_stands_in_one_place_only(self):
        """An anchor with a twin would let a stale number land on the wrong line.

        The check above asks whether the cited line carries the construct, not
        whether it is the only line that could. Should the renderer ever grow a
        second `steps.append`, this fails first and says which anchor needs a
        narrower fragment.
        """
        expected_ambiguous = []
        ambiguous = [
            f"{construct!r} stands on {n} lines of {RENDERER.name}"
            for construct in {c for _doc, _phrase, c in CITATIONS}
            if (n := sum(construct in line for line in self.source)) != 1
        ]
        self.assertEqual(expected_ambiguous, ambiguous)

    def test_no_citation_in_the_skills_tree_goes_unguarded(self):
        """A citation written without an entry above would drift unwatched."""
        expected = len(CITATIONS)
        found = sum(len(CITATION.findall(flat(doc))) for doc in CITING_DOCS)
        self.assertEqual(expected, found)

    def test_the_skills_tree_carries_no_citing_document_this_guard_forgot(self):
        """A new skill citing the renderer must be added to CITING_DOCS."""
        expected = set(CITING_DOCS)
        citing = {
            str(path.relative_to(REPO))
            for path in (REPO / "skills").rglob("*.md")
            if CITATION.search(path.read_text(encoding="utf-8"))
        }
        self.assertEqual(expected, citing)


if __name__ == "__main__":
    unittest.main()
