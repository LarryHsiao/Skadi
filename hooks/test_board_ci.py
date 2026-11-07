#!/usr/bin/env python3
"""Tests for board-ci.py — the CI channel writer: binding parsing, scan, grouping."""

import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("board_ci", HERE / "board-ci.py")
board_ci = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(board_ci)

FRONTMATTER = "---\nname: CI Routing\ndescription: x\ntype: reference\n---\n\n"
TC_RUN_OK = (0, "482|success|master|20261107T130000+0000|https://tc/b/482\n")
TC_RUN_BAD = (0, "217|failed|dev|20261107T100000+0000|https://tc/b/217\n")
GH_RUN_OK = (0, "9|success|main|2026-11-07T12:00:00Z|https://github.com/o/r/actions/runs/9\n")


def write_binding(profiles, profile, project_dir, body):
    path = Path(profiles) / profile / "projects" / project_dir
    path.mkdir(parents=True)
    (path / "ci_routing.md").write_text(FRONTMATTER + body, encoding="utf-8")


class ParseBindingTest(unittest.TestCase):
    def test_teamcity_build_types_carry_their_labels(self):
        text = FRONTMATTER + "flavor: teamcity\nbuildTypes:\n  - id: A_Build\n    label: android\n  - id: A_Ios\n"
        expected = {"flavor": "teamcity", "repo": None,
                    "lamps": [{"id": "A_Build", "label": "android"}, {"id": "A_Ios", "label": "A_Ios"}]}
        self.assertEqual(expected, board_ci.parse_binding(text))

    def test_the_legacy_single_build_type_form_becomes_one_lamp(self):
        text = FRONTMATTER + "flavor: teamcity\nbuildTypeId: Old_Build\n"
        expected = {"flavor": "teamcity", "repo": None, "lamps": [{"id": "Old_Build", "label": "Old_Build"}]}
        self.assertEqual(expected, board_ci.parse_binding(text))

    def test_a_github_binding_names_its_repo_and_workflows(self):
        text = FRONTMATTER + "flavor: github\nrepo: o/r\nworkflows:\n  - id: ci.yml\n    label: CI\n"
        expected = {"flavor": "github", "repo": "o/r", "lamps": [{"id": "ci.yml", "label": "CI"}]}
        self.assertEqual(expected, board_ci.parse_binding(text))

    def test_a_file_without_a_flavor_is_unreadable(self):
        self.assertIsNone(board_ci.parse_binding(FRONTMATTER + "nothing useful\n"))


class ProjectNameTest(unittest.TestCase):
    def test_the_trailing_checksum_is_dropped(self):
        self.assertEqual("metis_app", board_ci.project_name("metis_app-579639375ea9"))

    def test_a_name_without_a_checksum_is_kept(self):
        self.assertEqual("plain", board_ci.project_name("plain"))


class ParseTimeTest(unittest.TestCase):
    def test_a_teamcity_stamp_and_an_iso_stamp_name_the_same_instant(self):
        expected = "2026-11-07T13:00:00Z"
        self.assertEqual(expected, board_ci.parse_time("20261107T130000+0000"))
        self.assertEqual(expected, board_ci.parse_time("2026-11-07T13:00:00Z"))

    def test_an_unreadable_stamp_is_none(self):
        self.assertIsNone(board_ci.parse_time("yesterday"))


class MakeLampTest(unittest.TestCase):
    LAMP = {"id": "X", "label": "x"}

    def test_a_hook_that_printed_nothing_is_a_lamp_with_no_runs(self):
        lamp = board_ci.make_lamp(self.LAMP, (0, ""))
        self.assertEqual(("unknown", "no runs"), (lamp["status"], lamp["error"]))

    def test_a_row_with_too_few_fields_is_a_lamp_with_no_runs(self):
        lamp = board_ci.make_lamp(self.LAMP, (0, "482|success|master\n"))
        self.assertEqual(("unknown", "no runs"), (lamp["status"], lamp["error"]))

    def test_a_failed_hook_is_marked_with_the_shared_sentinel(self):
        lamp = board_ci.make_lamp(self.LAMP, (1, ""))
        self.assertEqual(board_ci.HOOK_FAILED, lamp["error"])


class HookArgvTest(unittest.TestCase):
    def test_the_hook_runs_under_the_bash_on_path_never_a_bare_name(self):
        # A bare "bash" under subprocess resolves, on Windows, to WSL's
        # System32\bash.exe ahead of PATH — which fails with no distribution.
        expected = shutil.which("bash")
        self.assertEqual(expected, board_ci.hook_argv("teamcity", None, "X_Build")[0])

    def test_a_teamcity_call_names_the_build_type_and_asks_for_one_run(self):
        argv = board_ci.hook_argv("teamcity", None, "X_Build")
        self.assertEqual(["X_Build", "1"], argv[2:])

    def test_a_github_call_names_the_repo_and_the_workflow(self):
        argv = board_ci.hook_argv("github", "o/r", "ci.yml")
        self.assertEqual(["o/r", "ci.yml", "1"], argv[2:])


class CollectTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.profiles = self.tmp.name

    def hook(self, results):
        def run(flavor, repo, lamp_id):
            return results[(flavor, lamp_id)]
        return run

    def test_no_bindings_yield_no_sources(self):
        channel = board_ci.collect(self.profiles, self.hook({}))
        self.assertEqual([], channel["sources"])

    def test_github_leads_and_each_source_holds_its_projects(self):
        write_binding(self.profiles, "personal", "snotra-aaaaaaaaaaaa",
                      "flavor: teamcity\nbuildTypes:\n  - id: S_Rel\n    label: release\n")
        write_binding(self.profiles, "work", "jubo-bbbbbbbbbbbb",
                      "flavor: github\nrepo: o/r\nworkflows:\n  - id: ci.yml\n    label: CI\n")
        results = {("teamcity", "S_Rel"): TC_RUN_OK, ("github", "ci.yml"): GH_RUN_OK}
        channel = board_ci.collect(self.profiles, self.hook(results))
        expected = [("github", ["jubo"]), ("teamcity", ["snotra"])]
        actual = [(s["source"], [p["name"] for p in s["projects"]]) for s in channel["sources"]]
        self.assertEqual(expected, actual)

    def test_a_lamp_carries_the_latest_run(self):
        write_binding(self.profiles, "personal", "snotra-aaaaaaaaaaaa",
                      "flavor: teamcity\nbuildTypes:\n  - id: S_Rel\n    label: release\n")
        channel = board_ci.collect(self.profiles, self.hook({("teamcity", "S_Rel"): TC_RUN_OK}))
        expected = {"id": "S_Rel", "label": "release", "status": "success", "number": "482",
                    "branch": "master", "finished": "2026-11-07T13:00:00Z", "url": "https://tc/b/482",
                    "error": None}
        self.assertEqual(expected, channel["sources"][0]["projects"][0]["lamps"][0])

    def test_a_red_project_sorts_before_a_green_one_and_wears_the_worst_light(self):
        write_binding(self.profiles, "personal", "aaa-aaaaaaaaaaaa",
                      "flavor: teamcity\nbuildTypes:\n  - id: G\n")
        write_binding(self.profiles, "personal", "zzz-bbbbbbbbbbbb",
                      "flavor: teamcity\nbuildTypes:\n  - id: G2\n  - id: R\n")
        results = {("teamcity", "G"): TC_RUN_OK, ("teamcity", "G2"): TC_RUN_OK, ("teamcity", "R"): TC_RUN_BAD}
        projects = board_ci.collect(self.profiles, self.hook(results))["sources"][0]["projects"]
        self.assertEqual([("zzz", "failed"), ("aaa", "success")], [(p["name"], p["worst"]) for p in projects])

    def test_a_failed_hook_is_an_unknown_lamp_never_a_green_one(self):
        write_binding(self.profiles, "personal", "snotra-aaaaaaaaaaaa", "flavor: teamcity\nbuildTypes:\n  - id: S\n")
        channel = board_ci.collect(self.profiles, self.hook({("teamcity", "S"): (1, "")}))
        lamp = channel["sources"][0]["projects"][0]["lamps"][0]
        self.assertEqual(("unknown", True), (lamp["status"], lamp["error"] is not None))

    def test_a_source_is_unreachable_only_when_every_lamp_failed(self):
        write_binding(self.profiles, "personal", "p-aaaaaaaaaaaa", "flavor: teamcity\nbuildTypes:\n  - id: A\n  - id: B\n")
        both_down = board_ci.collect(self.profiles, self.hook({("teamcity", "A"): (1, ""), ("teamcity", "B"): (1, "")}))
        one_up = board_ci.collect(self.profiles, self.hook({("teamcity", "A"): (1, ""), ("teamcity", "B"): TC_RUN_OK}))
        self.assertEqual((True, False), (both_down["sources"][0]["unreachable"], one_up["sources"][0]["unreachable"]))

    def test_the_same_project_bound_in_two_profiles_appears_once(self):
        body = "flavor: teamcity\nbuildTypes:\n  - id: S\n"
        write_binding(self.profiles, "personal", "snotra-aaaaaaaaaaaa", body)
        write_binding(self.profiles, "work", "snotra-aaaaaaaaaaaa", body)
        channel = board_ci.collect(self.profiles, self.hook({("teamcity", "S"): TC_RUN_OK}))
        self.assertEqual(["snotra"], [p["name"] for p in channel["sources"][0]["projects"]])

    def test_a_gitlab_binding_is_left_off_the_board(self):
        write_binding(self.profiles, "work", "g-aaaaaaaaaaaa", "flavor: gitlab\n")
        self.assertEqual([], board_ci.collect(self.profiles, self.hook({}))["sources"])


if __name__ == "__main__":
    unittest.main()
