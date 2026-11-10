#!/usr/bin/env python3
"""Tests for board_schedule.py — the board server's timed jobs: config, due rule, runner."""

import importlib.util
import json
import shutil
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("board_schedule", HERE / "board_schedule.py")
board_schedule = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(board_schedule)

Job = board_schedule.Job


def job(name="ci", script="board-ci.py", args=(), every_s=300, timeout_s=120):
    return Job(name, script, tuple(args), every_s, timeout_s)


class HooksDirCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.hooks = Path(self.tmp.name) / "hooks"
        self.hooks.mkdir()
        self.board = Path(self.tmp.name) / "board"
        self.board.mkdir()

    def script(self, name, body="pass\n"):
        path = self.hooks / name
        path.write_text(body, encoding="utf-8")
        return path

    def write_schedule(self, payload):
        text = payload if isinstance(payload, str) else json.dumps(payload)
        (self.board / "schedule.json").write_text(text, encoding="utf-8")


class ParseJobsTest(HooksDirCase):
    def test_a_valid_entry_becomes_a_job(self):
        self.script("board-ci.py")
        text = json.dumps({"jobs": [{"name": "ci", "script": "board-ci.py", "every_s": 300}]})
        expected = [job("ci", "board-ci.py", (), 300, 120)]
        jobs, errors = board_schedule.parse_jobs(text, self.hooks)
        self.assertEqual((expected, []), (jobs, errors))

    def test_args_and_a_timeout_are_kept(self):
        self.script("board.sh")
        text = json.dumps({"jobs": [{"name": "mrs", "script": "board.sh", "args": ["attention", "mrs"],
                                      "every_s": 900, "timeout_s": 60}]})
        expected = [job("mrs", "board.sh", ("attention", "mrs"), 900, 60)]
        self.assertEqual(expected, board_schedule.parse_jobs(text, self.hooks)[0])

    def test_a_script_outside_the_hooks_folder_is_refused(self):
        text = json.dumps({"jobs": [{"name": "x", "script": "../evil.sh", "every_s": 300}]})
        jobs, errors = board_schedule.parse_jobs(text, self.hooks)
        self.assertEqual(([], 1), (jobs, len(errors)))

    def test_a_script_that_does_not_exist_is_refused(self):
        text = json.dumps({"jobs": [{"name": "x", "script": "missing.py", "every_s": 300}]})
        self.assertEqual(1, len(board_schedule.parse_jobs(text, self.hooks)[1]))

    def test_an_unknown_suffix_is_refused(self):
        self.script("tool.rb")
        text = json.dumps({"jobs": [{"name": "x", "script": "tool.rb", "every_s": 300}]})
        self.assertEqual(1, len(board_schedule.parse_jobs(text, self.hooks)[1]))

    def test_an_interval_under_the_floor_is_refused(self):
        self.script("board-ci.py")
        text = json.dumps({"jobs": [{"name": "ci", "script": "board-ci.py", "every_s": 1}]})
        self.assertEqual(1, len(board_schedule.parse_jobs(text, self.hooks)[1]))

    def test_a_duplicate_name_is_refused_and_the_first_kept(self):
        self.script("board-ci.py")
        entry = {"name": "ci", "script": "board-ci.py", "every_s": 300}
        jobs, errors = board_schedule.parse_jobs(json.dumps({"jobs": [entry, entry]}), self.hooks)
        self.assertEqual((1, 1), (len(jobs), len(errors)))

    def test_one_bad_entry_does_not_spoil_a_good_one(self):
        self.script("board-ci.py")
        good = {"name": "ci", "script": "board-ci.py", "every_s": 300}
        bad = {"name": "x", "script": "missing.py", "every_s": 300}
        jobs, errors = board_schedule.parse_jobs(json.dumps({"jobs": [bad, good]}), self.hooks)
        self.assertEqual((["ci"], 1), ([j.name for j in jobs], len(errors)))

    def test_text_that_is_not_json_is_one_error_and_no_jobs(self):
        jobs, errors = board_schedule.parse_jobs("{nope", self.hooks)
        self.assertEqual(([], 1), (jobs, len(errors)))


class LoadJobsTest(HooksDirCase):
    def test_no_file_gives_the_default_ci_job(self):
        self.script("board-ci.py")
        jobs, errors = board_schedule.load_jobs(self.board, self.hooks)
        self.assertEqual((["ci"], 300, []), ([j.name for j in jobs], jobs[0].every_s, errors))

    def test_a_file_replaces_the_default(self):
        self.script("board-ci.py")
        self.script("board.sh")
        self.write_schedule({"jobs": [{"name": "mrs", "script": "board.sh", "args": ["attention", "mrs"],
                                        "every_s": 900}]})
        jobs, errors = board_schedule.load_jobs(self.board, self.hooks)
        self.assertEqual((["mrs"], []), ([j.name for j in jobs], errors))

    def test_a_file_that_is_not_utf8_reports_and_falls_back_instead_of_raising(self):
        self.script("board-ci.py")
        (self.board / "schedule.json").write_bytes(b'{"jobs": [] } \xff\xfe')
        jobs, errors = board_schedule.load_jobs(self.board, self.hooks)
        self.assertEqual((["ci"], 1), ([j.name for j in jobs], len(errors)))

    def test_an_explicit_empty_list_is_respected_as_no_jobs(self):
        self.script("board-ci.py")
        self.write_schedule({"jobs": []})
        self.assertEqual(([], []), board_schedule.load_jobs(self.board, self.hooks))

    def test_a_broken_file_reports_and_falls_back_to_the_default(self):
        self.script("board-ci.py")
        self.write_schedule("{nope")
        jobs, errors = board_schedule.load_jobs(self.board, self.hooks)
        self.assertEqual((["ci"], 1), ([j.name for j in jobs], len(errors)))


