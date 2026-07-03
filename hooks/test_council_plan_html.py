#!/usr/bin/env python3
"""Tests for the council plan-preview HTML renderer."""

import importlib.util
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("council_plan_html", HERE / "council-plan-html.py")
cph = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cph)


class FindDiagramBlockTest(unittest.TestCase):
    def test_no_fence_returns_none(self):
        expected = None
        result = cph.find_diagram_block("# Intent\n\nJust prose, no diagram here.\n")
        self.assertEqual(expected, result)

    def test_diagram_fence_is_found(self):
        text = "before\n\n```diagram\nA -> B\n```\n\nafter"
        result = cph.find_diagram_block(text)
        self.assertEqual("diagram", result["tag"])
        self.assertEqual("A -> B", result["body"])
        self.assertEqual(text[result["start"]:result["end"]], "```diagram\nA -> B\n```")

    def test_wireframe_fence_is_found(self):
        text = "before\n\n```wireframe\n[Box]\n```\n\nafter"
        result = cph.find_diagram_block(text)
        self.assertEqual("wireframe", result["tag"])
        self.assertEqual("[Box]", result["body"])

    def test_only_first_fence_is_returned(self):
        text = "```diagram\nfirst\n```\n\n```wireframe\nsecond\n```"
        result = cph.find_diagram_block(text)
        self.assertEqual("diagram", result["tag"])
        self.assertEqual("first", result["body"])

    def test_bare_fence_without_tag_is_ignored(self):
        expected = None
        result = cph.find_diagram_block("```\nplain code, not a diagram\n```")
        self.assertEqual(expected, result)


class ReplaceDiagramBlockTest(unittest.TestCase):
    def test_replaces_fence_with_given_text(self):
        text = "before\n\n```diagram\nA -> B\n```\n\nafter"
        expected = "before\n\n![diagram](x.png)\n\nafter"
        result = cph.replace_diagram_block(text, "![diagram](x.png)")
        self.assertEqual(expected, result)

    def test_raises_when_no_block_present(self):
        with self.assertRaises(ValueError):
            cph.replace_diagram_block("no fence here", "x")


class RenderPlanHtmlTest(unittest.TestCase):
    def test_output_contains_escaped_ticket_and_body(self):
        html_out = cph.render_plan_html("Intent: <script>alert(1)</script>", "MET-1")
        self.assertIn("MET-1", html_out)
        self.assertIn("&lt;script&gt;", html_out)
        self.assertNotIn("<script>alert(1)</script>", html_out)
        self.assertIn('href="skadi-theme.css"', html_out)


class RenderDiagramHtmlTest(unittest.TestCase):
    def test_output_preserves_ascii_box_drawing(self):
        body = "┌───┐\n│ A │\n└───┘"
        html_out = cph.render_diagram_html(body, "MET-1")
        self.assertIn("┌───┐", html_out)
        self.assertIn('href="skadi-theme.css"', html_out)


if __name__ == "__main__":
    unittest.main()
