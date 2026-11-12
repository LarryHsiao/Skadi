#!/usr/bin/env python3
"""Tests for ithildin-clips.py: one clip per AC, cut from the single recording.

ffmpeg and ffprobe are faked as scripts on PATH, so the tests need neither.
POSIX only: the fakes are executable scripts.
"""

import json
import os
import stat
import subprocess
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "ithildin-clips.py"

FAKE_FFPROBE = """#!/usr/bin/env python3
import os
print(os.environ.get("FAKE_DURATION", "12.0"))
"""

FAKE_FFMPEG = """#!/usr/bin/env python3
import os, pathlib, sys
out = sys.argv[-1]
with open(os.environ["FAKE_FFMPEG_LOG"], "a") as log:
    log.write(" ".join(sys.argv[1:]) + "\\n")
if os.environ.get("FAKE_FFMPEG_FAIL_ON") and os.environ["FAKE_FFMPEG_FAIL_ON"] in out:
    sys.exit(1)
pathlib.Path(out).write_bytes(b"fake-clip")
"""


def _install(directory, name, body):
    path = Path(directory) / name
    path.write_text(body.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


@unittest.skipIf(os.name == "nt", "fakes are POSIX scripts")
class ClipsTestCase(unittest.TestCase):
    with_ffmpeg = True

    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "ffmpeg.log"
        _install(self.bin, "ffprobe", FAKE_FFPROBE)
        if self.with_ffmpeg:
            _install(self.bin, "ffmpeg", FAKE_FFMPEG)
        self.video = self.root / "recording.mp4"
        self.video.write_bytes(b"fake-mp4")

    def tearDown(self):
        self._tmp.cleanup()

    def stop_json(self, marks, **extra):
        path = self.root / "stop.json"
        path.write_text(json.dumps({"video": str(self.video), "marks": marks, "duration": 12.0, **extra}), encoding="utf-8")
        return path

    def run_hook(self, stop_path, *args, extra_env=None, path=None):
        env = {
            **os.environ,
            "PATH": path if path is not None else f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "FAKE_FFMPEG_LOG": str(self.log),
            **(extra_env or {}),
        }
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), str(stop_path), *args],
            capture_output=True, text=True, env=env,
        )

    def ffmpeg_calls(self):
        return self.log.read_text(encoding="utf-8").splitlines() if self.log.exists() else []


def _marks(*pairs):
    return [{"label": label, "at": at} for label, at in pairs]


THREE = _marks(("ac-1", 0.0), ("ac-2", 4.0), ("ac-3", 8.0))


class BoundaryTest(ClipsTestCase):
    def test_each_mark_starts_a_clip_that_ends_at_the_next_mark(self):
        self.run_hook(self.stop_json(THREE))
        calls = self.ffmpeg_calls()
        expected = [("0.000", "4.000"), ("4.000", "4.000"), ("8.000", "4.000")]
        actual = [(c.split("-ss ")[1].split()[0], c.split("-t ")[1].split()[0]) for c in calls]
        self.assertEqual(expected, actual)

    def test_the_last_clip_ends_at_the_end_of_the_video(self):
        self.run_hook(self.stop_json(THREE), extra_env={"FAKE_DURATION": "11.5"})
        expected_length = "3.500"
        self.assertEqual(expected_length, self.ffmpeg_calls()[-1].split("-t ")[1].split()[0])

    def test_marks_given_out_of_order_are_sorted_by_time(self):
        shuffled = _marks(("ac-3", 8.0), ("ac-1", 0.0), ("ac-2", 4.0))
        result = self.run_hook(self.stop_json(shuffled))
        expected = ["ac-1", "ac-2", "ac-3"]
        self.assertEqual(expected, [clip["label"] for clip in json.loads(result.stdout)["clips"]])

    def test_clips_are_cut_by_re_encoding_so_they_start_where_asked(self):
        self.run_hook(self.stop_json(_marks(("ac-1", 1.0))))
        tokens = self.ffmpeg_calls()[0].split()
        for expected in ("libx264", "-an", "+faststart", "yuv420p"):
            self.assertIn(expected, tokens)
        self.assertLess(tokens.index("-ss"), tokens.index("-i"))


