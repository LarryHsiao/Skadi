#!/usr/bin/env python3
"""Tests for the Galadriel standing server — chiefly its delete guards.

DELETE moves a real markdown file out of a user's repo, so the guards matter more
than the happy path: a project must be a direct child of the served root, and a
concept must resolve inside the plans folder that project was rendered from.
"""

import importlib.util
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("galadriel_server",
                                               HERE / "galadriel-server.py")
gs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gs)


def scaffold(tmp, project="skadi", concepts=("one.md", "two.md")):
    """A served root with one project pointing at a plans folder holding concepts."""
    root = Path(tmp) / "galadriel"
    plans = Path(tmp) / "repo" / "docs" / "plans"
    plans.mkdir(parents=True)
    (root / project).mkdir(parents=True)
    (root / project / "plan-dashboard.html").write_text("<html>", encoding="utf-8")
    (root / project / "source").write_text(str(plans), encoding="utf-8")
    for c in concepts:
        (plans / c).write_text(f"# {c}\n\n## Steps\n- [ ] a\n", encoding="utf-8")
    return root, plans


class ConceptPathTest(unittest.TestCase):
    def test_a_concept_in_the_projects_plans_folder_resolves(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, plans = scaffold(tmp)
            expected = (plans / "one.md").resolve()
            self.assertEqual(expected, gs.concept_path(root, "/skadi/one.md"))

    def test_a_name_climbing_out_of_the_plans_folder_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, plans = scaffold(tmp)
            outside = plans.parent / "escape.md"
            outside.write_text("# nope\n", encoding="utf-8")
            expected = None
            self.assertEqual(expected, gs.concept_path(root, "/skadi/../escape.md"))

    def test_a_project_outside_the_root_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, _ = scaffold(tmp)
            expected = None
            self.assertEqual(expected, gs.concept_path(root, "/../repo/one.md"))

    def test_a_non_markdown_target_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, plans = scaffold(tmp)
            (plans / "flow.html").write_text("<html>", encoding="utf-8")
            expected = None
            self.assertEqual(expected, gs.concept_path(root, "/skadi/flow.html"))

    def test_a_project_with_no_source_marker_is_refused(self):
        """Without a recorded source there is no folder to delete from."""
        with tempfile.TemporaryDirectory() as tmp:
            root, _ = scaffold(tmp)
            (root / "skadi" / "source").unlink()
            expected = None
            self.assertEqual(expected, gs.concept_path(root, "/skadi/one.md"))

    def test_a_missing_concept_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, _ = scaffold(tmp)
            expected = None
            self.assertEqual(expected, gs.concept_path(root, "/skadi/absent.md"))


class EscapeTest(unittest.TestCase):
    """Vectors an audit had to hand-trace; pinned so they stay closed."""

    def test_a_concept_symlinked_out_of_the_plans_folder_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, plans = scaffold(tmp)
            outside = Path(tmp) / "secret.md"
            outside.write_text("# not yours\n", encoding="utf-8")
            (plans / "sneak.md").symlink_to(outside)
            expected = None
            self.assertEqual(expected, gs.concept_path(root, "/skadi/sneak.md"))

    def test_a_project_symlinked_out_of_the_root_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, _ = scaffold(tmp)
            elsewhere = Path(tmp) / "elsewhere"
            (elsewhere / "docs").mkdir(parents=True)
            (root / "linked").symlink_to(elsewhere)
            expected = None
            self.assertEqual(expected, gs.concept_path(root, "/linked/any.md"))

    def test_a_url_encoded_climb_is_refused_even_though_paths_are_decoded(self):
        """Decoding is required for real names, and must not reopen traversal.

        `%2e%2e%2f` decodes to `../`, which becomes its own path segment and so
        fails the two-segment check before any file is touched.
        """
        expected = None
        with tempfile.TemporaryDirectory() as tmp:
            root, _ = scaffold(tmp)
            self.assertEqual(expected, gs.concept_path(root, "/skadi/%2e%2e%2fone.md"))

    def test_an_encoded_climb_into_a_sibling_folder_is_refused(self):
        expected = None
        with tempfile.TemporaryDirectory() as tmp:
            root, plans = scaffold(tmp)
            (plans.parent / "outside.md").write_text("# no\n", encoding="utf-8")
            self.assertEqual(expected, gs.concept_path(root, "/skadi/..%2Foutside.md"))

    def test_a_dot_segment_project_is_refused(self):
        expected = None
        with tempfile.TemporaryDirectory() as tmp:
            root, _ = scaffold(tmp)
            self.assertEqual(expected, gs.concept_path(root, "/./one.md"))

    def test_a_concept_beside_the_plans_folder_is_refused(self):
        """`source` is trusted, but only its immediate children are reachable."""
        with tempfile.TemporaryDirectory() as tmp:
            root, plans = scaffold(tmp)
            sibling = plans.parent / "outside.md"
            sibling.write_text("# no\n", encoding="utf-8")
            expected = None
            self.assertEqual(expected, gs.concept_path(root, "/skadi/../outside.md"))


class EncodedNameTest(unittest.TestCase):
    """The page percent-encodes each concept name; the server must decode it.

    Every plan filename in this repo today is kebab-case, so this never fires in
    practice — which is exactly why it is pinned rather than left to convention.
    """

    def test_a_name_bearing_a_space_round_trips(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, plans = scaffold(tmp, concepts=("user auth flow.md",))
            expected = (plans / "user auth flow.md").resolve()
            self.assertEqual(expected,
                             gs.concept_path(root, "/skadi/user%20auth%20flow.md"))

    def test_a_name_bearing_a_hash_round_trips(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, plans = scaffold(tmp, concepts=("step #2.md",))
            expected = (plans / "step #2.md").resolve()
            self.assertEqual(expected, gs.concept_path(root, "/skadi/step%20%232.md"))

    def test_a_query_string_is_stripped_rather_than_breaking_the_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, plans = scaffold(tmp)
            expected = (plans / "one.md").resolve()
            self.assertEqual(expected, gs.concept_path(root, "/skadi/one.md?v=2"))


class ToTrashTest(unittest.TestCase):
    def test_the_concept_moves_into_trash_rather_than_vanishing(self):
        with tempfile.TemporaryDirectory() as tmp:
            _, plans = scaffold(tmp)
            target = plans / "one.md"
            expected = plans / ".trash" / "one.md"
            self.assertEqual(expected, gs.to_trash(target))
            self.assertTrue(expected.is_file())
            self.assertFalse(target.exists())

    def test_the_body_survives_the_move(self):
        with tempfile.TemporaryDirectory() as tmp:
            _, plans = scaffold(tmp)
            expected = (plans / "one.md").read_text(encoding="utf-8")
            moved = gs.to_trash(plans / "one.md")
            self.assertEqual(expected, moved.read_text(encoding="utf-8"))

    def test_a_second_casualty_of_the_same_name_does_not_clobber_the_first(self):
        with tempfile.TemporaryDirectory() as tmp:
            _, plans = scaffold(tmp)
            gs.to_trash(plans / "one.md")
            (plans / "one.md").write_text("# the second one\n", encoding="utf-8")
            expected = plans / ".trash" / "one-2.md"
            self.assertEqual(expected, gs.to_trash(plans / "one.md"))

    def test_trash_is_not_rendered_as_a_concept(self):
        """galadriel-render globs the top level only, so .trash stays invisible."""
        spec = importlib.util.spec_from_file_location("gr", HERE / "galadriel-render.py")
        gr = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gr)
        with tempfile.TemporaryDirectory() as tmp:
            _, plans = scaffold(tmp)
            gs.to_trash(plans / "one.md")
            expected = ["two.md"]
            self.assertEqual(expected, [Path(c["file"]).name
                                        for c in gr.collect(plans, None)])


class ProjectsTest(unittest.TestCase):
    def test_a_project_bearing_a_dashboard_is_listed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, plans = scaffold(tmp)
            listed = gs.projects(root)
            self.assertEqual(["skadi"], [p["name"] for p in listed])
            self.assertEqual(str(plans), listed[0]["source"])

    def test_a_folder_without_a_dashboard_is_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, _ = scaffold(tmp)
            (root / "half-built").mkdir()
            expected = ["skadi"]
            self.assertEqual(expected, [p["name"] for p in gs.projects(root)])

    def test_the_index_names_every_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, _ = scaffold(tmp)
            expected = "skadi"
            self.assertIn(expected, gs.index_html(gs.projects(root)))

    def test_an_empty_root_renders_a_placeholder_rather_than_failing(self):
        expected = "No project mirrors yet"
        self.assertIn(expected, gs.index_html([]))


if __name__ == "__main__":
    unittest.main()
