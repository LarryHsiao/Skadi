#!/usr/bin/env python3
"""Tests for ithildin-record.py: one continuous simulator recording, a mark per AC.

The recorder and the converter are faked as scripts on PATH, so the tests need
no simulator and no ffmpeg. POSIX only: the fakes are executable scripts.
"""

import json
import os
import shutil
import stat
import subprocess
import sys
import time
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "ithildin-record.py"

FAKE_XCRUN = """#!/usr/bin/env python3
import os, pathlib, signal, sys, time
if os.environ.get("FAKE_XCRUN_FAIL"):
    print("No devices are booted.", file=sys.stderr, flush=True)
    sys.exit(149)
out = sys.argv[-1]
done = []
signal.signal(signal.SIGINT, lambda *_: done.append(True))
print("Recording started", file=sys.stderr, flush=True)
while not done:
    time.sleep(0.05)
pathlib.Path(out).write_bytes(b"fake-mov")
print("Wrote video to: " + out, file=sys.stderr, flush=True)
"""

FAKE_FFPROBE = """#!/usr/bin/env python3
import os
print(os.environ.get("FAKE_DURATION", "0.5"))
"""

FAKE_FFMPEG = """#!/usr/bin/env python3
import os, pathlib, sys
pathlib.Path(os.environ["FAKE_FFMPEG_LOG"]).write_text(" ".join(sys.argv[1:]))
if os.environ.get("FAKE_FFMPEG_FAIL"):
    sys.exit(1)
source = sys.argv[sys.argv.index("-i") + 1]
pathlib.Path(sys.argv[-1]).write_bytes(pathlib.Path(source).read_bytes())
"""


def _install(directory, name, body):
    path = Path(directory) / name
    path.write_text(body.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


@unittest.skipIf(os.name == "nt", "fakes are POSIX scripts")
class RecorderTestCase(unittest.TestCase):
    with_ffmpeg = True

    def setUp(self):
        self._tmp = TemporaryDirectory()
        root = Path(self._tmp.name)
        self.bin = root / "bin"
        self.bin.mkdir()
        self.state = root / "state"
        self.ffmpeg_log = root / "ffmpeg.log"
        (self.bin / "ps").symlink_to(shutil.which("ps"))  # the hook checks the recorder by it
        _install(self.bin, "xcrun", FAKE_XCRUN)
        _install(self.bin, "ffprobe", FAKE_FFPROBE)
        if self.with_ffmpeg:
            _install(self.bin, "ffmpeg", FAKE_FFMPEG)

    def tearDown(self):
        self._stop_quietly()
        self._tmp.cleanup()

    def _stop_quietly(self):
        if (self.state / "current.json").exists():
            self.run_hook("stop")

    def run_hook(self, *args, extra_env=None, path=None):
        env = {
            **os.environ,
            "PATH": path if path is not None else f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "FAKE_FFMPEG_LOG": str(self.ffmpeg_log),
            **(extra_env or {}),
        }
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), *args, "--state-dir", str(self.state)],
            capture_output=True,
            text=True,
            env=env,
        )

    def read_state(self):
        return json.loads((self.state / "current.json").read_text(encoding="utf-8"))


class StartTest(RecorderTestCase):
    def test_start_records_pid_and_empty_marks(self):
        result = self.run_hook("start")
        self.assertEqual(0, result.returncode, result.stderr)
        state = self.read_state()
        self.assertEqual([], state["marks"])
        self.assertGreater(state["pid"], 0)
        self.assertTrue(result.stdout.strip().endswith(".mov"))

    def test_start_fails_loud_when_the_recorder_cannot_start(self):
        expected_code = 4
        result = self.run_hook("start", extra_env={"FAKE_XCRUN_FAIL": "1"})
        self.assertEqual(expected_code, result.returncode)
        self.assertIn("No devices are booted", result.stderr)
        self.assertFalse((self.state / "current.json").exists())

    def test_second_start_is_refused(self):
        self.run_hook("start")
        expected_code = 3
        result = self.run_hook("start")
        self.assertEqual(expected_code, result.returncode)
        self.assertIn("already recording", result.stderr)

    def test_start_without_xcrun_names_the_platform_need(self):
        expected_code = 3
        result = self.run_hook("start", path=str(self.bin / "nowhere"))
        self.assertEqual(expected_code, result.returncode)
        self.assertIn("macOS", result.stderr)


