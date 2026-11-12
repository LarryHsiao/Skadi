#!/usr/bin/env python3
"""Contract tests for the skills-against-handbook lint.

Two promises: every skill under `skills/` is named as `/name` somewhere in the
handbook, and every `/name` the handbook writes is a skill or a known
non-skill. The last test holds the committed tree to both.
"""

import shutil
import tempfile
import unittest
from pathlib import Path

import handbook_skills

REPO = Path(__file__).resolve().parent.parent


class ProblemsTest(unittest.TestCase):
    def test_a_skill_the_handbook_never_names_is_reported(self):
        expected = ["commit: no handbook page names /commit"]
        actual = handbook_skills.problems({"commit", "stage"}, "<p>run /stage first</p>", set())
        self.assertEqual(expected, actual)

    def test_a_slash_name_that_is_no_skill_is_reported(self):
        expected = ["handbook names /oldname, which is no skill"]
        actual = handbook_skills.problems({"stage"}, "<p>/stage then /oldname</p>", set())
        self.assertEqual(expected, actual)

    def test_a_known_non_skill_is_not_reported(self):
        expected = []
        actual = handbook_skills.problems({"stage"}, "<p>/stage, then /clear</p>", {"clear"})
        self.assertEqual(expected, actual)

    def test_a_path_is_not_read_as_a_slash_name(self):
        expected = []
        actual = handbook_skills.problems({"stage"}, "<p>/stage edits docs/workflow and ~/.claude/hooks/x.sh</p>", set())
        self.assertEqual(expected, actual)

    def test_markup_is_not_read_as_a_slash_name(self):
        expected = []
        actual = handbook_skills.problems({"stage"}, '<p>/stage</p><a href="/elsewhere">x</a>', set())
        self.assertEqual(expected, actual)

    def test_a_name_inside_a_longer_word_does_not_count_as_a_mention(self):
        expected = ["commit: no handbook page names /commit"]
        actual = handbook_skills.problems({"commit"}, "<p>/commit-msg</p>", {"commit-msg"})
        self.assertEqual(expected, actual)


class SlashNameShapeTest(unittest.TestCase):
    def test_a_stale_name_ending_a_sentence_is_still_reported(self):
        expected = ["handbook names /oldname, which is no skill"]
        actual = handbook_skills.problems({"stage"}, "<p>/stage. Not /oldname.</p>", set())
        self.assertEqual(expected, actual)

    def test_a_trailing_hyphen_is_not_part_of_the_name(self):
        expected = []
        actual = handbook_skills.problems({"stage"}, "<p>/stage- then</p>", set())
        self.assertEqual(expected, actual)

    def test_a_skill_name_with_a_digit_is_found(self):
        expected = []
        actual = handbook_skills.problems({"fix2go"}, "<p>run /fix2go now</p>", set())
        self.assertEqual(expected, actual)


class MainTest(unittest.TestCase):
    def _tree(self, handbook_text):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root)
        (root / "skills" / "stage").mkdir(parents=True)
        (root / "skills" / "stage" / "SKILL.md").write_text("---\n---\n", encoding="utf-8")
        (root / "handbook").mkdir()
        (root / "handbook" / "page.html").write_text(handbook_text, encoding="utf-8")
        return [str(root / "skills"), str(root / "handbook")]

    def test_a_clean_tree_exits_zero(self):
        expected = 0
        actual = handbook_skills.main(["x", *self._tree("<p>/stage</p>")])
        self.assertEqual(expected, actual)

    def test_a_drifted_tree_exits_one(self):
        expected = 1
        actual = handbook_skills.main(["x", *self._tree("<p>nothing here</p>")])
        self.assertEqual(expected, actual)


class CommittedTreeTest(unittest.TestCase):
    def test_the_skills_and_the_handbook_agree(self):
        expected = []
        actual = handbook_skills.check(REPO / "skills", REPO / "handbook")
        self.assertEqual(expected, actual)


if __name__ == "__main__":
    unittest.main()
