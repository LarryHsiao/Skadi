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


if __name__ == "__main__":
    unittest.main()
