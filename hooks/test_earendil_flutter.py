"""Tests for the FLUTTER block of /earendil (earendil_flutter.py)."""

import os
import stat
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import earendil_flutter as flutter  # noqa: E402
from earendil_common import FAIL, NA, PASS, WARN  # noqa: E402
from test_earendil import FLUTTER_PUBSPEC, Workdir, write  # noqa: E402

STUB_FLUTTER = """#!/bin/bash
case "$1" in
  --version) echo '{"frameworkVersion":"%(flutter)s","dartSdkVersion":"%(dart)s"}' ;;
  pub) echo '%(pub_out)s' >&2; exit %(pub_exit)s ;;
  doctor) printf '%%s\\n' '[✓] Flutter (Channel stable, 3.35.7)' '[!] Android toolchain - develop for Android devices' '[✓] Connected device (1 available)' ;;
esac
"""


def git_init(root):
    subprocess.run(["git", "-C", str(root), "init", "-q"], check=True, capture_output=True)


def statuses(findings):
    return [(f.status, f.dim) for f in findings]


def stub_flutter(root, flutter_version="3.35.7", dart="3.9.2", pub_exit=0, pub_out=""):
    bin_dir = Path(root) / "stub-bin"
    bin_dir.mkdir(exist_ok=True)
    script = bin_dir / "flutter"
    script.write_text(STUB_FLUTTER % {"flutter": flutter_version, "dart": dart, "pub_exit": pub_exit, "pub_out": pub_out})
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    return bin_dir


class SatisfiesTest(unittest.TestCase):
    def test_caret_admits_the_same_major(self):
        self.assertTrue(flutter.satisfies("3.9.2", "^3.9.0"))

    def test_caret_refuses_the_next_major(self):
        self.assertFalse(flutter.satisfies("4.0.0", "^3.9.0"))

    def test_range_is_checked_at_both_ends(self):
        expected = [True, False, False]
        actual = [flutter.satisfies(v, ">=3.9.0 <4.0.0") for v in ("3.9.2", "3.8.9", "4.0.0")]
        self.assertEqual(expected, actual)

    def test_any_admits_everything(self):
        self.assertTrue(flutter.satisfies("1.0.0", "any"))

    def test_unreadable_constraint_is_not_refused(self):
        self.assertTrue(flutter.satisfies("3.9.2", "weird"))


class VersionTest(Workdir):
    def test_well_formed_version_passes_with_its_build_number(self):
        write(self.root, "pubspec.yaml", FLUTTER_PUBSPEC)
        rows = flutter.version_rows(self.root)
        self.assertEqual([(PASS, "version")], statuses(rows))

    def test_missing_version_fails(self):
        write(self.root, "pubspec.yaml", "name: a\ndependencies:\n  flutter:\n    sdk: flutter\n")
        self.assertEqual([(FAIL, "version")], statuses(flutter.version_rows(self.root)))

    def test_malformed_version_fails(self):
        write(self.root, "pubspec.yaml", "name: a\nversion: two\n")
        self.assertEqual([(FAIL, "version")], statuses(flutter.version_rows(self.root)))

    def test_trailing_comment_and_quotes_do_not_break_the_version(self):
        for line in ('version: 1.0.0+1 # note', 'version: "1.0.0+1"', "version: '1.0.0+1'  # note"):
            write(self.root, "pubspec.yaml", f"name: a\n{line}\n")
            self.assertEqual(("1.0.0", "1"), flutter.pubspec_version(self.root), line)

    def test_pubspec_version_returns_name_and_build(self):
        write(self.root, "pubspec.yaml", FLUTTER_PUBSPEC)
        self.assertEqual(("2.4.0", "57"), flutter.pubspec_version(self.root))

    def test_build_number_not_above_the_last_tag_warns(self):
        write(self.root, "pubspec.yaml", FLUTTER_PUBSPEC)
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        for argv in (["init", "-q"], ["add", "."], ["commit", "-qm", "x"], ["tag", "v2.4.0+57"]):
            subprocess.run(["git", "-C", str(self.root), *argv], check=True, env=env, capture_output=True)
        self.assertEqual([(WARN, "version")], statuses(flutter.version_rows(self.root)))


