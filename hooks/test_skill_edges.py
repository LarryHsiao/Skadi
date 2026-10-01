#!/usr/bin/env python3
"""Contract tests for the skill-composition edge reader.

Each SKILL.md may declare, in one-line frontmatter keys the other line-based
parsers already tolerate:

    stage: forge
    composes: commit:dispatch, mithrandir:companion+mend|weighed again

``composes`` names the skills this one relates to, each with the kind of the
relation (`dispatch`: calls it; `companion`: names it without calling), an
optional `+mend` flag for the one red review cycle, and an optional `|label`.
The reader returns them; `check` turns every way the declaration can lie into
a plain sentence, so the generated graph never draws an edge the prose denies.
"""

import tempfile
import unittest
from pathlib import Path

import skill_edges


def write_skill(root, name, frontmatter_extra="", body=""):
    folder = Path(root) / name
    folder.mkdir(parents=True)
    (folder / "SKILL.md").write_text(
        f"---\nname: {name}\ndescription: {name} does a thing.\n"
        f"{frontmatter_extra}---\n{body}\n",
        encoding="utf-8",
    )


class ParseTest(unittest.TestCase):
    def test_reads_stage_and_ordered_edges(self):
        expected = (
            "forge",
            [skill_edges.Edge("commit", "dispatch"), skill_edges.Edge("mithrandir", "companion")],
        )
        actual = skill_edges.parse_declaration(
            "name: x\nstage: forge\ncomposes: commit:dispatch, mithrandir:companion"
        )
        self.assertEqual(expected, actual)

    def test_mend_flag_and_label_ride_on_an_edge(self):
        expected = [skill_edges.Edge("mithrandir", "dispatch", mend=True, label="weighed again")]
        _, actual = skill_edges.parse_declaration(
            "composes: mithrandir:dispatch+mend|weighed again"
        )
        self.assertEqual(expected, actual)

    def test_absent_keys_read_as_no_stage_and_no_edges(self):
        expected = (None, [])
        actual = skill_edges.parse_declaration("name: x\ndescription: y")
        self.assertEqual(expected, actual)

    def test_entry_without_a_kind_is_refused(self):
        with self.assertRaises(ValueError):
            skill_edges.parse_declaration("composes: commit")


class LoadTest(unittest.TestCase):
    def test_load_keys_every_skill_by_name(self):
        with tempfile.TemporaryDirectory() as root:
            write_skill(root, "sirion", "stage: merge\ncomposes: commit:dispatch\n", "calls /commit")
            write_skill(root, "commit", "stage: merge\n")
            expected = {"sirion", "commit"}
            actual = set(skill_edges.load(root))
            self.assertEqual(expected, actual)


class DirectoryNameTest(unittest.TestCase):
    def test_a_skill_is_keyed_by_its_directory_not_its_frontmatter_name(self):
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root) / "reset"
            folder.mkdir()
            (folder / "SKILL.md").write_text("---\nname: git-reset\ndescription: d\n---\nbody\n", encoding="utf-8")
            expected = {"reset"}
            actual = set(skill_edges.load(root))
            self.assertEqual(expected, actual)


class CheckTest(unittest.TestCase):
    def problems(self, specs):
        """specs: name -> (frontmatter_extra, body)."""
        with tempfile.TemporaryDirectory() as root:
            for name, (extra, body) in specs.items():
                write_skill(root, name, extra, body)
            return skill_edges.check(skill_edges.load(root))

    def test_consistent_declaration_has_no_problems(self):
        expected = []
        actual = self.problems({
            "sirion": ("stage: merge\ncomposes: commit:dispatch\n", "then /commit runs"),
            "commit": ("stage: merge\n", ""),
        })
        self.assertEqual(expected, actual)

    def test_a_bold_capitalised_name_counts_as_a_mention(self):
        expected = []
        actual = self.problems({
            "amon-sul": ("stage: vigil\ncomposes: moria:dispatch\n", "**Moria** rides the mend stage"),
            "moria": ("stage: vigil\n", ""),
        })
        self.assertEqual(expected, actual)

    def test_edge_to_a_missing_skill_is_named(self):
        actual = self.problems({
            "sirion": ("stage: merge\ncomposes: ghost:dispatch\n", "calls /ghost"),
        })
        self.assertEqual(1, len(actual))
        self.assertIn("ghost", actual[0])

    def test_declared_edge_the_body_never_mentions_is_named(self):
        actual = self.problems({
            "sirion": ("stage: merge\ncomposes: commit:dispatch\n", "no mention here"),
            "commit": ("stage: merge\n", ""),
        })
        self.assertEqual(1, len(actual))
        self.assertIn("never mentions", actual[0])

    def test_unknown_kind_is_named(self):
        actual = self.problems({
            "sirion": ("stage: merge\ncomposes: commit:sprint\n", "/commit"),
            "commit": ("stage: merge\n", ""),
        })
        self.assertTrue(any("sprint" in p for p in actual))

    def test_unknown_stage_is_named(self):
        actual = self.problems({"sirion": ("stage: nowhere\n", "")})
        self.assertTrue(any("nowhere" in p for p in actual))

    def test_skill_with_no_stage_is_named(self):
        actual = self.problems({"sirion": ("", "")})
        self.assertTrue(any("no stage" in p for p in actual))

    def test_self_edge_is_named(self):
        actual = self.problems({
            "sirion": ("stage: merge\ncomposes: sirion:dispatch\n", "/sirion"),
        })
        self.assertTrue(any("itself" in p for p in actual))

    def test_duplicate_edge_is_named(self):
        actual = self.problems({
            "sirion": ("stage: merge\ncomposes: commit:dispatch, commit:companion\n", "/commit"),
            "commit": ("stage: merge\n", ""),
        })
        self.assertTrue(any("twice" in p for p in actual))