class OutputTest(ClipsTestCase):
    def test_clips_are_named_for_their_label_in_the_out_dir(self):
        out_dir = self.root / "clips"
        result = self.run_hook(self.stop_json(THREE), "--out-dir", str(out_dir))
        self.assertEqual(0, result.returncode, result.stderr)
        expected = [str(out_dir / f"clip-ac-{n}.mp4") for n in (1, 2, 3)]
        self.assertEqual(expected, [clip["clip"] for clip in json.loads(result.stdout)["clips"]])
        self.assertTrue(all(Path(path).is_file() for path in expected))

    def test_the_default_out_dir_sits_beside_the_recording(self):
        result = self.run_hook(self.stop_json(_marks(("ac-1", 0.0))))
        expected = str(self.root / "clips" / "clip-ac-1.mp4")
        self.assertEqual(expected, json.loads(result.stdout)["clips"][0]["clip"])

    def test_each_clip_reports_its_label_start_and_end(self):
        result = self.run_hook(self.stop_json(THREE))
        first = json.loads(result.stdout)["clips"][0]
        expected = {"label": "ac-1", "at": 0.0, "end": 4.0}
        self.assertEqual(expected, {key: first[key] for key in ("label", "at", "end")})

    def test_a_label_with_odd_characters_makes_a_safe_file_name(self):
        result = self.run_hook(self.stop_json(_marks(("AC 1 / dark", 0.0))))
        expected = "clip-AC-1-dark.mp4"
        self.assertEqual(expected, Path(json.loads(result.stdout)["clips"][0]["clip"]).name)


class SkipTest(ClipsTestCase):
    def test_a_clip_shorter_than_half_a_second_is_skipped_with_a_reason(self):
        marks = _marks(("ac-1", 0.0), ("ac-2", 0.2), ("ac-3", 5.0))
        result = json.loads(self.run_hook(self.stop_json(marks)).stdout)
        expected_kept = ["ac-2", "ac-3"]
        self.assertEqual(expected_kept, [clip["label"] for clip in result["clips"]])
        skipped = {entry["label"]: entry["reason"] for entry in result["skipped"]}
        self.assertEqual(["ac-1"], list(skipped))
        self.assertIn("shorter than 0.5", skipped["ac-1"])

    def test_a_last_clip_shorter_than_half_a_second_is_skipped(self):
        marks = _marks(("ac-1", 0.0), ("ac-2", 11.8))
        result = json.loads(self.run_hook(self.stop_json(marks)).stdout)
        self.assertEqual(["ac-1"], [clip["label"] for clip in result["clips"]])
        self.assertEqual(["ac-2"], [entry["label"] for entry in result["skipped"]])

    def test_a_mark_at_or_after_the_end_of_the_video_is_skipped_with_a_reason(self):
        marks = _marks(("ac-1", 0.0), ("ac-2", 12.0))
        result = json.loads(self.run_hook(self.stop_json(marks)).stdout)
        skipped = {entry["label"]: entry["reason"] for entry in result["skipped"]}
        self.assertIn("ac-2", skipped)
        self.assertIn("end of the video", skipped["ac-2"])

    def test_no_marks_means_no_clips_and_no_ffmpeg_call(self):
        result = self.run_hook(self.stop_json([]))
        self.assertEqual(0, result.returncode, result.stderr)
        expected = {"clips": [], "skipped": [], "failed": []}
        self.assertEqual(expected, json.loads(result.stdout))
        self.assertEqual([], self.ffmpeg_calls())


