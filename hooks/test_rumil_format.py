#!/usr/bin/env python3
"""Contract tests for the concept-file format /rumil writes.

/rumil authors plan concepts that /galadriel renders. The renderer's parser
imposes two constraints that are invisible in the markdown itself, and this
file pins both so a future edit to either side fails loudly:

1. Every ``- [ ]`` line in the file is collected as a step, whatever heading
   it sits under. Acceptance criteria must therefore be plain ``-`` bullets;
   a checkbox there silently inflates the progress bar.
2. Lines matching ``^#{1,6}\\s+`` are dropped from the overview walk. Purpose
   and Acceptance must lead with a bold run (``**Purpose** — ...``) rather
   than a heading, or their labels vanish from the rendered page.
"""

import importlib.util
import re
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("galadriel_render", HERE / "galadriel-render.py")
galadriel = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(galadriel)

# A concept in the shape /rumil writes: bold-lead Purpose and Acceptance,
# plain bullets for the criteria, phase-grouped steps carrying global numbers
# and dependency tags.
RUMIL_CONCEPT = """\
# Offline receipt cache

**Purpose** — Receipts captured without a network must survive until the
device can post them, so a courier in a basement loses no work.

**Acceptance** — the outcomes that mark the whole done:
- a receipt queued offline survives an app restart
- the queue drains in capture order once the network returns
- a receipt rejected by the server surfaces in the failures list

**Spec source** — docs/specs/offline-receipts.md (rules, Dana) + mock/*.png (3 frames, Ines)

**The wiring** — each screen bound to the rule that governs it:
- Capture screen → §2 "capture works offline" — wired
- Failures list → §5 "rejected receipts are visible" — wired
- Capture → Failures (tap the banner) → no rule names this transition — Q4
- Sync banner → no rule in the text spec — orphan screen — Q2
- §4 "a courier may delete a queued receipt" → no frame shows it — orphan rule — Q5
- Retry: §5 says the app retries on its own; the mock draws a Retry button — Q1

**Open questions** — for whoever wrote the spec:
- Q1: When a receipt is rejected by the server, does the app retry on its own,
  or wait for the courier to resubmit it?
- Q2: While receipts are syncing, what does the courier see — a banner, a
  spinner on each row, or nothing until it finishes?
- Q3: The spec asks that syncing "feel instant". What is the budget, and
  measured from which moment?
- Q4: What carries the courier from the capture screen to the failures list —
  tapping the sync banner, or somewhere else?
- Q5: §4 says a courier may delete a queued receipt, but no frame shows it.
  Where does that happen?

## Steps

### Phase 1 — the store

- [ ] 1. Add the ReceiptQueue table and its migration [independent]
- [ ] 2. Write ReceiptQueue.enqueue with its test [depends on 1]

### Phase 2 — the drain

- [ ] 3. Write ReceiptDrain.next with its test [depends on 2]
- [ ] 4. Render the syncing indicator on the receipt row [depends on 3] [blocked on Q2]
"""

# The same concept with the trap sprung: acceptance written as checkboxes.
TRAP_CONCEPT = RUMIL_CONCEPT.replace(
    "- a receipt queued offline survives an app restart",
    "- [ ] a receipt queued offline survives an app restart",
).replace(
    "- the queue drains in capture order once the network returns",
    "- [ ] the queue drains in capture order once the network returns",
).replace(
    "- a receipt rejected by the server surfaces in the failures list",
    "- [ ] a receipt rejected by the server surfaces in the failures list",
)


def parse(text):
    """Run one concept body through the real renderer's parser."""
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "concept.md"
        path.write_text(text, encoding="utf-8")
        return galadriel.parse_concept(path, None)


class StepCollectionTest(unittest.TestCase):
    def test_acceptance_bullets_are_not_counted_as_steps(self):
        expected = 4
        self.assertEqual(expected, len(parse(RUMIL_CONCEPT)["steps"]))

    def test_open_questions_do_not_leak_into_the_step_labels(self):
        """Questions go back to the spec's author; they are not work to tick off."""
        expected_absent = "Q1:"
        labels = " ".join(s["label"] for s in parse(RUMIL_CONCEPT)["steps"])
        self.assertNotIn(expected_absent, labels)

    def test_open_questions_reach_the_reader_through_the_overview(self):
        expected = "Q1: When a receipt is rejected by the server"
        self.assertIn(expected, parse(RUMIL_CONCEPT)["overview"])

    def test_checkbox_acceptance_inflates_the_step_count(self):
        """The trap the format rule exists to avoid — three criteria read as steps."""
        expected = 7
        self.assertEqual(expected, len(parse(TRAP_CONCEPT)["steps"]))

    def test_phase_headings_do_not_interrupt_collection(self):
        expected = ["1.", "2.", "3.", "4."]
        labels = [s["label"].split()[0] for s in parse(RUMIL_CONCEPT)["steps"]]
        self.assertEqual(expected, labels)

    def test_dependency_tags_survive_into_the_label(self):
        expected = "2. Write ReceiptQueue.enqueue with its test [depends on 1]"
        self.assertEqual(expected, parse(RUMIL_CONCEPT)["steps"][1]["label"])

    def test_blocked_tag_survives_beside_the_dependency_tag(self):
        """A step awaiting an answer keeps both tags, so the gap stays visible."""
        expected = "4. Render the syncing indicator on the receipt row [depends on 3] [blocked on Q2]"
        self.assertEqual(expected, parse(RUMIL_CONCEPT)["steps"][3]["label"])