def ring(*pairs):
    """Skills whose mend edges are the given (source, target) pairs."""
    names = {n for pair in pairs for n in pair}
    out = {n: [] for n in names}
    for source, target in pairs:
        out[source].append(skill_edges.Edge(target, "dispatch", mend=True))
    return {n: skill_edges.Skill(n, "forge", tuple(es), f"/{' /'.join(t for t in names)}") for n, es in out.items()}


class MendCycleTest(unittest.TestCase):
    def test_edges_forming_one_closed_ring_pass(self):
        expected = []
        actual = skill_edges.check(ring(("a", "b"), ("b", "c"), ("c", "a")))
        self.assertEqual(expected, actual)

    def test_a_lone_mend_edge_is_named(self):
        actual = skill_edges.check(ring(("a", "b")))
        self.assertTrue(any("mend" in p and "cycle" in p for p in actual))

    def test_two_separate_rings_are_named(self):
        actual = skill_edges.check(ring(("a", "b"), ("b", "a"), ("c", "d"), ("d", "c")))
        self.assertTrue(any("mend" in p and "cycle" in p for p in actual))

    def test_no_mend_edges_is_fine(self):
        self.assertEqual([], [p for p in skill_edges.check({"a": skill_edges.Skill("a", "forge", (), "")}) if "mend" in p])


class FrontmatterGapTest(unittest.TestCase):
    def test_a_skill_with_no_frontmatter_is_loaded_and_flagged_for_having_no_stage(self):
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root) / "bare"
            folder.mkdir()
            (folder / "SKILL.md").write_text("no frontmatter at all\n", encoding="utf-8")
            actual = skill_edges.check(skill_edges.load(root))
            self.assertEqual(["bare: has no stage"], actual)

    def test_a_repeated_composes_line_is_refused(self):
        with self.assertRaises(ValueError):
            skill_edges.parse_declaration("composes: a:dispatch\ncomposes: b:dispatch")

    def test_a_repeated_stage_line_is_refused(self):
        with self.assertRaises(ValueError):
            skill_edges.parse_declaration("stage: forge\nstage: weigh")

    def test_a_bare_stage_key_reads_as_no_stage(self):
        self.assertEqual((None, []), skill_edges.parse_declaration("stage:"))

    def test_an_unknown_flag_is_refused(self):
        with self.assertRaises(ValueError):
            skill_edges.parse_declaration("composes: a:dispatch+loud")

    def test_an_entry_with_no_target_is_refused(self):
        with self.assertRaises(ValueError):
            skill_edges.parse_declaration("composes: :dispatch")


class MainTest(unittest.TestCase):
    def test_a_clean_tree_exits_zero(self):
        with tempfile.TemporaryDirectory() as root:
            write_skill(root, "solo", "stage: desk\n")
            self.assertEqual(0, skill_edges.main(["x", root]))

    def test_a_tree_with_a_problem_exits_one(self):
        with tempfile.TemporaryDirectory() as root:
            write_skill(root, "solo")
            self.assertEqual(1, skill_edges.main(["x", root]))


class RealTreeTest(unittest.TestCase):
    def test_every_declaration_in_the_repo_is_consistent(self):
        expected = []
        actual = skill_edges.check(skill_edges.load(Path(__file__).resolve().parent.parent / "skills"))
        self.assertEqual(expected, actual)


if __name__ == "__main__":
    unittest.main()
