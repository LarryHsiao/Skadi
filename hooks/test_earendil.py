"""Tests for /earendil — project detection, report frame, and each check group.

Run: python3 -m unittest hooks/test_earendil.py   (from the repo root)
"""

import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import earendil  # noqa: E402
from earendil_common import FAIL, NA, PASS, WARN, Finding  # noqa: E402

FLUTTER_PUBSPEC = (
    "name: acme_app\n"
    "version: 2.4.0+57\n"
    "environment:\n"
    "  sdk: ^3.9.0\n"
    "dependencies:\n"
    "  flutter:\n"
    "    sdk: flutter\n"
)


def write(root, rel, text=""):
    path = Path(root) / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


class Workdir(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name).resolve()


class DetectionTest(Workdir):
    def test_flutter_project_with_both_platform_dirs(self):
        write(self.root, "pubspec.yaml", FLUTTER_PUBSPEC)
        (self.root / "android").mkdir()
        (self.root / "ios").mkdir()
        project = earendil.detect(self.root)
        expected = ("flutter", self.root / "android", self.root / "ios")
        self.assertEqual(expected, (project.kind, project.android_root, project.ios_root))

    def test_flutter_project_without_android_dir_reports_it_absent(self):
        write(self.root, "pubspec.yaml", FLUTTER_PUBSPEC)
        (self.root / "ios").mkdir()
        project = earendil.detect(self.root)
        self.assertIsNone(project.android_root)

    def test_pure_dart_package_is_not_a_flutter_project(self):
        write(self.root, "pubspec.yaml", "name: lib_only\nenvironment:\n  sdk: ^3.9.0\n")
        self.assertIsNone(earendil.detect(self.root))

    def test_native_android_is_detected_by_settings_gradle(self):
        write(self.root, "settings.gradle.kts", 'include(":app")\n')
        project = earendil.detect(self.root)
        expected = ("native", self.root, None)
        self.assertEqual(expected, (project.kind, project.android_root, project.ios_root))

    def test_native_ios_is_detected_by_xcodeproj(self):
        (self.root / "Acme.xcodeproj").mkdir()
        project = earendil.detect(self.root)
        expected = ("native", None, self.root)
        self.assertEqual(expected, (project.kind, project.android_root, project.ios_root))

    def test_unrelated_directory_is_not_a_mobile_project(self):
        write(self.root, "README.md", "hello")
        self.assertIsNone(earendil.detect(self.root))

    def test_find_root_walks_up_from_a_subdirectory(self):
        write(self.root, "pubspec.yaml", FLUTTER_PUBSPEC)
        (self.root / "lib" / "src").mkdir(parents=True)
        self.assertEqual(self.root, earendil.find_root(self.root / "lib" / "src"))

    def test_find_root_prefers_the_flutter_root_over_the_native_folder_inside_it(self):
        write(self.root, "pubspec.yaml", FLUTTER_PUBSPEC)
        write(self.root, "android/settings.gradle.kts", "")
        self.assertEqual(self.root, earendil.find_root(self.root / "android"))

    def test_find_root_returns_none_when_nothing_marks_a_project(self):
        (self.root / "a" / "b").mkdir(parents=True)
        self.assertIsNone(earendil.find_root(self.root / "a" / "b"))


class SelectionTest(Workdir):
    def project(self):
        write(self.root, "pubspec.yaml", FLUTTER_PUBSPEC)
        (self.root / "android").mkdir()
        (self.root / "ios").mkdir()
        return earendil.detect(self.root)

    def test_platform_argument_drops_the_other_platform(self):
        chosen = earendil.select(self.project(), "android")
        self.assertEqual((self.root / "android", None), (chosen.android_root, chosen.ios_root))

    def test_no_argument_keeps_both_platforms(self):
        chosen = earendil.select(self.project(), None)
        self.assertEqual((self.root / "android", self.root / "ios"), (chosen.android_root, chosen.ios_root))

    def test_platform_with_no_directory_is_refused(self):
        project = self.project()
        project = earendil.replace(project, android_root=None)
        with self.assertRaises(ValueError):
            earendil.select(project, "android")


