#!/usr/bin/env python3
"""Contract tests for the chapter VI graph generator.

The chapter's Mermaid block is not typed any more: it is produced from the
`stage:` and `composes:` keys in each SKILL.md. The chapter's own script reads
that block back to draw its network, so what these tests pin is the text shape
that script's parser expects, plus the promise that the committed chapter never
drifts from the skills it draws.
"""

import re
import unittest
from pathlib import Path

import fellowship_graph
from skill_edges import Edge, Skill, load

REPO = Path(__file__).resolve().parent.parent


def skill(name, stage, *edges):
    return Skill(name, stage, tuple(edges), "")


FIXTURE = {
    "sirion": skill("sirion", "merge", Edge("commit", "dispatch"), Edge("mithrandir", "dispatch")),
    "commit": skill("commit", "forge"),
    "mithrandir": skill("mithrandir", "weigh", Edge("lindir", "companion"), Edge("moria", "companion", mend=True, label="comments left standing")),
    "lindir": skill("lindir", "weigh"),
    "moria": skill("moria", "vigil", Edge("narvi", "dispatch", mend=True)),
    "narvi": skill("narvi", "forge", Edge("mithrandir", "dispatch", mend=True, label="weighed again")),
    "focus": skill("focus", "desk"),
}


class RenderGraphTest(unittest.TestCase):
    def setUp(self):
        self.text = fellowship_graph.render_graph(FIXTURE)
        self.lines = [line.strip() for line in self.text.splitlines()]

    def test_lanes_appear_in_chapter_order_and_only_when_populated(self):
        expected = ["VIGIL", "FORGE", "WEIGH", "MERGE", "DESK"]
        actual = re.findall(r"^\s*subgraph ([A-Z]+)\[", self.text, re.M)
        self.assertEqual(expected, actual)

    def test_lane_title_comes_from_the_bilingual_table(self):
        expected = f'subgraph FORGE["{fellowship_graph.LANES["forge"]}"]'
        self.assertIn(expected, self.lines)

    def test_node_id_is_the_upper_cased_name_without_hyphens(self):
        self.assertIn('MITHRANDIR["/mithrandir"]', self.lines)

    def test_dispatch_edges_precede_companion_edges_and_mend_edges_come_last(self):
        edges = [l for l in self.lines if re.match(r"^[A-Z]+ -(->|\.->)", l)]
        expected = [
            "SIRION --> COMMIT",
            "SIRION --> MITHRANDIR",
            "MITHRANDIR -.-> LINDIR",
            "MORIA --> NARVI",
            'NARVI -->|"weighed again"| MITHRANDIR',
            'MITHRANDIR -.->|"comments left standing"| MORIA',
        ]
        self.assertEqual(expected, edges)

    def test_link_style_names_exactly_the_trailing_mend_edges(self):
        expected = "linkStyle 3,4,5 stroke:#9a3b2e,stroke-width:2px;"
        self.assertIn(expected, self.lines)

    def test_a_skill_with_no_edges_in_or_out_is_marked_isolate(self):
        expected = "class FOCUS isolate;"
        self.assertIn(expected, self.lines)

    def test_no_isolate_line_when_every_skill_is_wired(self):
        wired = {k: v for k, v in FIXTURE.items() if k != "focus"}
        self.assertNotIn("isolate;", fellowship_graph.render_graph(wired).replace("classDef isolate", ""))

    def test_a_skill_with_no_stage_is_refused(self):
        with self.assertRaises(ValueError):
            fellowship_graph.render_graph({"x": skill("x", None)})


class LaneOrderTest(unittest.TestCase):
    def test_a_caller_precedes_the_skill_it_calls_in_the_same_lane(self):
        skills = {
            "alpha": skill("alpha", "vigil"),
            "zulu": skill("zulu", "vigil", Edge("alpha", "dispatch")),
        }
        expected = ["zulu", "alpha"]
        actual = fellowship_graph._lane_order(["alpha", "zulu"], skills)
        self.assertEqual(expected, actual)

    def test_a_cycle_inside_a_lane_still_terminates_and_places_everyone(self):
        skills = {
            "a": skill("a", "vigil", Edge("b", "dispatch")),
            "b": skill("b", "vigil", Edge("a", "dispatch")),
        }
        expected = ["a", "b"]
        actual = fellowship_graph._lane_order(["a", "b"], skills)
        self.assertEqual(expected, actual)

    def test_a_stage_outside_the_known_set_is_refused_not_dropped(self):
        with self.assertRaises(ValueError):
            fellowship_graph.render_graph({"x": skill("x", "nowhere")})


