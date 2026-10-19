#!/usr/bin/env python3
"""Tests for manwe-compare.py: the side-by-side page /manwe --human renders."""

import importlib.util
import json
import re
import subprocess
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "manwe-compare.py"
_spec = importlib.util.spec_from_file_location("manwe_compare", SCRIPT)
manwe_compare = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(manwe_compare)

PNG_BYTES = b"\x89PNG-fake-image"


def _image(directory, name):
    path = Path(directory) / name
    path.write_bytes(PNG_BYTES)
    return str(path)


def _render(out_dir, manifest):
    return manwe_compare.render(manifest, Path(out_dir))


def _html(out_dir, manifest):
    return _render(out_dir, manifest).read_text(encoding="utf-8")


def _pair(src, title="P", **extra):
    return {"title": title, "spec": _image(src, "spec.png"), "shot": _image(src, "shot.png"), **extra}


class OnePairTest(unittest.TestCase):
    def test_pair_draws_both_images_copied_beside_the_page(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            manifest = {"slug": "login", "title": "Login", "pairs": [_pair(src, "Empty form")]}
            expected_images = [
                "manwe-compare-login/pair-1-spec.png",
                "manwe-compare-login/pair-1-shot.png",
            ]

            html = _html(out, manifest)

            for image in expected_images:
                self.assertIn(f'src="{image}"', html)
                self.assertEqual((Path(out) / image).read_bytes(), PNG_BYTES)

    def test_pair_with_both_sides_carries_a_collapsible_overlay(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            manifest = {"slug": "t", "title": "T", "pairs": [_pair(src)]}
            expected_summary = "<summary>Overlay</summary>"
            expected_top = '<img class="top"'

            html = _html(out, manifest)

            self.assertIn(expected_summary, html)
            self.assertIn(expected_top, html)

    def test_overlay_starts_at_half_opacity(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            manifest = {"slug": "t", "title": "T", "pairs": [_pair(src)]}
            expected = 'style="opacity:0.5"'

            html = _html(out, manifest)

            self.assertIn(expected, html)

    def test_page_name_is_the_slug(self):
        with TemporaryDirectory() as out:
            expected = Path(out) / "manwe-compare-login.html"

            page = _render(out, {"slug": "login", "title": "Login", "pairs": []})

            self.assertEqual(page, expected)

    def test_page_is_utf8_and_wears_the_theme(self):
        with TemporaryDirectory() as out:
            expected_head = '<!doctype html>\n<meta charset="utf-8">'
            expected_theme = 'href="skadi-theme.css"'

            html = _html(out, {"slug": "t", "title": "T", "pairs": []})

            self.assertTrue(html.startswith(expected_head))
            self.assertIn(expected_theme, html)

    def test_container_avoids_the_themes_two_column_wrap(self):
        with TemporaryDirectory() as out:
            html = _html(out, {"slug": "t", "title": "T", "pairs": []})

            self.assertIsNone(re.search(r'class="wrap"|\.wrap\b', html))

    def test_markup_in_a_title_is_escaped(self):
        with TemporaryDirectory() as out:
            expected = "&lt;b&gt;x&lt;/b&gt;"

            html = _html(out, {"slug": "t", "title": "<b>x</b>", "pairs": []})

            self.assertNotIn("<b>x</b>", html)
            self.assertIn(expected, html)

    def test_lede_renders_under_the_title(self):
        with TemporaryDirectory() as out:
            expected = '<p class="lede">Left is Figma.</p>'

            html = _html(out, {"slug": "t", "title": "T", "lede": "Left is Figma.", "pairs": []})

            self.assertIn(expected, html)


class OverlayLabelTest(unittest.TestCase):
    def test_each_overlay_carries_its_own_labels(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            pairs = [
                _pair(src, "One", specLabel="Figma", shotLabel="iPad"),
                _pair(src, "Two", specLabel="Sketch", shotLabel="Pixel"),
            ]
            expected = [("Figma", "iPad"), ("Sketch", "Pixel")]

            html = _html(out, {"slug": "t", "title": "T", "pairs": pairs})

            found = re.findall(r'data-spec-label="(.*?)" data-shot-label="(.*?)"', html)
            self.assertEqual(found, expected)

    def test_a_label_cannot_break_out_of_its_attribute(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            hostile = '"><script>x</script>'
            pairs = [_pair(src, specLabel=hostile, shotLabel="it's")]

            html = _html(out, {"slug": "t", "title": "T", "pairs": pairs})

            self.assertNotIn("<script>x</script>", html)
            self.assertIn("it&#x27;s", html)


class MissingSideTest(unittest.TestCase):
    def test_missing_shot_shows_a_placeholder_naming_the_hint(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            pair = {"title": "Chosen", "spec": _image(src, "spec.png"), "shot": None,
                    "shotHint": "choose a protocol and I'll shoot it"}
            expected = '<div class="missing">choose a protocol and I&#x27;ll shoot it</div>'

            html = _html(out, {"slug": "t", "title": "T", "pairs": [pair]})

            self.assertIn(expected, html)

    def test_missing_spec_shows_its_own_hint(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            pair = {"title": "No frame", "spec": None, "shot": _image(src, "shot.png"),
                    "specHint": "no frame in Figma"}
            expected = '<div class="missing">no frame in Figma</div>'

            html = _html(out, {"slug": "t", "title": "T", "pairs": [pair]})

            self.assertIn(expected, html)

    def test_missing_side_without_a_hint_still_says_not_captured(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            pair = {"title": "No spec", "spec": None, "shot": _image(src, "shot.png")}
            expected = '<div class="missing">not captured yet</div>'

            html = _html(out, {"slug": "t", "title": "T", "pairs": [pair]})

            self.assertIn(expected, html)

    def test_pair_with_a_missing_side_has_no_overlay(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            pair = {"title": "Half", "spec": _image(src, "spec.png"), "shot": None}
            expected_overlays = 0

            html = _html(out, {"slug": "t", "title": "T", "pairs": [pair]})

            self.assertEqual(html.count("<details"), expected_overlays)

    def test_a_named_but_absent_file_counts_as_not_captured(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            pair = {"title": "Gone", "spec": str(Path(src) / "nope.png"), "shot": _image(src, "shot.png")}
            expected = '<div class="missing">not captured yet</div>'

            html = _html(out, {"slug": "t", "title": "T", "pairs": [pair]})

            self.assertIn(expected, html)


class NotesAndManyPairsTest(unittest.TestCase):
    def test_notes_render_as_a_list_in_order(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            pair = _pair(src, "Gaps", notes=["gap 52 vs 40", "label Start vs Starts"])
            expected = '<ul class="notes"><li>gap 52 vs 40</li><li>label Start vs Starts</li></ul>'

            html = _html(out, {"slug": "t", "title": "T", "pairs": [pair]})

            self.assertIn(expected, html)

    def test_several_pairs_land_on_one_page_in_order(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            pairs = [_pair(src, f"Pair {n}") for n in (1, 2, 3)]
            expected = ["1. Pair 1", "2. Pair 2", "3. Pair 3"]

            html = _html(out, {"slug": "t", "title": "T", "pairs": pairs})

            self.assertEqual(re.findall(r"<h2>(.*?)</h2>", html), expected)

    def test_a_second_slug_leaves_the_first_page_untouched(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            first = _render(out, {"slug": "one", "title": "One", "pairs": [_pair(src)]})
            before = first.read_bytes()

            _render(out, {"slug": "two", "title": "Two", "pairs": [_pair(src)]})

            self.assertEqual(first.read_bytes(), before)
            self.assertTrue((Path(out) / "manwe-compare-two.html").exists())

    def test_rerunning_a_slug_with_fewer_pairs_leaves_no_stale_images(self):
        with TemporaryDirectory() as src, TemporaryDirectory() as out:
            _render(out, {"slug": "t", "title": "T", "pairs": [_pair(src), _pair(src)]})
            expected = ["pair-1-shot.png", "pair-1-spec.png"]

            _render(out, {"slug": "t", "title": "T", "pairs": [_pair(src)]})

            kept = sorted(p.name for p in (Path(out) / "manwe-compare-t").iterdir())
            self.assertEqual(kept, expected)


class SlugTest(unittest.TestCase):
    def test_slug_is_confined_to_one_path_segment(self):
        with TemporaryDirectory() as out:
            expected = Path(out) / "manwe-compare-etc-x-y.html"

            page = _render(out, {"slug": "../../etc/x y", "title": "T", "pairs": []})

            self.assertEqual(page, expected)

    def test_empty_slug_is_refused(self):
        with TemporaryDirectory() as out:
            with self.assertRaises(ValueError):
                _render(out, {"slug": "///", "title": "T", "pairs": []})


class CommandLineTest(unittest.TestCase):
    def _run(self, manifest_text, out_dir):
        with TemporaryDirectory() as src:
            manifest = Path(src) / "m.json"
            manifest.write_text(manifest_text)
            return subprocess.run(
                [sys.executable, "-I", str(SCRIPT), str(manifest), "--out-dir", out_dir],
                capture_output=True, text=True,
            )

    def test_prints_the_page_path_and_exits_zero(self):
        with TemporaryDirectory() as out:
            expected = (0, str(Path(out) / "manwe-compare-cli.html"))

            run = self._run(json.dumps({"slug": "cli", "title": "C", "pairs": []}), out)

            self.assertEqual((run.returncode, run.stdout.strip()), expected)

    def test_a_missing_manifest_exits_non_zero_with_a_reason(self):
        run = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "/nonexistent/m.json"],
            capture_output=True, text=True,
        )

        self.assertNotEqual(run.returncode, 0)
        self.assertIn("manifest", run.stderr)

    def test_a_manifest_missing_a_field_names_the_field(self):
        with TemporaryDirectory() as out:
            run = self._run(json.dumps({"slug": "cli", "pairs": []}), out)

            self.assertNotEqual(run.returncode, 0)
            self.assertIn("missing field 'title'", run.stderr)


if __name__ == "__main__":
    unittest.main()