class DepsTest(Workdir):
    def pubspec(self, deps):
        write(self.root, "pubspec.yaml", "name: a\nversion: 1.0.0+1\ndependencies:\n  flutter:\n    sdk: flutter\n" + deps)
        write(self.root, "pubspec.lock", "packages: {}\n")
        write(self.root, ".dart_tool/package_config.json", "{}")
        future = (self.root / "pubspec.yaml").stat().st_mtime + 10
        os.utime(self.root / ".dart_tool/package_config.json", (future, future))

    def test_clean_pubspec_with_current_lock_passes(self):
        self.pubspec("")
        self.assertEqual([(PASS, "deps")], statuses(flutter.deps_rows(self.root, "flutter", commands=False)))

    def test_missing_lock_warns(self):
        self.pubspec("")
        (self.root / "pubspec.lock").unlink()
        self.assertEqual([(WARN, "deps")], statuses(flutter.deps_rows(self.root, "flutter", commands=False)))

    def test_package_config_older_than_pubspec_warns(self):
        self.pubspec("")
        past = (self.root / "pubspec.yaml").stat().st_mtime - 100
        os.utime(self.root / ".dart_tool/package_config.json", (past, past))
        self.assertEqual([(WARN, "deps")], statuses(flutter.deps_rows(self.root, "flutter", commands=False)))

    def test_git_dependency_without_ref_warns_with_its_line(self):
        self.pubspec("  acme_ui:\n    git: https://example.com/acme_ui.git\n")
        rows = flutter.deps_rows(self.root, "flutter", commands=False)
        self.assertEqual([(WARN, "deps", "pubspec.yaml:6")], [(r.status, r.dim, r.anchor) for r in rows])

    def test_git_dependency_with_ref_passes(self):
        self.pubspec("  acme_ui:\n    git:\n      url: https://example.com/a.git\n      ref: v1.2.0\n")
        self.assertEqual([(PASS, "deps")], statuses(flutter.deps_rows(self.root, "flutter", commands=False)))

    def test_git_dependency_with_a_path_subfolder_is_not_a_path_dependency(self):
        self.pubspec("  acme_ui:\n    git:\n      url: https://example.com/a.git\n      path: packages/acme_ui\n      ref: v1.2.0\n")
        self.assertEqual([(PASS, "deps")], statuses(flutter.deps_rows(self.root, "flutter", commands=False)))

    def test_git_dependency_with_a_path_subfolder_but_no_ref_still_warns_once(self):
        self.pubspec("  acme_ui:\n    git:\n      url: https://example.com/a.git\n      path: packages/acme_ui\n")
        rows = flutter.deps_rows(self.root, "flutter", commands=False)
        self.assertEqual([(WARN, "deps")], statuses(rows))
        self.assertIn("no ref", rows[0].text)

    def test_path_dependency_with_an_unusual_child_indent_still_warns(self):
        self.pubspec("  acme_ui:\n   path: ../acme_ui\n")
        self.assertEqual([(WARN, "deps")], statuses(flutter.deps_rows(self.root, "flutter", commands=False)))

    def test_path_dependency_warns(self):
        self.pubspec("  acme_ui:\n    path: ../acme_ui\n")
        self.assertEqual([(WARN, "deps")], statuses(flutter.deps_rows(self.root, "flutter", commands=False)))

    def test_dry_run_that_cannot_reach_pub_dev_warns_instead_of_failing(self):
        self.pubspec("")
        bin_dir = stub_flutter(self.root, pub_exit=1, pub_out="Failed host lookup: 'pub.dev'")
        with mock.patch.dict(os.environ, {"PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"}):
            rows = flutter.deps_rows(self.root, "flutter", commands=True)
        self.assertEqual((WARN, "deps"), statuses(rows)[0])

    def test_failing_dry_run_fails(self):
        self.pubspec("")
        bin_dir = stub_flutter(self.root, pub_exit=1)
        with mock.patch.dict(os.environ, {"PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"}):
            rows = flutter.deps_rows(self.root, "flutter", commands=True)
        self.assertEqual((FAIL, "deps"), statuses(rows)[0])


