#!/usr/bin/env python3
"""Tests for the Galadriel dashboard renderer.

This file exists because the renderer had none — it is 460 lines of Python
emitting a page that now triggers a destructive action, so the emitted markup
deserves the same pinning its parser already has (`test_rumil_format.py` covers
the concept-file contract; this covers the page).
"""

import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("galadriel_render",
                                               HERE / "galadriel-render.py")
gr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gr)


def page(concepts=("alpha", "beta")):
    """Render a page from a scratch plans folder and return its HTML."""
    with tempfile.TemporaryDirectory() as tmp:
        plans = Path(tmp) / "plans"
        plans.mkdir()
        for name in concepts:
            (plans / f"{name}.md").write_text(
                f"# {name.title()}\n\nprose\n\n## Steps\n- [ ] a\n", encoding="utf-8")
        return gr.render(gr.collect(plans, None), str(plans))


class SelectionControlsTest(unittest.TestCase):
    """The delete affordance — markup only; behaviour is exercised in a browser."""

    def test_the_selection_toggle_is_emitted(self):
        expected = 'id="selToggle"'
        self.assertIn(expected, page())

    def test_the_delete_bar_is_emitted(self):
        expected = 'id="delsel"'
        self.assertIn(expected, page())

    def test_the_delete_button_starts_disabled(self):
        """Nothing is selected on load, so the destructive control must be inert."""
        expected = '<button id="delsel" disabled>'
        self.assertIn(expected, page())

    def test_a_checkbox_rides_on_every_concept(self):
        expected = 'class="box" type="checkbox"'
        self.assertIn(expected, page())

    def test_the_controls_are_removed_when_opened_from_disk(self):
        """DELETE cannot work over file:, so the affordance is not merely hidden."""
        html = page()
        self.assertIn('location.protocol !== "file:"', html)
        self.assertIn('document.getElementById("selToggle").remove()', html)

    def test_a_delete_targets_a_sibling_of_the_dashboard(self):
        """`/<project>/plan-dashboard.html` -> `/<project>/<concept>.md`."""
        expected = 'location.pathname.replace(/[^/]*$/, "")'
        self.assertIn(expected, page())

    def test_a_failed_delete_is_reported_rather_than_reloaded_over(self):
        expected = "could not delete:"
        self.assertIn(expected, page())

    def test_the_delete_is_confirmed_before_it_runs(self):
        expected = "confirm("
        self.assertIn(expected, page())


class ExistingBehaviourTest(unittest.TestCase):
    """The sidebar collapse already shipped; pin it so a rewrite cannot lose it."""

    def test_the_sidebar_toggle_survives(self):
        expected = 'id="sideToggle"'
        self.assertIn(expected, page())

    def test_every_concept_reaches_the_nav(self):
        html = page(("alpha", "beta"))
        for expected in ("Alpha", "Beta"):
            self.assertIn(expected, html)

    def test_the_page_is_self_contained(self):
        """No externally-fetched stylesheet, script, or icon — it must open
        straight from disk. A favicon as an inline data URI fetches nothing
        off disk, so it's not the external dependency this test guards against."""
        html = page()
        self.assertNotIn('href="http', html)
        self.assertNotIn('src="http', html)

    def test_an_empty_folder_still_renders(self):
        expected = "No concepts"
        self.assertIn(expected, page(()))


def git_repo_with_non_ascii_commit(root):
    """A throwaway repo whose one commit's diff carries non-ASCII bytes.

    Real regression fixture for the Windows cp1252 crash: `git show`'s
    stdout must round-trip through `diff_for` without raising or losing
    the em dash.
    """
    env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
    run = lambda *args: subprocess.run(
        ["git", "-C", str(root), *args], check=True,
        capture_output=True, env=env)
    run("init", "-q")
    (root / "note.md").write_text("café — done\n", encoding="utf-8")
    run("add", "note.md")
    run("commit", "-q", "-m", "add note")
    sha = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "HEAD"],
        check=True, capture_output=True, text=True).stdout.strip()
    return sha


class DiffForTest(unittest.TestCase):
    """`diff_for` must survive the exact bytes that killed it on Windows."""

    def test_a_non_ascii_diff_round_trips(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            sha = git_repo_with_non_ascii_commit(repo)
            expected = "café"
            self.assertIn(expected, gr.diff_for([sha], repo))

    def test_a_none_stdout_degrades_to_an_empty_block(self):
        """The observed failure mode: the reader thread dies mid-decode and
        `subprocess.run` returns normally with `stdout=None`, not an
        exception — so the guard must be on the value, not a try/except."""
        expected = ""
        fake = subprocess.CompletedProcess(args=[], returncode=0, stdout=None)
        with patch.object(subprocess, "run", return_value=fake):
            self.assertEqual(expected, gr.diff_for(["deadbeef"], Path(".")))


if __name__ == "__main__":
    unittest.main()