class MainTest(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        folder = root / "skills" / "solo"
        folder.mkdir(parents=True)
        (folder / "SKILL.md").write_text("---\nname: solo\ndescription: d\nstage: desk\n---\nbody\n", encoding="utf-8")
        self.skills_dir = str(root / "skills")
        self.page = root / "page.html"
        self.page.write_text(
            "<!-- fellowship:begin -->\n<!-- fellowship:end -->"
            "<!-- alone:en:begin --><!-- alone:en:end -->"
            "<!-- alone:zh:begin --><!-- alone:zh:end -->",
            encoding="utf-8",
        )

    def tearDown(self):
        self.tmp.cleanup()

    def test_check_exits_one_while_the_page_is_stale_then_zero_after_a_write(self):
        args = [self.skills_dir, str(self.page)]
        expected = (1, 0, 0)
        actual = (
            fellowship_graph.main(["x", "--check", *args]),
            fellowship_graph.main(["x", *args]),
            fellowship_graph.main(["x", "--check", *args]),
        )
        self.assertEqual(expected, actual)

    def test_a_lint_failure_stops_the_run_and_leaves_the_page_alone(self):
        (Path(self.skills_dir) / "solo" / "SKILL.md").write_text("---\nname: solo\ndescription: d\n---\n", encoding="utf-8")
        before = self.page.read_text(encoding="utf-8")
        code = fellowship_graph.main(["x", self.skills_dir, str(self.page)])
        self.assertEqual((1, before), (code, self.page.read_text(encoding="utf-8")))


class SpliceTest(unittest.TestCase):
    PAGE = "before\n<!-- fellowship:begin -->\nOLD\n<!-- fellowship:end -->\nafter\n"

    def test_replaces_only_the_marked_region(self):
        expected = (
            'before\n<!-- fellowship:begin -->\n<pre class="mermaid">\nNEW\n</pre>\n'
            "<!-- fellowship:end -->\nafter\n"
        )
        actual = fellowship_graph.splice(self.PAGE, "NEW")
        self.assertEqual(expected, actual)

    def test_page_without_markers_is_refused(self):
        with self.assertRaises(ValueError):
            fellowship_graph.splice("no markers here", "NEW")


class AloneTest(unittest.TestCase):
    def test_english_list_joins_with_and(self):
        expected = (
            '<span class="name">/focus</span>, '
            '<span class="name">/reset</span> and '
            '<span class="name">/scribe</span>'
        )
        skills = {n: skill(n, "desk") for n in ("scribe", "focus", "reset")}
        actual = fellowship_graph.render_alone(skills, "en")
        self.assertEqual(expected, actual)

    def test_chinese_list_joins_with_the_enumeration_comma(self):
        expected = '<span class="name">/focus</span> 與 <span class="name">/scribe</span>'
        skills = {n: skill(n, "desk") for n in ("scribe", "focus")}
        actual = fellowship_graph.render_alone(skills, "zh")
        self.assertEqual(expected, actual)

    def test_wired_skills_are_left_out(self):
        expected = '<span class="name">/focus</span>'
        skills = {"focus": skill("focus", "desk"), "a": skill("a", "forge", Edge("b", "dispatch")), "b": skill("b", "forge")}
        actual = fellowship_graph.render_alone(skills, "en")
        self.assertEqual(expected, actual)

    def test_a_single_name_needs_no_joiner(self):
        expected = '<span class="name">/focus</span>'
        actual = fellowship_graph.render_alone({"focus": skill("focus", "desk")}, "zh")
        self.assertEqual(expected, actual)

    def test_a_page_missing_the_alone_markers_is_refused(self):
        page = "<!-- fellowship:begin -->\n<!-- fellowship:end -->"
        with self.assertRaises(ValueError):
            fellowship_graph.generate(page, {"focus": skill("focus", "desk")})

    def test_nothing_standing_alone_renders_empty(self):
        self.assertEqual("", fellowship_graph.render_alone({}, "en"))

    def test_generate_fills_both_language_markers(self):
        page = (
            "<!-- fellowship:begin -->\n<!-- fellowship:end -->\n"
            "<!-- alone:en:begin -->x<!-- alone:en:end -->"
            "<!-- alone:zh:begin -->y<!-- alone:zh:end -->"
        )
        out = fellowship_graph.generate(page, {"focus": skill("focus", "desk")})
        self.assertIn('<!-- alone:en:begin --><span class="name">/focus</span><!-- alone:en:end -->', out)
        self.assertIn('<!-- alone:zh:begin --><span class="name">/focus</span><!-- alone:zh:end -->', out)


class CommittedChapterTest(unittest.TestCase):
    def test_chapter_vi_is_in_step_with_the_skills(self):
        chapter = (REPO / "handbook" / "skill-fellowship.html").read_text(encoding="utf-8")
        expected = fellowship_graph.generate(chapter, load(REPO / "skills"))
        self.assertEqual(expected, chapter, "run: python3 hooks/fellowship_graph.py")


if __name__ == "__main__":
    unittest.main()
