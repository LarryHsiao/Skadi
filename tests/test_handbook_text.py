#!/usr/bin/env python3
"""Guard: handbook Chinese text carries no line break inside a phrase.

HTML reads a newline plus indent as one space. Where the source wraps a line
between two Chinese characters, the page shows a stray space in the middle of a
phrase ("要 當成", "不通 過"). A space between a Latin word and Chinese is the
file's own convention and is left alone; only a break with Chinese or
full-width punctuation on both sides is a defect.
"""

import re
import unittest
from pathlib import Path

HANDBOOK = Path(__file__).resolve().parent.parent / "handbook"
CJK = r"[　-〿㐀-鿿＀-￯]"
BREAK_INSIDE_CJK = re.compile(CJK + r"\n[ \t]+" + CJK)


def _line_of(text, offset):
    return text.count("\n", 0, offset) + 1


class HandbookChineseTextTest(unittest.TestCase):
    def test_no_page_breaks_a_line_between_two_chinese_characters(self):
        offenders = []
        for page in sorted(HANDBOOK.glob("*.html")):
            text = page.read_text(encoding="utf-8")
            offenders += [f"{page.name}:{_line_of(text, m.start())}" for m in BREAK_INSIDE_CJK.finditer(text)]
        expected = []
        self.assertEqual(expected, offenders)

    def test_the_pattern_catches_a_break_and_spares_a_latin_boundary(self):
        broken = "唯一一個成果要\n          當成一頁網頁來讀"
        latin_boundary = "當成一頁\n          skill 的網頁"
        self.assertIsNotNone(BREAK_INSIDE_CJK.search(broken))
        self.assertIsNone(BREAK_INSIDE_CJK.search(latin_boundary))


if __name__ == "__main__":
    unittest.main()