class AssetsTest(Workdir):
    def project(self, declared, files=()):
        lines = "".join(f"    - {entry}\n" for entry in declared)
        write(self.root, "pubspec.yaml", FLUTTER_PUBSPEC + "flutter:\n  assets:\n" + lines)
        for name in files:
            write(self.root, name, "x")

    def test_declared_files_that_exist_pass(self):
        self.project(["assets/logo.png"], ["assets/logo.png"])
        self.assertEqual([(PASS, "assets")], statuses(flutter.assets_rows(self.root)))

    def test_declared_file_that_is_missing_fails(self):
        self.project(["assets/logo.png"])
        self.assertEqual((FAIL, "assets"), statuses(flutter.assets_rows(self.root))[0])

    def test_declared_directory_covers_its_direct_children(self):
        self.project(["assets/img/"], ["assets/img/a.png"])
        self.assertEqual([(PASS, "assets")], statuses(flutter.assets_rows(self.root)))

    def test_undeclared_file_under_assets_warns(self):
        self.project(["assets/logo.png"], ["assets/logo.png", "assets/extra.png"])
        self.assertEqual([(WARN, "assets")], statuses(flutter.assets_rows(self.root)))

    def test_map_form_asset_with_flavors_is_read_by_its_path(self):
        write(self.root, "pubspec.yaml", FLUTTER_PUBSPEC + "flutter:\n  assets:\n    - path: assets/x.png\n      flavors:\n        - dev\n")
        write(self.root, "assets/x.png", "x")
        self.assertEqual([(PASS, "assets")], statuses(flutter.assets_rows(self.root)))

    def test_font_files_are_checked_too(self):
        write(self.root, "pubspec.yaml", FLUTTER_PUBSPEC + "flutter:\n  fonts:\n    - family: X\n      fonts:\n        - asset: fonts/x.ttf\n")
        self.assertEqual((FAIL, "assets"), statuses(flutter.assets_rows(self.root))[0])

    def test_project_with_no_assets_yields_no_row(self):
        write(self.root, "pubspec.yaml", FLUTTER_PUBSPEC)
        self.assertEqual([], flutter.assets_rows(self.root))


