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
        expected_tag = "diagram"
        self.assertEqual(expected_tag, result["tag"])
        expected_body = "A -> B"
        self.assertEqual(expected_body, result["body"])
        expected_fence = "```diagram\nA -> B\n```"
        self.assertEqual(expected_fence, text[result["start"]:result["end"]])

    def test_wireframe_fence_is_found(self):
        text = "before\n\n```wireframe\n[Box]\n```\n\nafter"
        result = cph.find_diagram_block(text)
        expected_tag = "wireframe"
        self.assertEqual(expected_tag, result["tag"])
        expected_body = "[Box]"
        self.assertEqual(expected_body, result["body"])

    def test_only_first_fence_is_returned(self):
        text = "```diagram\nfirst\n```\n\n```wireframe\nsecond\n```"
        result = cph.find_diagram_block(text)
        expected_tag = "diagram"
        self.assertEqual(expected_tag, result["tag"])
        expected_body = "first"
        self.assertEqual(expected_body, result["body"])

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
        expected_ticket = "MET-1"
        self.assertIn(expected_ticket, html_out)
        expected_escaped = "&lt;script&gt;"
        self.assertIn(expected_escaped, html_out)
        expected_unescaped = "<script>alert(1)</script>"
        self.assertNotIn(expected_unescaped, html_out)
        expected_stylesheet = 'href="skadi-theme.css"'
        self.assertIn(expected_stylesheet, html_out)


class RenderDiagramHtmlTest(unittest.TestCase):
    def test_output_preserves_ascii_box_drawing(self):
        body = "┌───┐\n│ A │\n└───┘"
        html_out = cph.render_diagram_html(body, "MET-1")
        expected_box = "┌───┐"
        self.assertIn(expected_box, html_out)
        # Inlined, not linked: this file is screenshotted from a scratch tmp
        # path with no skadi-theme.css sibling, so the CSS must be self-contained.
        expected_no_link = 'href="skadi-theme.css"'
        self.assertNotIn(expected_no_link, html_out)
        expected_monospace = "ui-monospace"
        self.assertIn(expected_monospace, html_out)
        expected_no_wrap = "white-space: pre;"
        self.assertIn(expected_no_wrap, html_out)


if __name__ == "__main__":
    unittest.main()