class DueTest(unittest.TestCase):
    def test_a_job_never_run_is_due(self):
        self.assertEqual(["ci"], [j.name for j in board_schedule.due([job()], {}, set(), 1000.0)])

    def test_a_job_is_not_due_before_its_interval(self):
        started = {"ci": 1000.0}
        self.assertEqual([], board_schedule.due([job(every_s=300)], started, set(), 1299.0))

    def test_a_job_is_due_at_its_interval(self):
        started = {"ci": 1000.0}
        self.assertEqual(["ci"], [j.name for j in board_schedule.due([job(every_s=300)], started, set(), 1300.0)])

    def test_a_job_still_running_is_never_due(self):
        started = {"ci": 0.0}
        self.assertEqual([], board_schedule.due([job(every_s=300)], started, {"ci"}, 9999.0))


class ArgvTest(unittest.TestCase):
    def test_a_python_script_runs_under_this_interpreter(self):
        argv = board_schedule.argv_for(job(script="board-ci.py", args=("--x",)), Path("/h"))
        self.assertEqual([sys.executable, str(Path("/h") / "board-ci.py"), "--x"], argv)

    def test_a_shell_script_runs_under_the_bash_on_path(self):
        argv = board_schedule.argv_for(job(script="board.sh", args=("attention", "mrs")), Path("/h"))
        expected = [shutil.which("bash") or "bash", str(Path("/h") / "board.sh"), "attention", "mrs"]
        self.assertEqual(expected, argv)


class RunJobTest(HooksDirCase):
    def test_a_script_that_exits_zero_is_ok(self):
        self.script("good.py", "import sys\nsys.exit(0)\n")
        ok, detail = board_schedule.run_job(job("good", "good.py"), self.hooks)
        self.assertEqual((True, ""), (ok, detail))

    def test_a_failing_script_reports_its_exit_code_and_last_words(self):
        self.script("bad.py", "import sys\nsys.stderr.write('boom\\n')\nsys.exit(3)\n")
        ok, detail = board_schedule.run_job(job("bad", "bad.py"), self.hooks)
        self.assertEqual((False, True, True), (ok, "exit 3" in detail, "boom" in detail))

    def test_a_script_past_its_timeout_is_killed_and_reported(self):
        self.script("slow.py", "import time\ntime.sleep(30)\n")
        ok, detail = board_schedule.run_job(job("slow", "slow.py", timeout_s=1), self.hooks)
        self.assertEqual((False, True), (ok, "timed out" in detail))

    def test_a_grandchild_holding_the_output_does_not_hold_the_run_past_its_timeout(self):
        self.script("spawn.py", "import subprocess, sys, time\n"
                                "subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(6)'])\n"
                                "time.sleep(30)\n")
        started = time.monotonic()
        ok, detail = board_schedule.run_job(job("spawn", "spawn.py", timeout_s=1), self.hooks)
        elapsed = time.monotonic() - started
        self.assertEqual((False, True, True), (ok, "timed out" in detail, elapsed < 4))

    def test_the_environment_reaches_the_script(self):
        self.script("env.py", "import os, sys\nsys.exit(0 if os.environ.get('BOARD_DIR') == 'x' else 1)\n")
        ok, _ = board_schedule.run_job(job("env", "env.py"), self.hooks, {"BOARD_DIR": "x"})
        self.assertTrue(ok)


class ScheduleTest(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.lines = []
        self.threads = []

    def spawn(self, work):
        thread = threading.Thread(target=work)
        thread.start()
        self.threads.append(thread)

    def join(self):
        for thread in self.threads:
            thread.join(timeout=5)

    def schedule(self, run, every_s=300):
        return board_schedule.Schedule([job(every_s=every_s)], run, self.lines.append, self.spawn)

    def test_a_due_job_runs_once_and_again_after_its_interval(self):
        def run(j):
            self.calls.append(j.name)
            return True, ""
        schedule = self.schedule(run)
        schedule.tick(0.0)
        self.join()
        schedule.tick(100.0)
        self.join()
        schedule.tick(300.0)
        self.join()
        self.assertEqual(["ci", "ci"], self.calls)

    def test_a_job_still_running_is_not_started_again(self):
        release = threading.Event()

        def run(j):
            self.calls.append(j.name)
            release.wait(timeout=5)
            return True, ""
        schedule = self.schedule(run, every_s=10)
        schedule.tick(0.0)
        schedule.tick(1000.0)
        release.set()
        self.join()
        schedule.tick(2000.0)
        self.join()
        self.assertEqual(["ci", "ci"], self.calls)

    def test_a_job_that_raises_does_not_escape_and_is_logged(self):
        def run(j):
            raise RuntimeError("kaboom")
        schedule = self.schedule(run)
        schedule.tick(0.0)
        self.join()
        self.assertEqual(True, any("kaboom" in line for line in self.lines))

    def test_a_failed_job_is_logged_with_its_detail(self):
        schedule = self.schedule(lambda j: (False, "exit 2: no network"))
        schedule.tick(0.0)
        self.join()
        self.assertEqual(True, any("exit 2: no network" in line for line in self.lines))

    def test_a_job_that_raised_is_due_again_after_its_interval(self):
        outcomes = iter([RuntimeError("once"), None])

        def run(j):
            outcome = next(outcomes)
            if outcome:
                raise outcome
            self.calls.append(j.name)
            return True, ""
        schedule = self.schedule(run, every_s=10)
        schedule.tick(0.0)
        self.join()
        schedule.tick(10.0)
        self.join()
        self.assertEqual(["ci"], self.calls)


if __name__ == "__main__":
    unittest.main()