class MarkTest(RecorderTestCase):
    def test_mark_without_a_recording_is_refused(self):
        expected_code = 2
        result = self.run_hook("mark", "ac-1")
        self.assertEqual(expected_code, result.returncode)
        self.assertIn("no recording in progress", result.stderr)

    def test_marks_keep_label_and_increasing_offsets(self):
        self.run_hook("start")
        self.run_hook("mark", "ac-1")
        time.sleep(0.2)
        self.run_hook("mark", "ac-2")
        marks = self.read_state()["marks"]
        self.assertEqual(["ac-1", "ac-2"], [mark["label"] for mark in marks])
        self.assertGreaterEqual(marks[0]["at"], 0)
        self.assertGreater(marks[1]["at"], marks[0]["at"])


class StopTest(RecorderTestCase):
    def _record(self, *labels):
        self.run_hook("start")
        for label in labels:
            self.run_hook("mark", label)

    def test_stop_prints_video_marks_and_duration(self):
        self._record("ac-1")
        result = self.run_hook("stop", "--out", str(Path(self._tmp.name) / "rec.mp4"))
        self.assertEqual(0, result.returncode, result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(Path(report["video"]).is_file())
        self.assertEqual(["ac-1"], [mark["label"] for mark in report["marks"]])
        self.assertGreater(report["duration"], 0)

    def test_stop_clears_state_and_the_raw_recording(self):
        self._record()
        mov = Path(self.read_state()["mov"])
        self.run_hook("stop", "--out", str(Path(self._tmp.name) / "rec.mp4"))
        self.assertFalse((self.state / "current.json").exists())
        self.assertFalse(mov.exists())

    def test_stop_pads_a_recording_shorter_than_the_wall_clock(self):
        self._record()
        time.sleep(1.0)
        self.run_hook("stop", "--out", str(Path(self._tmp.name) / "rec.mp4"),
                      extra_env={"FAKE_DURATION": "0.1"})
        log = self.ffmpeg_log.read_text(encoding="utf-8")
        self.assertIn("tpad=stop_mode=clone:stop_duration=", log)

    def test_stop_does_not_pad_a_recording_that_already_covers_the_clock(self):
        self._record()
        self.run_hook("stop", "--out", str(Path(self._tmp.name) / "rec.mp4"),
                      extra_env={"FAKE_DURATION": "999"})
        self.assertNotIn("tpad", self.ffmpeg_log.read_text(encoding="utf-8"))

    def test_stop_without_a_recording_is_refused(self):
        expected_code = 2
        result = self.run_hook("stop")
        self.assertEqual(expected_code, result.returncode)
        self.assertIn("no recording in progress", result.stderr)


class RobustnessTest(RecorderTestCase):
    def _write_state(self, **fields):
        self.state.mkdir(parents=True, exist_ok=True)
        state = {"pid": 999999, "started_at": time.time(), "mov": str(self.state / "recording.mov"),
                 "marks": [], **fields}
        (self.state / "current.json").write_text(json.dumps(state), encoding="utf-8")

    def _pad_seconds(self):
        log = self.ffmpeg_log.read_text(encoding="utf-8")
        return float(log.split("stop_duration=")[1].split()[0])

    def test_retried_stop_pads_to_when_the_recorder_stopped_not_to_now(self):
        (self.bin / "ffmpeg").unlink()
        self.run_hook("start", path=str(self.bin))
        time.sleep(0.6)
        self.run_hook("stop", path=str(self.bin))
        time.sleep(1.5)
        _install(self.bin, "ffmpeg", FAKE_FFMPEG)
        result = self.run_hook("stop", extra_env={"FAKE_DURATION": "0.1"})
        report = json.loads(result.stdout)
        self.assertLess(report["duration"], 1.2)
        self.assertLess(self._pad_seconds(), 1.0)

    def test_start_refuses_to_overwrite_an_unfinished_recording(self):
        (self.bin / "ffmpeg").unlink()
        self.run_hook("start", path=str(self.bin))
        self.run_hook("stop", path=str(self.bin))
        mov = Path(self.read_state()["mov"])
        expected_code = 3
        result = self.run_hook("start")
        self.assertEqual(expected_code, result.returncode)
        self.assertIn("unfinished", result.stderr)
        self.assertTrue(mov.exists())
        (self.state / "current.json").unlink()

    def test_start_proceeds_over_stale_state_with_no_recording(self):
        self._write_state(pid=999999)
        result = self.run_hook("start")
        self.assertEqual(0, result.returncode, result.stderr)

    def test_a_reused_pid_is_not_taken_for_the_recorder(self):
        self._write_state(pid=os.getpid())
        result = self.run_hook("start")
        self.assertEqual(0, result.returncode, result.stderr)

    def test_stop_never_signals_a_process_that_is_not_the_recorder(self):
        bystander = subprocess.Popen(["sleep", "30"])
        try:
            mov = self.state / "recording.mov"
            self.state.mkdir(parents=True, exist_ok=True)
            mov.write_bytes(b"fake-mov")
            self._write_state(pid=bystander.pid, mov=str(mov))
            result = self.run_hook("stop", "--out", str(Path(self._tmp.name) / "rec.mp4"))
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIsNone(bystander.poll())
        finally:
            bystander.kill()
            bystander.wait()

    def test_unreadable_state_names_the_file(self):
        self.state.mkdir(parents=True, exist_ok=True)
        (self.state / "current.json").write_text("{not json", encoding="utf-8")
        expected_code = 2
        result = self.run_hook("mark", "ac-1")
        self.assertEqual(expected_code, result.returncode)
        self.assertIn("current.json", result.stderr)
        (self.state / "current.json").unlink()

    def test_an_unreadable_duration_still_converts(self):
        self.run_hook("start")
        result = self.run_hook("stop", "--out", str(Path(self._tmp.name) / "rec.mp4"),
                               extra_env={"FAKE_DURATION": "N/A"})
        self.assertEqual(0, result.returncode, result.stderr)

    def test_ffmpeg_failure_fails_loud_and_keeps_the_raw_recording(self):
        self.run_hook("start")
        mov = Path(self.read_state()["mov"])
        expected_code = 5
        result = self.run_hook("stop", extra_env={"FAKE_FFMPEG_FAIL": "1"})
        self.assertEqual(expected_code, result.returncode)
        self.assertTrue(mov.exists())
        (self.state / "current.json").unlink()

    def test_default_output_sits_beside_the_raw_recording(self):
        self.run_hook("start")
        expected = str(self.state / "recording.mp4")
        result = self.run_hook("stop")
        self.assertEqual(expected, json.loads(result.stdout)["video"])


class StopWithoutFfmpegTest(RecorderTestCase):
    with_ffmpeg = False

    def test_missing_ffmpeg_fails_loud_and_keeps_the_raw_recording(self):
        self.run_hook("start", path=str(self.bin))
        mov = Path(self.read_state()["mov"])
        expected_code = 5
        result = self.run_hook("stop", path=str(self.bin))
        self.assertEqual(expected_code, result.returncode)
        self.assertIn("ffmpeg", result.stderr)
        self.assertTrue(mov.exists())
        (self.state / "current.json").unlink()


if __name__ == "__main__":
    unittest.main()