class InputValidationTest(ClipsTestCase):
    def _refused(self, marks):
        result = self.run_hook(self.stop_json(marks))
        self.assertEqual(2, result.returncode, f"{marks!r}: {result.stderr}")
        self.assertTrue(result.stderr.startswith("ithildin-clips:"), result.stderr)
        self.assertEqual([], self.ffmpeg_calls())

    def test_each_kind_of_bad_mark_is_refused(self):
        bad_marks = [
            [{"label": "ac-1", "at": -1}],
            [{"label": "ac-1", "at": True}],
            [{"label": "ac-1", "at": "soon"}],
            [{"at": 1.0}],
            ["not a dict"],
            [{"label": "ac-1", "at": float("nan")}],
            [{"label": "ac-1", "at": float("inf")}],
        ]
        for marks in bad_marks:
            with self.subTest(marks=marks):
                self._refused(marks)

    def test_labels_that_differ_only_in_case_are_refused(self):
        self._refused(_marks(("AC-1", 0.0), ("ac-1", 3.0)))

    def test_json_that_is_not_recorder_output_is_refused(self):
        for body in ('{"marks": []}', '{"video": "x"}', "[]", '"text"'):
            with self.subTest(body=body):
                path = self.root / "odd.json"
                path.write_text(body, encoding="utf-8")
                result = self.run_hook(path)
                self.assertEqual(2, result.returncode)
                self.assertIn("ithildin-record.py stop", result.stderr)

    def test_an_unreadable_recording_length_is_refused(self):
        result = self.run_hook(self.stop_json(THREE), extra_env={"FAKE_DURATION": "N/A"})
        self.assertEqual(2, result.returncode)
        self.assertIn("length", result.stderr)

    def test_an_out_dir_that_cannot_be_made_is_refused(self):
        blocker = self.root / "a-file"
        blocker.write_text("not a directory", encoding="utf-8")
        result = self.run_hook(self.stop_json(THREE), "--out-dir", str(blocker / "clips"))
        self.assertEqual(2, result.returncode)
        self.assertTrue(result.stderr.startswith("ithildin-clips:"), result.stderr)


class SecondRunTest(ClipsTestCase):
    def test_a_clip_from_an_earlier_run_is_overwritten(self):
        out_dir = self.root / "clips"
        out_dir.mkdir()
        (out_dir / "clip-ac-1.mp4").write_bytes(b"old")
        self.run_hook(self.stop_json(THREE), "--out-dir", str(out_dir))
        expected = b"fake-clip"
        self.assertEqual(expected, (out_dir / "clip-ac-1.mp4").read_bytes())

    def test_a_clip_from_an_earlier_run_with_more_marks_is_left_alone(self):
        out_dir = self.root / "clips"
        out_dir.mkdir()
        (out_dir / "clip-ac-9.mp4").write_bytes(b"older")
        self.run_hook(self.stop_json(THREE), "--out-dir", str(out_dir))
        self.assertEqual(b"older", (out_dir / "clip-ac-9.mp4").read_bytes())


