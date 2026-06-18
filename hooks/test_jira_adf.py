#!/usr/bin/env python3
"""Tests for the shared ADF flattener."""

import importlib.util
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("jira_adf", HERE / "jira_adf.py")
jira_adf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(jira_adf)


class AdfToTextTest(unittest.TestCase):
    def test_heading_paragraph_and_bullets_flatten_to_markdown(self):
        doc = {
            "type": "doc",
            "content": [
                {"type": "heading", "attrs": {"level": 2},
                 "content": [{"type": "text", "text": "Title"}]},
                {"type": "paragraph",
                 "content": [{"type": "text", "text": "Hello world"}]},
                {"type": "bulletList", "content": [
                    {"type": "listItem", "content": [
                        {"type": "paragraph", "content": [{"type": "text", "text": "one"}]}]},
                    {"type": "listItem", "content": [
                        {"type": "paragraph", "content": [{"type": "text", "text": "two"}]}]},
                ]},
            ],
        }
        expected = "## Title\n\nHello world\n\n- one\n\n- two"
        self.assertEqual(expected, jira_adf.adf_to_text(doc))

    def test_none_yields_empty_string(self):
        expected = ""
        self.assertEqual(expected, jira_adf.adf_to_text(None))

    def test_plain_string_passes_through(self):
        expected = "already flat"
        self.assertEqual(expected, jira_adf.adf_to_text("already flat"))


if __name__ == "__main__":
    unittest.main()
