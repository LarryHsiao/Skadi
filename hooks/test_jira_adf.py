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


def _text(value, marks=None):
    node = {"type": "text", "text": value}
    if marks:
        node["marks"] = marks
    return node


def _para(*nodes):
    return {"type": "paragraph", "content": list(nodes)}


def _item(*blocks):
    return {"type": "listItem", "content": list(blocks)}


class MdToAdfTest(unittest.TestCase):
    def _content(self, markdown):
        return jira_adf.md_to_adf(markdown)["content"]

    def test_empty_markdown_yields_empty_doc(self):
        expected = {"type": "doc", "version": 1, "content": []}
        self.assertEqual(expected, jira_adf.md_to_adf(""))

    def test_heading_keeps_its_level(self):
        expected = [{"type": "heading", "attrs": {"level": 2},
                     "content": [_text("Scope")]}]
        self.assertEqual(expected, self._content("## Scope"))

    def test_paragraph_lines_join_with_hard_breaks(self):
        expected = [_para(_text("one"), {"type": "hardBreak"}, _text("two"))]
        self.assertEqual(expected, self._content("one\ntwo"))

    def test_blank_line_separates_paragraphs(self):
        expected = [_para(_text("one")), _para(_text("two"))]
        self.assertEqual(expected, self._content("one\n\ntwo"))

    def test_bullets_become_a_bullet_list(self):
        expected = [{"type": "bulletList", "content": [
            _item(_para(_text("a"))), _item(_para(_text("b")))]}]
        self.assertEqual(expected, self._content("- a\n- b"))

    def test_checklist_items_carry_a_box_glyph(self):
        expected = [{"type": "bulletList", "content": [
            _item(_para(_text("☐ open"))), _item(_para(_text("☑ done")))]}]
        self.assertEqual(expected, self._content("- [ ] open\n- [x] done"))

    def test_indented_bullet_nests_under_its_parent(self):
        inner = {"type": "bulletList", "content": [_item(_para(_text("child")))]}
        expected = [{"type": "bulletList", "content": [
            _item(_para(_text("parent")), inner)]}]
        self.assertEqual(expected, self._content("- parent\n  - child"))

    def test_link_becomes_a_link_mark(self):
        link = [{"type": "link", "attrs": {"href": "https://x.test/a"}}]
        expected = [_para(_text("see "), _text("docs", link))]
        self.assertEqual(expected, self._content("see [docs](https://x.test/a)"))

    def test_image_with_local_source_becomes_plain_alt_text(self):
        expected = [_para(_text("Component"))]
        self.assertEqual(expected, self._content("![Component](attachment://screenshot.png)"))

    def test_image_with_web_source_becomes_a_link(self):
        link = [{"type": "link", "attrs": {"href": "https://x.test/a.png"}}]
        expected = [_para(_text("Shot", link))]
        self.assertEqual(expected, self._content("![Shot](https://x.test/a.png)"))

    def test_relative_link_stays_plain_text(self):
        expected = [_para(_text("notes (./notes.md)"))]
        self.assertEqual(expected, self._content("[notes](./notes.md)"))

    def test_unindented_line_after_a_list_starts_a_paragraph(self):
        expected = [{"type": "bulletList", "content": [_item(_para(_text("a")))]},
                    _para(_text("after"))]
        self.assertEqual(expected, self._content("- a\nafter"))

    def test_heading_ends_the_paragraph_before_it(self):
        expected = [_para(_text("intro")),
                    {"type": "heading", "attrs": {"level": 3}, "content": [_text("Next")]}]
        self.assertEqual(expected, self._content("intro\n### Next"))

    def test_star_bullet_and_upper_x_checkbox(self):
        expected = [{"type": "bulletList", "content": [_item(_para(_text("☑ done")))]}]
        self.assertEqual(expected, self._content("* [X] done"))

    def test_bold_and_code_become_marks(self):
        expected = [_para(_text("bold", [{"type": "strong"}]), _text(" and "),
                          _text("x()", [{"type": "code"}]))]
        self.assertEqual(expected, self._content("**bold** and `x()`"))


if __name__ == "__main__":
    unittest.main()