class CodegenTest(Workdir):
    def test_generated_file_older_than_its_source_warns(self):
        write(self.root, "lib/user.g.dart", "g")
        write(self.root, "lib/user.dart", "s")
        old = (self.root / "lib/user.g.dart").stat().st_mtime - 100
        os.utime(self.root / "lib/user.g.dart", (old, old))
        self.assertEqual([(WARN, "codegen")], statuses(flutter.codegen_rows(self.root)))

    def test_unchanged_output_is_current_when_build_runner_ran_after_the_source_edit(self):
        write(self.root, "lib/user.g.dart", "g")
        write(self.root, "lib/user.dart", "s")
        write(self.root, ".dart_tool/build/abc123/asset_graph.json", "{}")
        source = (self.root / "lib/user.dart").stat().st_mtime
        os.utime(self.root / "lib/user.g.dart", (source - 100, source - 100))
        os.utime(self.root / ".dart_tool/build/abc123/asset_graph.json", (source + 100, source + 100))
        self.assertEqual([(PASS, "codegen")], statuses(flutter.codegen_rows(self.root)))

    def test_graph_directly_under_dart_tool_build_counts_as_a_build(self):
        write(self.root, "lib/user.g.dart", "g")
        write(self.root, "lib/user.dart", "s")
        write(self.root, ".dart_tool/build/asset_graph.json", "{}")
        source = (self.root / "lib/user.dart").stat().st_mtime
        os.utime(self.root / "lib/user.g.dart", (source - 100, source - 100))
        os.utime(self.root / ".dart_tool/build/asset_graph.json", (source + 100, source + 100))
        self.assertEqual([(PASS, "codegen")], statuses(flutter.codegen_rows(self.root)))

    def test_only_the_source_edited_after_the_last_build_is_named(self):
        for name in ("old", "fresh"):
            write(self.root, f"lib/{name}.g.dart", "g")
            write(self.root, f"lib/{name}.dart", "s")
        write(self.root, ".dart_tool/build/asset_graph.json", "{}")
        base = (self.root / "lib/old.dart").stat().st_mtime
        for name, source_at in (("old", base - 50), ("fresh", base + 50)):
            os.utime(self.root / f"lib/{name}.dart", (source_at, source_at))
            os.utime(self.root / f"lib/{name}.g.dart", (base - 200, base - 200))
        os.utime(self.root / ".dart_tool/build/asset_graph.json", (base, base))
        rows = flutter.codegen_rows(self.root)
        self.assertEqual([(WARN, "codegen")], statuses(rows))
        self.assertIn("1 generated file(s)", rows[0].text)
        self.assertIn("fresh.g.dart", rows[0].text)
        self.assertNotIn("old.g.dart", rows[0].text)

    def test_source_edited_after_build_runner_last_ran_still_warns(self):
        write(self.root, "lib/user.g.dart", "g")
        write(self.root, "lib/user.dart", "s")
        write(self.root, ".dart_tool/build/abc123/asset_graph.json", "{}")
        source = (self.root / "lib/user.dart").stat().st_mtime
        os.utime(self.root / "lib/user.g.dart", (source - 100, source - 100))
        os.utime(self.root / ".dart_tool/build/abc123/asset_graph.json", (source - 50, source - 50))
        self.assertEqual([(WARN, "codegen")], statuses(flutter.codegen_rows(self.root)))

    def test_generated_file_newer_than_its_source_passes(self):
        write(self.root, "lib/user.dart", "s")
        write(self.root, "lib/user.g.dart", "g")
        new = (self.root / "lib/user.dart").stat().st_mtime + 100
        os.utime(self.root / "lib/user.g.dart", (new, new))
        self.assertEqual([(PASS, "codegen")], statuses(flutter.codegen_rows(self.root)))

    def test_arb_newer_than_generated_l10n_warns(self):
        write(self.root, "l10n.yaml", "arb-dir: lib/l10n\n")
        write(self.root, "lib/l10n/app_en.arb", "{}")
        write(self.root, ".dart_tool/flutter_gen/gen_l10n/app_localizations.dart", "x")
        old = (self.root / ".dart_tool/flutter_gen/gen_l10n/app_localizations.dart").stat().st_mtime - 100
        os.utime(self.root / ".dart_tool/flutter_gen/gen_l10n/app_localizations.dart", (old, old))
        self.assertEqual([(WARN, "codegen")], statuses(flutter.codegen_rows(self.root)))

    def l10n(self, config, outputs, outputs_newer):
        """An .arb at t0 and the named output files either a week newer or a week older."""
        write(self.root, "l10n.yaml", config)
        write(self.root, "lib/l10n/intl_zh.arb", "{}")
        t0 = (self.root / "lib/l10n/intl_zh.arb").stat().st_mtime
        for rel in outputs:
            write(self.root, rel, "x")
            at = t0 + 604800 if outputs_newer else t0 - 604800
            os.utime(self.root / rel, (at, at))

    def test_outputs_next_to_the_arb_files_are_current_when_newer(self):
        self.l10n("arb-dir: lib/l10n\n", ["lib/l10n/app_localizations.dart", "lib/l10n/app_localizations_zh.dart"], True)
        self.assertEqual([(PASS, "codegen")], statuses(flutter.codegen_rows(self.root)))

    def test_outputs_next_to_the_arb_files_warn_when_older(self):
        self.l10n("arb-dir: lib/l10n\n", ["lib/l10n/app_localizations.dart"], False)
        self.assertEqual([(WARN, "codegen")], statuses(flutter.codegen_rows(self.root)))

    def test_explicit_output_dir_is_the_one_consulted(self):
        self.l10n("arb-dir: lib/l10n\noutput-dir: lib/gen\n", ["lib/gen/app_localizations.dart"], True)
        self.assertEqual([(PASS, "codegen")], statuses(flutter.codegen_rows(self.root)))

    def test_custom_output_file_name_decides_which_files_count(self):
        self.l10n("arb-dir: lib/l10n\noutput-localization-file: strings.dart\n", ["lib/l10n/strings.dart"], False)
        write(self.root, "lib/l10n/helper.dart", "hand written")
        future = (self.root / "lib/l10n/intl_zh.arb").stat().st_mtime + 604800
        os.utime(self.root / "lib/l10n/helper.dart", (future, future))
        self.assertEqual([(WARN, "codegen")], statuses(flutter.codegen_rows(self.root)))

    def test_empty_output_dir_value_does_not_swallow_the_next_key(self):
        self.l10n("output-dir:\narb-dir: lib/l10n\n", ["lib/l10n/app_localizations.dart"], True)
        self.assertEqual([(PASS, "codegen")], statuses(flutter.codegen_rows(self.root)))

    def test_hand_written_file_sharing_the_prefix_does_not_mask_a_stale_output(self):
        self.l10n("arb-dir: lib/l10n\n", ["lib/l10n/app_localizations.dart"], False)
        write(self.root, "lib/l10n/app_localizations_extra_helper.dart", "hand written")
        future = (self.root / "lib/l10n/intl_zh.arb").stat().st_mtime + 604800
        os.utime(self.root / "lib/l10n/app_localizations_extra_helper.dart", (future, future))
        self.assertEqual([(WARN, "codegen")], statuses(flutter.codegen_rows(self.root)))

    def test_region_tagged_locale_output_counts_as_generated(self):
        self.l10n("arb-dir: lib/l10n\n", ["lib/l10n/app_localizations_zh_TW.dart"], True)
        self.assertEqual([(PASS, "codegen")], statuses(flutter.codegen_rows(self.root)))

    def test_older_synthetic_package_location_is_still_read(self):
        self.l10n("arb-dir: lib/l10n\n", [".dart_tool/flutter_gen/gen_l10n/app_localizations.dart"], True)
        self.assertEqual([(PASS, "codegen")], statuses(flutter.codegen_rows(self.root)))

    def test_quoted_directory_value_is_read(self):
        self.l10n('arb-dir: "lib/l10n"\n', ["lib/l10n/app_localizations.dart"], True)
        self.assertEqual([(PASS, "codegen")], statuses(flutter.codegen_rows(self.root)))

    def test_stale_source_and_stale_l10n_are_each_reported(self):
        self.l10n("arb-dir: lib/l10n\n", ["lib/l10n/app_localizations.dart"], False)
        write(self.root, "lib/user.g.dart", "g")
        write(self.root, "lib/user.dart", "s")
        old = (self.root / "lib/user.dart").stat().st_mtime - 100
        os.utime(self.root / "lib/user.g.dart", (old, old))
        rows = flutter.codegen_rows(self.root)
        self.assertEqual([(WARN, "codegen"), (WARN, "codegen")], statuses(rows))
        self.assertIn("generated file(s) older than source", rows[0].text)
        self.assertIn("l10n output older", rows[1].text)

    def test_project_with_no_generated_files_yields_no_row(self):
        write(self.root, "lib/main.dart", "x")
        self.assertEqual([], flutter.codegen_rows(self.root))