class VerdictTest(unittest.TestCase):
    def test_a_failing_row_holds_the_verdict(self):
        sections = [("ANDROID", [Finding(FAIL, "services", "mismatch"), Finding(PASS, "sdk", "ok")])]
        expected = ("HOLD", 1, 0, 2)
        self.assertEqual(expected, earendil.verdict(sections))

    def test_warnings_alone_pass(self):
        sections = [("IOS", [Finding(WARN, "pods", "stale"), Finding(PASS, "sdk", "ok")])]
        expected = ("PASS", 0, 1, 2)
        self.assertEqual(expected, earendil.verdict(sections))

    def test_not_applicable_rows_are_not_counted(self):
        sections = [("IOS", [Finding(NA, "doctor", "macOS only"), Finding(PASS, "sdk", "ok")])]
        expected = ("PASS", 0, 0, 1)
        self.assertEqual(expected, earendil.verdict(sections))


class RenderTest(unittest.TestCase):
    def sample(self):
        return [
            ("ANDROID", [Finding(FAIL, "services", "package mismatch", "android/app/google-services.json:14")]),
            ("IOS", [Finding(PASS, "identity", "bundle id com.acme.app")]),
        ]

    def test_report_carries_title_kind_sections_and_verdict(self):
        text = earendil.render("acme_app 2.4.0+57", "Flutter", self.sample())
        for needle in ("Earendil — acme_app 2.4.0+57", "kind: Flutter", "ANDROID", "IOS", "Verdict: HOLD — 1 failing"):
            self.assertIn(needle, text)

    def test_failing_row_lists_its_anchor_under_the_verdict(self):
        text = earendil.render("acme_app", "Flutter", self.sample())
        self.assertIn("1. android/app/google-services.json:14", text)

    def test_clean_report_reads_pass_with_the_row_count(self):
        sections = [("IOS", [Finding(PASS, "identity", "ok"), Finding(PASS, "sdk", "ok")])]
        text = earendil.render("acme_app", "Flutter", sections)
        self.assertIn("Verdict: PASS — 2 checks, 0 failing", text)


class SectionsTest(Workdir):
    def project(self):
        write(self.root, "pubspec.yaml", FLUTTER_PUBSPEC)
        write(self.root, "lib/main.dart", "x")
        return earendil.detect(self.root)

    def test_flutter_project_leads_with_the_flutter_block(self):
        names = [name for name, _ in earendil.build_sections(self.project(), commands=False)]
        self.assertEqual("FLUTTER", names[0])

    def test_no_flutter_flag_drops_the_block(self):
        names = [name for name, _ in earendil.build_sections(self.project(), commands=False, with_flutter=False)]
        self.assertNotIn("FLUTTER", names)

    def names(self, project, **kw):
        return [name.split("  ")[0] for name, _ in earendil.build_sections(project, commands=False, **kw)]

    def test_blocks_follow_flutter_then_android_then_ios(self):
        (self.root / "android").mkdir()
        (self.root / "ios").mkdir()
        self.assertEqual(["FLUTTER", "ANDROID", "IOS"], self.names(self.project()))

    def test_absent_platform_in_a_flutter_project_reads_not_applicable(self):
        (self.root / "ios").mkdir()
        sections = dict(earendil.build_sections(self.project(), commands=False))
        rows = sections["ANDROID"]
        self.assertEqual([(NA, "platform")], [(r.status, r.dim) for r in rows])

    def test_explicit_platform_prints_only_that_block(self):
        (self.root / "android").mkdir()
        (self.root / "ios").mkdir()
        chosen = earendil.select(self.project(), "ios")
        self.assertEqual(["FLUTTER", "IOS"], self.names(chosen))

    def test_native_android_project_prints_only_its_block(self):
        write(self.root, "settings.gradle.kts", "")
        self.assertEqual(["ANDROID"], self.names(earendil.detect(self.root)))

    def test_flutter_title_carries_name_and_version(self):
        self.assertEqual("acme_app 2.4.0+57", earendil.title_of(self.project()))

    def test_native_title_is_the_directory_name(self):
        write(self.root, "settings.gradle.kts", "")
        self.assertEqual(self.root.name, earendil.title_of(earendil.detect(self.root)))

    def test_report_for_a_flutter_project_prints_its_block(self):
        lines = []
        earendil.main(["--root", str(self.project().root), "--no-commands"], out=lines.append)
        self.assertIn("FLUTTER", lines[0])


class MainTest(Workdir):
    def test_directory_with_no_mobile_project_exits_2(self):
        code = earendil.main(["--root", str(self.root), "--no-commands"], out=lambda _: None)
        self.assertEqual(2, code)

    def test_platform_with_no_directory_exits_2(self):
        write(self.root, "pubspec.yaml", FLUTTER_PUBSPEC)
        code = earendil.main(["ios", "--root", str(self.root), "--no-commands"], out=lambda _: None)
        self.assertEqual(2, code)


if __name__ == "__main__":
    unittest.main()
