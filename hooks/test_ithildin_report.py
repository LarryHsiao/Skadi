#!/usr/bin/env python3
"""Tests for ithildin-report.py: the proof page /ithildin renders per AC."""

import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "ithildin-report.py"
_spec = importlib.util.spec_from_file_location("ithildin_report", SCRIPT)
ithildin_report = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ithildin_report)

PNG_BYTES = b"\x89PNG-fake-image"


def _image(directory, name):
    path = Path(directory) / name
    path.write_bytes(PNG_BYTES)
    return str(path)


def _html(out_dir, manifest):
    return ithildin_report.render(manifest, Path(out_dir)).read_text(encoding="utf-8")


def _manifest(acs, **extra):
    return {"slug": "psg-1", "title": "PSG-1 proof", "acs": acs, **extra}


class CapturedAcTest(unittest.TestCase):
    def test_ac_with_shot_shows_text_and_image(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            expected_text = "The empty list shows the placeholder"
            manifest = _manifest([{"text": expected_text, "shot": _image(src, "a.png")}])
            page = _html(out, manifest)
            self.assertIn(expected_text, page)
            self.assertIn('<img src="ithildin-psg-1/ac-1.png">', page)

    def test_shot_is_copied_beside_the_page(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            expected = PNG_BYTES
            _html(out, _manifest([{"text": "A", "shot": _image(src, "a.png")}]))
            actual = (Path(out) / "ithildin-psg-1" / "ac-1.png").read_bytes()
            self.assertEqual(expected, actual)

    def test_acs_are_numbered_in_order(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            acs = [
                {"text": "First", "shot": _image(src, "a.png")},
                {"text": "Second", "shot": _image(src, "b.png")},
            ]
            page = _html(out, _manifest(acs))
            self.assertLess(page.index("<h2>1. "), page.index("<h2>2. "))
            self.assertIn("ac-2.png", page)


class MissingProofTest(unittest.TestCase):
    def test_ac_without_shot_is_a_missing_proof_row(self):
        with TemporaryDirectory() as out:
            expected_hint = "open the settings screen, then ask for the shot"
            page = _html(out, _manifest([{"text": "A", "hint": expected_hint}]))
            self.assertIn('class="missing"', page)
            self.assertIn(expected_hint, page)

    def test_ac_naming_an_absent_file_is_a_missing_proof_row(self):
        with TemporaryDirectory() as out:
            page = _html(out, _manifest([{"text": "A", "shot": "/no/such/file.png"}]))
            self.assertIn('class="missing"', page)

    def test_missing_proof_without_hint_says_not_captured(self):
        with TemporaryDirectory() as out:
            page = _html(out, _manifest([{"text": "A"}]))
            self.assertIn(ithildin_report.DEFAULT_MISSING_HINT, page)

    def test_summary_counts_captured_against_total(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            acs = [{"text": "A", "shot": _image(src, "a.png")}, {"text": "B"}]
            page = _html(out, _manifest(acs))
            self.assertIn("1 of 2 captured", page)


class PageShapeTest(unittest.TestCase):
    def test_ac_text_is_escaped(self):
        with TemporaryDirectory() as out:
            page = _html(out, _manifest([{"text": "<script>x</script>"}]))
            self.assertNotIn("<script>x</script>", page)
            self.assertIn("&lt;script&gt;x&lt;/script&gt;", page)

    def test_page_declares_charset_first(self):
        with TemporaryDirectory() as out:
            page = _html(out, _manifest([{"text": "A"}]))
            expected_second_line = '<meta charset="utf-8">'
            self.assertEqual(expected_second_line, page.splitlines()[1])

    def test_rerun_clears_the_previous_images(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            _html(out, _manifest([{"text": "A", "shot": _image(src, "a.png")}]))
            _html(out, _manifest([{"text": "A"}]))
            self.assertFalse((Path(out) / "ithildin-psg-1" / "ac-1.png").exists())

    def test_unusable_slug_raises(self):
        with TemporaryDirectory() as out:
            manifest = {"slug": "///", "title": "T", "acs": []}
            with self.assertRaises(ValueError):
                ithildin_report.render(manifest, Path(out))


class OptionalFieldsTest(unittest.TestCase):
    def test_notes_render_as_list_items(self):
        with TemporaryDirectory() as out:
            page = _html(out, _manifest([{"text": "A", "notes": ["measured 12px gap"]}]))
            self.assertIn("<li>measured 12px gap</li>", page)

    def test_lede_renders_under_the_title(self):
        with TemporaryDirectory() as out:
            page = _html(out, _manifest([{"text": "A"}], lede="second pass"))
            self.assertIn('<p class="lede">second pass</p>', page)


class VideoTest(unittest.TestCase):
    MP4_BYTES = b"fake-mp4-bytes"

    def _video(self, directory, name="rec.mp4"):
        path = Path(directory) / name
        path.write_bytes(self.MP4_BYTES)
        return str(path)

    def test_video_is_embedded_once_with_controls(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            manifest = _manifest([{"text": "A"}, {"text": "B"}], video=self._video(src))
            page = _html(out, manifest)
            self.assertEqual(1, page.count("<video "))
            self.assertIn('src="ithildin-psg-1/recording.mp4"', page)
            self.assertIn("controls", page)

    def test_video_is_copied_beside_the_page(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            expected = self.MP4_BYTES
            _html(out, _manifest([{"text": "A"}], video=self._video(src)))
            actual = (Path(out) / "ithildin-psg-1" / "recording.mp4").read_bytes()
            self.assertEqual(expected, actual)

    def test_ac_start_time_becomes_a_jump_button(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            manifest = _manifest([{"text": "A", "at": 83}], video=self._video(src))
            page = _html(out, manifest)
            self.assertIn('data-at="83"', page)
            self.assertIn("\u25b6 1:23", page)

    def test_start_time_past_an_hour_shows_hours(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            manifest = _manifest([{"text": "A", "at": 3725}], video=self._video(src))
            page = _html(out, manifest)
            self.assertIn("\u25b6 1:02:05", page)

    def test_absent_video_file_is_a_missing_block_without_buttons(self):
        with TemporaryDirectory() as out:
            expected_hint = "start the recording first"
            manifest = _manifest(
                [{"text": "A", "at": 5}], video="/no/such.mp4", videoHint=expected_hint)
            page = _html(out, manifest)
            self.assertIn(expected_hint, page)
            self.assertNotIn("<video ", page)
            self.assertNotIn("data-at=", page)

    def test_no_video_key_means_no_player_and_no_buttons(self):
        with TemporaryDirectory() as out:
            page = _html(out, _manifest([{"text": "A", "at": 5}]))
            self.assertNotIn("<video ", page)
            self.assertNotIn("data-at=", page)

    def test_jump_script_present_only_with_a_video(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            with_video = _html(out, _manifest([{"text": "A", "at": 1}], video=self._video(src)))
            without = _html(out, _manifest([{"text": "A"}]))
            self.assertIn("currentTime", with_video)
            self.assertNotIn("currentTime", without)

    def test_zero_start_time_still_gets_a_button(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            manifest = _manifest([{"text": "A", "at": 0}], video=self._video(src))
            page = _html(out, manifest)
            self.assertIn('data-at="0"', page)
            self.assertIn("\u25b6 0:00", page)

    def test_fractional_start_time_is_kept_exactly(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            manifest = _manifest([{"text": "A", "at": 12345.678}], video=self._video(src))
            page = _html(out, manifest)
            self.assertIn('data-at="12345.678"', page)

    def test_ac_without_start_time_has_no_button_when_video_present(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            page = _html(out, _manifest([{"text": "A"}], video=self._video(src)))
            self.assertIn("<video ", page)
            self.assertNotIn("data-at=", page)

    def test_absent_video_without_hint_says_not_captured(self):
        with TemporaryDirectory() as out:
            page = _html(out, _manifest([{"text": "A"}], video="/no/such.mp4"))
            self.assertIn(ithildin_report.DEFAULT_MISSING_HINT, page)

    def test_unusable_start_times_raise_naming_the_ac(self):
        for bad in (float("nan"), float("inf"), True, "soon", -1):
            with self.subTest(at=bad), TemporaryDirectory() as src, TemporaryDirectory() as out:
                manifest = _manifest(
                    [{"text": "ok"}, {"text": "A", "at": bad}], video=self._video(src))
                with self.assertRaises(ValueError) as raised:
                    ithildin_report.render(manifest, Path(out))
                self.assertIn("AC 2", str(raised.exception))

    def test_negative_start_time_raises(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            manifest = _manifest([{"text": "A", "at": -1}], video=self._video(src))
            with self.assertRaises(ValueError):
                ithildin_report.render(manifest, Path(out))

    def test_non_numeric_start_time_raises(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            manifest = _manifest([{"text": "A", "at": "soon"}], video=self._video(src))
            with self.assertRaises(ValueError):
                ithildin_report.render(manifest, Path(out))


class CommandLineTest(unittest.TestCase):
    def _run(self, manifest, out):
        path = Path(out) / "manifest.json"
        path.write_text(json.dumps(manifest), encoding="utf-8")
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), str(path), "--out-dir", str(Path(out) / "pages")],
            capture_output=True,
            text=True,
        )

    def test_prints_the_page_path_and_exits_zero(self):
        with TemporaryDirectory() as out:
            result = self._run(_manifest([{"text": "A"}]), out)
            self.assertEqual(0, result.returncode)
            self.assertTrue(result.stdout.strip().endswith("ithildin-psg-1.html"))

    def test_malformed_acs_exit_one_with_reason(self):
        with TemporaryDirectory() as out:
            result = self._run(_manifest(["not a dict"]), out)
            expected_prefix = "ithildin-report: manifest"
            self.assertEqual(1, result.returncode)
            self.assertTrue(result.stderr.startswith(expected_prefix), result.stderr)

    def test_absent_manifest_exits_one_with_reason(self):
        with TemporaryDirectory() as out:
            result = subprocess.run(
                [sys.executable, "-I", str(SCRIPT), str(Path(out) / "none.json")],
                capture_output=True,
                text=True,
            )
            expected_prefix = "ithildin-report: manifest"
            self.assertEqual(1, result.returncode)
            self.assertTrue(result.stderr.startswith(expected_prefix), result.stderr)

    def test_missing_field_exits_one_with_reason(self):
        with TemporaryDirectory() as out:
            result = self._run({"slug": "x", "title": "T"}, out)
            self.assertEqual(1, result.returncode)
            self.assertIn("missing field", result.stderr)


if __name__ == "__main__":
    unittest.main()