class EntryTest(Workdir):
    def test_main_dart_present_passes(self):
        write(self.root, "lib/main.dart", "x")
        self.assertEqual([(PASS, "entry")], statuses(flutter.entry_rows(self.root)))

    def test_no_main_fails(self):
        (self.root / "lib").mkdir()
        self.assertEqual((FAIL, "entry"), statuses(flutter.entry_rows(self.root))[0])

    def test_env_file_named_in_a_build_script_but_absent_fails(self):
        write(self.root, "lib/main.dart", "x")
        write(self.root, "Makefile", "build:\n\tflutter build apk --dart-define-from-file=env/prod.json\n")
        rows = flutter.entry_rows(self.root)
        self.assertEqual([(FAIL, "entry", "Makefile:2")], [(r.status, r.dim, r.anchor) for r in rows])

    def test_env_file_path_built_from_a_shell_variable_is_not_judged(self):
        write(self.root, "lib/main.dart", "x")
        write(self.root, "Makefile", "build:\n\tflutter build apk --dart-define-from-file=env/$(FLAVOR).json\n")
        self.assertEqual([(PASS, "entry")], statuses(flutter.entry_rows(self.root)))

    def test_missing_env_file_that_is_gitignored_warns_that_ci_may_write_it(self):
        git_init(self.root)
        (self.root / "env").mkdir()
        write(self.root, ".gitignore", "env/\n")
        write(self.root, "lib/main.dart", "x")
        write(self.root, "Makefile", "build:\n\tflutter build apk --dart-define-from-file=env/prod.json\n")
        self.assertEqual([(WARN, "entry")], statuses(flutter.entry_rows(self.root)))

    def test_env_file_named_in_a_build_script_and_present_passes(self):
        write(self.root, "lib/main.dart", "x")
        write(self.root, "env/prod.json", "{}")
        write(self.root, "Makefile", "build:\n\tflutter build apk --dart-define-from-file=env/prod.json\n")
        self.assertEqual([(PASS, "entry")], statuses(flutter.entry_rows(self.root)))


class ObfuscateTest(Workdir):
    def test_flag_found_in_a_build_script_passes_with_its_anchor(self):
        write(self.root, ".gitlab-ci.yml", "build:\n  script: flutter build apk --obfuscate --split-debug-info=d\n")
        rows = flutter.obfuscate_rows(self.root)
        self.assertEqual([(PASS, "obfuscate", ".gitlab-ci.yml:2")], [(r.status, r.dim, r.anchor) for r in rows])

    def test_flag_absent_from_every_script_warns(self):
        write(self.root, "Makefile", "build:\n\tflutter build apk\n")
        self.assertEqual([(WARN, "obfuscate")], statuses(flutter.obfuscate_rows(self.root)))

    def test_no_build_scripts_at_all_warns(self):
        self.assertEqual([(WARN, "obfuscate")], statuses(flutter.obfuscate_rows(self.root)))


