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


class LayoutTest(unittest.TestCase):
    def test_a_tall_screenshot_is_capped_to_the_viewport(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            expected_rule = "max-height: 55vh"
            page = _html(out, _manifest([{"text": "A", "shot": _image(src, "a.png")}]))
            self.assertIn(expected_rule, page)

    def test_a_pinned_video_leaves_room_for_a_whole_screenshot(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            expected_rule = "max-height: 40vh"
            manifest = _manifest([{"text": "A"}], video=str(Path(src) / "v.mp4"))
            (Path(src) / "v.mp4").write_bytes(b"x")
            self.assertIn(expected_rule, _html(out, manifest))

    def test_section_spacing_pins_the_compare_page_values(self):
        with TemporaryDirectory() as out:
            page = _html(out, _manifest([{"text": "A"}]))
            self.assertIn("section { margin: 0 0 40px; }", page)
            self.assertIn("section h2 { margin: 0 0 8px; font-size: 1.15rem; }", page)


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

    def test_video_preloads_so_a_paused_seek_paints_a_frame(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            expected = 'preload="auto"'
            page = _html(out, _manifest([{"text": "A"}], video=self._video(src)))
            self.assertIn(expected, page)

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


class VerdictTest(unittest.TestCase):
    def _page(self, *acs):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            built = [{"shot": _image(src, f"a{n}.png"), **ac} for n, ac in enumerate(acs, 1)]
            return _html(out, _manifest(built))

    def test_fail_shows_a_red_badge_and_a_red_rule(self):
        page = self._page({"text": "A", "verdict": "fail"})
        self.assertIn('<span class="badge no">FAIL</span>', page)
        self.assertIn('class="ac fail"', page)

    def test_pass_shows_a_green_badge_and_rule(self):
        page = self._page({"text": "A", "verdict": "pass"})
        self.assertIn('<span class="badge yes">PASS</span>', page)
        self.assertIn('class="ac pass"', page)

    def test_unclear_shows_a_grey_badge_and_rule(self):
        page = self._page({"text": "A", "verdict": "unclear"})
        self.assertIn('<span class="badge unclear">UNCLEAR</span>', page)
        self.assertIn('class="ac unclear"', page)

    def test_verdict_word_is_case_insensitive(self):
        page = self._page({"text": "A", "verdict": " Fail "})
        self.assertIn(">FAIL<", page)

    def test_reason_is_shown_and_labelled_as_the_models_reading(self):
        page = self._page({"text": "A", "verdict": "fail", "reason": "list still shows 4 posts"})
        self.assertIn("list still shows 4 posts", page)
        self.assertIn("model's reading", page)

    def test_a_human_verdict_is_labelled_as_yours(self):
        page = self._page({"text": "A", "verdict": "pass", "verdictBy": "human"})
        self.assertIn("your reading", page)
        self.assertNotIn("model's reading", page)

    def test_reason_is_escaped(self):
        page = self._page({"text": "A", "verdict": "fail", "reason": "<b>bold</b>"})
        self.assertIn("&lt;b&gt;bold&lt;/b&gt;", page)

    def test_no_verdict_means_no_badge_and_a_plain_rule(self):
        page = self._page({"text": "A"})
        for word in ("PASS", "FAIL", "UNCLEAR"):
            self.assertNotIn(f">{word}<", page)
        self.assertIn('class="ac"', page)

    def test_unknown_verdict_raises_naming_the_ac(self):
        with self.assertRaises(ValueError) as raised:
            self._page({"text": "A"}, {"text": "B", "verdict": "maybe"})
        self.assertIn("AC 2", str(raised.exception))

    def test_verdict_without_a_shot_raises_naming_the_ac(self):
        with TemporaryDirectory() as out:
            manifest = _manifest([{"text": "A", "verdict": "pass"}])
            with self.assertRaises(ValueError) as raised:
                ithildin_report.render(manifest, Path(out))
            self.assertIn("AC 1", str(raised.exception))

    def test_a_non_text_reader_raises_naming_the_ac(self):
        with self.assertRaises(ValueError) as raised:
            self._page({"text": "A", "verdict": "pass", "verdictBy": ["model"]})
        self.assertIn("AC 1", str(raised.exception))

    def test_an_unknown_reader_raises_even_without_a_verdict(self):
        with self.assertRaises(ValueError) as raised:
            self._page({"text": "A", "verdictBy": "robot"})
        self.assertIn("AC 1", str(raised.exception))

    def test_a_reason_without_a_verdict_raises_naming_the_ac(self):
        with self.assertRaises(ValueError) as raised:
            self._page({"text": "A"}, {"text": "B", "reason": "looks wrong"})
        self.assertIn("AC 2", str(raised.exception))

    def test_unknown_reader_raises_naming_the_ac(self):
        with self.assertRaises(ValueError) as raised:
            self._page({"text": "A", "verdict": "pass", "verdictBy": "robot"})
        self.assertIn("AC 1", str(raised.exception))


class TallyTest(unittest.TestCase):
    def _page(self, *acs):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            built = []
            for number, ac in enumerate(acs, 1):
                shot = {} if ac.pop("noshot", False) else {"shot": _image(src, f"a{number}.png")}
                built.append({"text": f"AC {number}", **shot, **ac})
            return _html(out, _manifest(built))

    def test_every_ac_lands_in_exactly_one_count(self):
        page = self._page(
            {"verdict": "pass"}, {"verdict": "fail"}, {"verdict": "unclear"}, {}, {"noshot": True})
        for expected in ("1 pass", "1 fail", "1 unclear", "1 not judged", "1 not captured"):
            self.assertIn(expected, page)

    def test_zero_counts_stay_visible(self):
        page = self._page({"noshot": True})
        for expected in ("0 pass", "0 fail", "0 unclear", "0 not judged", "1 not captured"):
            self.assertIn(expected, page)

    def test_counts_are_exact_past_ten(self):
        page = self._page(*[{"verdict": "pass"} for _ in range(12)])
        self.assertIn("12 pass", page)

    def test_first_fail_link_points_at_the_first_failing_ac(self):
        page = self._page({"verdict": "pass"}, {"verdict": "fail"}, {"verdict": "fail"})
        self.assertIn('<a class="first" href="#ac-2">first fail', page)
        self.assertEqual(1, page.count("first fail"))

    def test_no_first_fail_link_without_a_failure(self):
        page = self._page({"verdict": "pass"}, {})
        self.assertNotIn("first fail", page)


class ReasonClampTest(unittest.TestCase):
    def _page(self, **ac):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            built = {"text": "A", "shot": _image(src, "a.png"), **ac}
            return _html(out, _manifest([built]))

    def test_a_reason_is_clamped_with_a_toggle_that_starts_hidden(self):
        page = self._page(verdict="fail", reason="long text")
        self.assertIn('class="reason clamp"', page)
        self.assertIn('<button class="more" type="button" hidden>show full reason</button>', page)

    def test_the_toggle_script_only_reveals_the_button_on_real_overflow(self):
        page = self._page(verdict="fail", reason="long text")
        self.assertIn("scrollHeight > ", page)

    def test_no_reason_means_no_toggle_and_no_script(self):
        page = self._page(verdict="fail")
        self.assertNotIn("show full reason", page)
        self.assertNotIn("scrollHeight", page)

    def test_a_report_without_verdicts_carries_neither(self):
        page = self._page()
        self.assertNotIn("show full reason", page)
        self.assertNotIn("scrollHeight", page)


class AnchorTest(unittest.TestCase):
    def test_a_pinned_video_marks_the_page_so_anchors_clear_the_player(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            (Path(src) / "v.mp4").write_bytes(b"x")
            page = _html(out, _manifest([{"text": "A"}], video=str(Path(src) / "v.mp4")))
            self.assertIn('class="proof has-video"', page)
            self.assertIn(".proof.has-video .ac { scroll-margin-top:", page)

    def test_without_a_video_anchors_get_no_extra_margin(self):
        with TemporaryDirectory() as out:
            page = _html(out, _manifest([{"text": "A"}]))
            self.assertIn('class="proof"', page)
            self.assertNotIn('class="proof has-video"', page)


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