class DocumentedShapeTest(unittest.TestCase):
    """The example in format.md and this fixture must stay one artifact.

    They have drifted twice — once on wording, once on what `Q4` referred to —
    and both times a human reviewer caught it. This makes the mirror mechanical.
    """

    def test_the_fixture_matches_the_example_in_format_md(self):
        doc = HERE.parent / "skills" / "rumil" / "format.md"
        if not doc.exists():          # the skill may be vendored without its docs
            self.skipTest(f"{doc} not present")
        block = re.search(r"```markdown\n(.*?)```", doc.read_text(encoding="utf-8"), re.S)
        self.assertIsNotNone(block, "format.md carries no ```markdown example")
        # The preview marker is exercised separately by FlowPreviewTest, which
        # supplies its own; the fixture omits it.
        expected = [ln for ln in block.group(1).splitlines()
                    if not ln.startswith("<!-- preview:")]
        self.assertEqual(expected, RUMIL_CONCEPT.splitlines())


class WiringTest(unittest.TestCase):
    """The text-spec-to-UI-spec correspondence, which lives nowhere else."""

    def test_wiring_bullets_do_not_leak_into_the_step_labels(self):
        """The wiring is a record for the reader, not work to tick off."""
        expected_absent = "→"
        labels = " ".join(s["label"] for s in parse(RUMIL_CONCEPT)["steps"])
        self.assertNotIn(expected_absent, labels)

    def test_a_contradiction_survives_into_the_overview(self):
        """The highest-value finding, and the one least likely to survive summarising."""
        expected = "§5 says the app retries on its own; the mock draws a Retry button"
        self.assertIn(expected, parse(RUMIL_CONCEPT)["overview"])

    def test_an_orphan_screen_survives_into_the_overview(self):
        expected = "Sync banner → no rule in the text spec — orphan screen"
        self.assertIn(expected, parse(RUMIL_CONCEPT)["overview"])

    def test_every_cited_question_is_also_defined(self):
        """A wiring line pointing at an undefined Qn is a dangling reference.

        The skill tells its reader to list the open questions in full; a concept
        citing Q4 with no Q4 beneath it models the opposite.
        """
        parsed = parse(RUMIL_CONCEPT)
        body = parsed["overview"] + " ".join(s["label"] for s in parsed["steps"])
        defined = set(re.findall(r"\b(Q\d+):", body))
        cited = set(re.findall(r"\b(Q\d+)\b(?!:)", body))
        expected_dangling = set()
        self.assertEqual(expected_dangling, cited - defined)


class OverviewTest(unittest.TestCase):
    def test_purpose_lead_survives_the_overview_walk(self):
        expected = "**Purpose** —"
        self.assertIn(expected, parse(RUMIL_CONCEPT)["overview"])

    def test_acceptance_criteria_survive_the_overview_walk(self):
        expected = "- a receipt queued offline survives an app restart"
        self.assertIn(expected, parse(RUMIL_CONCEPT)["overview"])

    def test_heading_lead_would_be_dropped(self):
        """Why Purpose leads with bold, not `## Purpose` — the heading vanishes."""
        expected_absent = "## Purpose"
        headed = RUMIL_CONCEPT.replace("**Purpose** —", "## Purpose\n\n")
        self.assertNotIn(expected_absent, parse(headed)["overview"])


class FlowPreviewTest(unittest.TestCase):
    """The UI-flow marker /rumil writes for a spec that changes screens."""

    FLOW = "<meta charset='utf-8'><p>capture -> queue -> drain</p>"

    def render_with_marker(self, marker, flow_name):
        """Parse a concept bearing `marker`, with the flow file written as `flow_name`."""
        with tempfile.TemporaryDirectory() as tmp:
            plans = Path(tmp) / "plans"
            plans.mkdir()
            (plans / flow_name).parent.mkdir(parents=True, exist_ok=True)
            (plans / flow_name).write_text(self.FLOW, encoding="utf-8")
            concept = plans / "concept.md"
            concept.write_text(f"{marker}\n{RUMIL_CONCEPT}", encoding="utf-8")
            return galadriel.parse_concept(concept, None)

    def test_a_sibling_flow_file_is_inlined(self):
        expected = self.FLOW
        parsed = self.render_with_marker("<!-- preview: flow-offline-receipts.html -->",
                                         "flow-offline-receipts.html")
        self.assertEqual(expected, parsed["preview"])

    def test_the_marker_is_stripped_from_the_overview(self):
        expected_absent = "preview:"
        parsed = self.render_with_marker("<!-- preview: flow-offline-receipts.html -->",
                                         "flow-offline-receipts.html")
        self.assertNotIn(expected_absent, parsed["overview"])

    def test_a_flow_outside_the_plans_folder_is_refused(self):
        """Why the flow file must be a sibling — an escaping path degrades to a note."""
        expected = "preview unavailable"
        parsed = self.render_with_marker("<!-- preview: ../escape.html -->", "escape.html")
        self.assertIn(expected, parsed["preview"])


class ConceptShapeTest(unittest.TestCase):
    def test_title_is_taken_from_the_first_heading(self):
        expected = "Offline receipt cache"
        self.assertEqual(expected, parse(RUMIL_CONCEPT)["title"])

    def test_a_freshly_written_plan_reads_as_planned(self):
        expected = "planned"
        self.assertEqual(expected, parse(RUMIL_CONCEPT)["lifecycle"])


if __name__ == "__main__":
    unittest.main()