class DoctorTest(unittest.TestCase):
    SAMPLE = "[✓] Flutter (Channel stable, 3.35.7)\n[!] Android toolchain - develop\n[✓] Xcode - develop\n[!] Connected device (0 available)\n"

    def test_markers_are_read_by_heading_name(self):
        expected = {"Flutter": "✓", "Android toolchain": "!", "Xcode": "✓", "Connected device": "!"}
        self.assertEqual(expected, flutter.parse_doctor(self.SAMPLE))

    def test_platform_headings_are_left_to_the_platform_blocks(self):
        rows = flutter.doctor_rows(flutter.parse_doctor(self.SAMPLE))
        self.assertEqual([(WARN, "doctor")], statuses(rows))

    def test_flutter_error_fails(self):
        rows = flutter.doctor_rows({"Flutter": "✗"})
        self.assertEqual([(FAIL, "doctor")], statuses(rows))

    def test_no_report_yields_not_applicable(self):
        self.assertEqual([(NA, "doctor")], statuses(flutter.doctor_rows(None)))


class JdkFromDoctorTest(unittest.TestCase):
    def test_build_number_of_the_java_version_line_is_the_major(self):
        text = "    • Java binary at: /x/bin/java\n    • Java version OpenJDK Runtime Environment Homebrew (build 17.0.15+0)\n"
        self.assertEqual(17, flutter.jdk_from_doctor(text))

    def test_legacy_one_dot_eight_reads_as_eight(self):
        self.assertEqual(8, flutter.jdk_from_doctor("    • Java version Java(TM) SE Runtime Environment (build 1.8.0_391-b13)\n"))

    def test_report_without_a_java_line_reads_zero(self):
        self.assertEqual(0, flutter.jdk_from_doctor("[✓] Flutter (Channel stable)\n"))


class PubFailureTest(unittest.TestCase):
    def test_first_cause_line_wins_over_the_closing_summary(self):
        text = "Resolving dependencies...\nBecause acme depends on foo >=2.0.0 which doesn't exist, version solving failed.\nFailed to update packages.\n"
        self.assertTrue(flutter.pub_failure_reason(text).startswith("Because acme depends on foo"))

    def test_error_line_is_a_cause(self):
        text = "Error on line 3, column 4 of pubspec.lock: bad\nConsider deleting the file.\nFailed to update packages.\n"
        self.assertTrue(flutter.pub_failure_reason(text).startswith("Error on line 3"))

    def test_output_with_no_known_cause_falls_back_to_its_last_line(self):
        self.assertEqual("Failed to update packages.", flutter.pub_failure_reason("noise\nFailed to update packages.\n"))


class SdkTest(Workdir):
    def project(self):
        write(self.root, "pubspec.yaml", FLUTTER_PUBSPEC)

    def run_with(self, bin_dir):
        with mock.patch.dict(os.environ, {"PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"}):
            return flutter.sdk_rows(self.root, commands=True)

    def test_dart_inside_the_constraint_passes(self):
        self.project()
        rows = self.run_with(stub_flutter(self.root, dart="3.9.2"))
        self.assertEqual([(PASS, "sdk")], statuses(rows))

    def test_dart_outside_the_constraint_fails_at_its_line(self):
        self.project()
        rows = self.run_with(stub_flutter(self.root, dart="3.7.0"))
        self.assertEqual([(FAIL, "sdk", "pubspec.yaml:4")], [(r.status, r.dim, r.anchor) for r in rows])

    def test_fvm_pin_that_differs_from_the_flutter_in_use_warns(self):
        self.project()
        write(self.root, ".fvmrc", '{"flutter": "3.29.0"}')
        rows = self.run_with(stub_flutter(self.root, flutter_version="3.35.7"))
        self.assertEqual([(WARN, "sdk")], statuses(rows))

    def test_commands_off_reports_not_applicable(self):
        self.project()
        self.assertEqual([(NA, "sdk")], statuses(flutter.sdk_rows(self.root, commands=False)))

    def test_missing_flutter_fails(self):
        self.project()
        with mock.patch.dict(os.environ, {"PATH": str(self.root)}):
            rows = flutter.sdk_rows(self.root, commands=True)
        self.assertEqual([(FAIL, "sdk")], statuses(rows))


if __name__ == "__main__":
    unittest.main()