class FailureTest(ClipsTestCase):
    def test_a_duplicate_label_is_refused_naming_it(self):
        expected_code = 2
        result = self.run_hook(self.stop_json(_marks(("ac-1", 0.0), ("ac-1", 3.0))))
        self.assertEqual(expected_code, result.returncode)
        self.assertIn("ac-1", result.stderr)
        self.assertEqual([], self.ffmpeg_calls())

    def test_an_absent_input_file_is_refused(self):
        expected_code = 2
        result = self.run_hook(self.root / "no-such.json")
        self.assertEqual(expected_code, result.returncode)
        self.assertTrue(result.stderr.startswith("ithildin-clips:"), result.stderr)

    def test_unreadable_json_is_refused(self):
        bad = self.root / "bad.json"
        bad.write_text("{not json", encoding="utf-8")
        expected_code = 2
        result = self.run_hook(bad)
        self.assertEqual(expected_code, result.returncode)
        self.assertTrue(result.stderr.startswith("ithildin-clips:"), result.stderr)

    def test_a_recording_that_is_not_there_is_refused(self):
        stop = self.stop_json(THREE)
        self.video.unlink()
        expected_code = 2
        result = self.run_hook(stop)
        self.assertEqual(expected_code, result.returncode)
        self.assertIn("recording", result.stderr)

    def test_one_failed_clip_is_named_and_the_others_are_still_reported(self):
        expected_code = 4
        result = self.run_hook(self.stop_json(THREE), extra_env={"FAKE_FFMPEG_FAIL_ON": "clip-ac-2"})
        self.assertEqual(expected_code, result.returncode)
        self.assertIn("ac-2", result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(["ac-1", "ac-3"], [clip["label"] for clip in report["clips"]])
        self.assertEqual(["ac-2"], [entry["label"] for entry in report["failed"]])


class TrimTest(ClipsTestCase):
    def _lengths(self):
        return [call.split("-t ")[1].split()[0] for call in self.ffmpeg_calls()]

    def test_trim_end_stops_each_clip_but_the_last_before_the_next_mark(self):
        result = self.run_hook(self.stop_json(THREE), "--trim-end", "0.5")
        self.assertEqual(0, result.returncode, result.stderr)
        expected = ["3.500", "3.500", "4.000"]
        self.assertEqual(expected, self._lengths())

    def test_the_reported_end_moves_with_the_trim(self):
        result = self.run_hook(self.stop_json(THREE), "--trim-end", "0.5")
        expected = [3.5, 7.5, 12.0]
        self.assertEqual(expected, [clip["end"] for clip in json.loads(result.stdout)["clips"]])

    def test_the_last_clip_is_never_trimmed(self):
        self.run_hook(self.stop_json(THREE), "--trim-end", "2", extra_env={"FAKE_DURATION": "11.5"})
        expected_last = "3.500"
        self.assertEqual(expected_last, self._lengths()[-1])

    def test_no_option_and_zero_both_mean_no_trim(self):
        self.run_hook(self.stop_json(THREE))
        without = self._lengths()
        self.log.unlink()
        self.run_hook(self.stop_json(THREE), "--trim-end", "0")
        self.assertEqual(without, self._lengths())
        self.assertEqual(["4.000", "4.000", "4.000"], without)

    def test_a_clip_left_under_half_a_second_by_the_trim_is_skipped_naming_the_trim(self):
        marks = _marks(("ac-1", 0.0), ("ac-2", 0.8), ("ac-3", 5.0))
        result = json.loads(self.run_hook(self.stop_json(marks), "--trim-end", "0.5").stdout)
        skipped = {entry["label"]: entry["reason"] for entry in result["skipped"]}
        self.assertEqual(["ac-1"], list(skipped))
        self.assertIn("shorter than 0.5", skipped["ac-1"])
        self.assertIn("trimming 0.5", skipped["ac-1"])
        self.assertEqual(["ac-2", "ac-3"], [clip["label"] for clip in result["clips"]])

    def test_a_trim_longer_than_the_gap_skips_the_clip_naming_the_trim(self):
        marks = _marks(("ac-1", 0.0), ("ac-2", 1.0), ("ac-3", 6.0))
        result = json.loads(self.run_hook(self.stop_json(marks), "--trim-end", "2").stdout)
        self.assertEqual(["ac-1"], [entry["label"] for entry in result["skipped"]])
        self.assertIn("trimming 2", result["skipped"][0]["reason"])

    def test_a_clip_left_at_exactly_half_a_second_by_the_trim_is_kept(self):
        marks = _marks(("ac-1", 0.0), ("ac-2", 1.0), ("ac-3", 6.0))
        result = json.loads(self.run_hook(self.stop_json(marks), "--trim-end", "0.5").stdout)
        self.assertEqual(["ac-1", "ac-2", "ac-3"], [clip["label"] for clip in result["clips"]])
        self.assertEqual([], result["skipped"])

    def test_a_skip_without_a_trim_does_not_mention_trimming(self):
        marks = _marks(("ac-1", 0.0), ("ac-2", 0.2), ("ac-3", 5.0))
        result = json.loads(self.run_hook(self.stop_json(marks)).stdout)
        self.assertNotIn("trimming", result["skipped"][0]["reason"])

    def test_an_unusable_trim_is_refused_with_exit_2(self):
        for bad in ("-1", "nan", "inf", "soon", ""):
            with self.subTest(trim=bad):
                result = self.run_hook(self.stop_json(THREE), "--trim-end", bad)
                self.assertEqual(2, result.returncode, result.stderr)
                self.assertIn("trim-end", result.stderr)
                self.assertEqual([], self.ffmpeg_calls())


class MissingToolTest(ClipsTestCase):
    with_ffmpeg = False

    def test_missing_ffmpeg_fails_loud_naming_it(self):
        expected_code = 3
        result = self.run_hook(self.stop_json(THREE), path=str(self.bin))
        self.assertEqual(expected_code, result.returncode)
        self.assertIn("ffmpeg", result.stderr)


if __name__ == "__main__":
    unittest.main()
