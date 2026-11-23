"""Tests for the IOS block of /earendil (earendil_ios.py)."""

import json
import os
import plistlib
import sys
import unittest
from datetime import datetime, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import earendil_ios as ios  # noqa: E402
from earendil_common import FAIL, NA, PASS, WARN  # noqa: E402
from test_earendil import FLUTTER_PUBSPEC, Workdir, write  # noqa: E402

TEAM = "4ABC12DEFG"
NOW = datetime(2026, 11, 23, 12, 0, 0)


def pbxproj(bundle="com.acme.app", team=TEAM, style="Automatic", identity="", profile="", app_extra="", project_extra=""):
    def body(lines):
        return "".join(f"\t\t\t\t{line};\n" for line in lines)

    app = [f"CODE_SIGN_STYLE = {style}", f"PRODUCT_BUNDLE_IDENTIFIER = {bundle}", "INFOPLIST_FILE = Runner/Info.plist"]
    app += [f"DEVELOPMENT_TEAM = {team}"] if team else []
    app += [f'CODE_SIGN_IDENTITY = "{identity}"'] if identity else []
    app += [f'PROVISIONING_PROFILE_SPECIFIER = "{profile}"'] if profile else []
    config = lambda ident, name, lines: (
        f"\t\t{ident} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{body(lines)}\t\t\t}};\n\t\t\tname = {name};\n\t\t}};\n"
    )
    return (
        "// !$*UTF8*$!\n{\n\tobjects = {\n"
        + config("A1", "Release", app + ([app_extra] if app_extra else []))
        + config("A2", "Debug", ["PRODUCT_BUNDLE_IDENTIFIER = com.acme.app.debugonly", "CODE_SIGN_STYLE = Manual"])
        + config("B1", "Release", ["PRODUCT_BUNDLE_IDENTIFIER = com.acme.app.RunnerTests"])
        + config("C1", "Release", ["IPHONEOS_DEPLOYMENT_TARGET = 13.0"] + ([project_extra] if project_extra else []))
        + "\t};\n}\n"
    )


def info_plist(short="$(FLUTTER_BUILD_NAME)", build="$(FLUTTER_BUILD_NUMBER)", **extra):
    return plistlib.dumps({"CFBundleShortVersionString": short, "CFBundleVersion": build, **extra}).decode()


def statuses(findings):
    return [(f.status, f.dim) for f in findings]


class IosDir(Workdir):
    def setUp(self):
        super().setUp()
        self.ios = self.root / "ios"
        write(self.ios, "Runner.xcodeproj/project.pbxproj", pbxproj())
        write(self.ios, "Runner/Info.plist", info_plist())

    def settings(self, **kw):
        write(self.ios, "Runner.xcodeproj/project.pbxproj", pbxproj(**kw))
        return ios.release_settings(ios.read_configs(ios.project_file(self.ios)))


class ProjectFileTest(IosDir):
    def test_xcodeproj_is_found_under_the_ios_root(self):
        self.assertEqual(self.ios / "Runner.xcodeproj" / "project.pbxproj", ios.project_file(self.ios))

    def test_missing_project_yields_none(self):
        self.assertIsNone(ios.project_file(self.root))


class SettingsTest(IosDir):
    def test_release_settings_come_from_the_app_target_not_debug_or_tests(self):
        settings = self.settings()
        self.assertEqual(("com.acme.app", "13.0"), (settings["PRODUCT_BUNDLE_IDENTIFIER"], settings["IPHONEOS_DEPLOYMENT_TARGET"]))

    def test_sdk_qualified_keys_are_read_by_their_base_name(self):
        write(self.ios, "Runner.xcodeproj/project.pbxproj", pbxproj(app_extra='"CODE_SIGN_IDENTITY[sdk=iphoneos*]" = "Apple Distribution"'))
        settings = ios.release_settings(ios.read_configs(ios.project_file(self.ios)))
        self.assertEqual("Apple Distribution", settings["CODE_SIGN_IDENTITY"])

    def test_tests_target_listed_before_the_app_target_is_skipped(self):
        text = pbxproj()
        tests_block = text[text.index("\t\tB1 /* Release */"):text.index("\t\tC1 /* Release */")]
        reordered = text.replace(tests_block, "").replace("\t\tA1 /* Release */", tests_block + "\t\tA1 /* Release */", 1)
        write(self.ios, "Runner.xcodeproj/project.pbxproj", reordered)
        settings = ios.release_settings(ios.read_configs(ios.project_file(self.ios)))
        self.assertEqual("com.acme.app", settings["PRODUCT_BUNDLE_IDENTIFIER"])

    def test_extension_target_listed_first_does_not_displace_the_app(self):
        text = pbxproj()
        extension = "\t\tE1 /* Release */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.acme.app.ShareExtension;\n\t\t\t};\n\t\t\tname = Release;\n\t\t};\n"
        write(self.ios, "Runner.xcodeproj/project.pbxproj", text.replace("\t\tA1 /* Release */", extension + "\t\tA1 /* Release */", 1))
        settings = ios.release_settings(ios.read_configs(ios.project_file(self.ios)))
        self.assertEqual("com.acme.app", settings["PRODUCT_BUNDLE_IDENTIFIER"])

    def test_malformed_plist_reads_as_empty_instead_of_raising(self):
        write(self.ios, "Broken.plist", "<plist><dict>")
        self.assertEqual({}, ios.load_plist(self.ios / "Broken.plist"))

    def test_resolve_follows_one_reference(self):
        self.assertEqual("2.4.0", ios.resolve("$(MARKETING_VERSION)", {"MARKETING_VERSION": "2.4.0"}))

    def test_resolve_leaves_an_unknown_reference_alone(self):
        self.assertEqual("$(FLUTTER_BUILD_NAME)", ios.resolve("$(FLUTTER_BUILD_NAME)", {}))


class IdentityTest(IosDir):
    def test_bundle_id_and_deployment_target_pass(self):
        self.assertEqual([(PASS, "identity")], statuses(ios.identity_rows(self.settings(), self.root, self.ios)))

    def test_missing_bundle_id_warns_that_an_xcconfig_may_set_it(self):
        self.assertEqual([(WARN, "identity")], statuses(ios.identity_rows({}, self.root, self.ios)))


class VersionTest(IosDir):
    def test_flutter_build_references_follow_pubspec(self):
        rows = ios.version_rows(self.settings(), self.ios, ("2.4.0", "57"), self.root)
        self.assertEqual([(PASS, "version")], statuses(rows))

    def test_literal_that_differs_from_pubspec_fails(self):
        write(self.ios, "Runner/Info.plist", info_plist(short="1.0.0", build="3"))
        rows = ios.version_rows(self.settings(), self.ios, ("2.4.0", "57"), self.root)
        self.assertEqual([(FAIL, "version")], statuses(rows))

    def test_native_marketing_version_in_the_project_passes(self):
        write(self.ios, "Runner/Info.plist", info_plist(short="$(MARKETING_VERSION)", build="$(CURRENT_PROJECT_VERSION)"))
        settings = {**self.settings(), "MARKETING_VERSION": "3.1", "CURRENT_PROJECT_VERSION": "9"}
        self.assertEqual([(PASS, "version")], statuses(ios.version_rows(settings, self.ios, None, self.root)))

    def test_native_unresolved_reference_warns_that_an_xcconfig_may_supply_it(self):
        self.assertEqual([(WARN, "version")], statuses(ios.version_rows(self.settings(), self.ios, None, self.root)))

    def test_missing_info_plist_warns(self):
        (self.ios / "Runner" / "Info.plist").unlink()
        self.assertEqual([(WARN, "version")], statuses(ios.version_rows(self.settings(), self.ios, ("2.4.0", "57"), self.root)))


class SigningTest(IosDir):
    def test_automatic_signing_with_a_team_passes(self):
        self.assertEqual([(PASS, "signing")], statuses(ios.signing_rows(self.settings(), self.root, self.ios)))

    def test_missing_team_warns_that_an_xcconfig_may_set_it(self):
        self.assertEqual([(WARN, "signing")], statuses(ios.signing_rows(self.settings(team=""), self.root, self.ios)))

    def test_manual_signing_with_a_development_identity_fails(self):
        settings = self.settings(style="Manual", identity="iPhone Developer", profile="Acme AppStore")
        self.assertEqual([(FAIL, "signing")], statuses(ios.signing_rows(settings, self.root, self.ios)))

    def test_manual_signing_without_a_profile_warns(self):
        settings = self.settings(style="Manual", identity="Apple Distribution")
        self.assertEqual([(WARN, "signing")], statuses(ios.signing_rows(settings, self.root, self.ios)))

    def test_manual_signing_with_distribution_identity_and_profile_passes(self):
        settings = self.settings(style="Manual", identity="Apple Distribution", profile="Acme AppStore")
        self.assertEqual([(PASS, "signing")], statuses(ios.signing_rows(settings, self.root, self.ios)))


class KeychainTest(IosDir):
    LISTING = f'  1) AB12 "Apple Distribution: Acme Ltd ({TEAM})"\n  2) CD34 "Apple Development: Larry (ZZZZZZZZZZ)"\n     2 valid identities found\n'

    def test_distribution_teams_are_read_from_the_listing(self):
        self.assertEqual({TEAM}, ios.distribution_teams(self.LISTING))

    def test_identity_for_the_team_passes(self):
        self.assertEqual([(PASS, "keychain")], statuses(ios.keychain_rows(self.settings(), self.LISTING)))

    def test_no_identity_for_the_team_warns_under_automatic_signing(self):
        self.assertEqual([(WARN, "keychain")], statuses(ios.keychain_rows(self.settings(), "0 valid identities found")))

    def test_no_identity_for_the_team_fails_under_manual_signing(self):
        settings = self.settings(style="Manual", identity="Apple Distribution", profile="P")
        self.assertEqual([(FAIL, "keychain")], statuses(ios.keychain_rows(settings, "0 valid identities found")))

    def test_no_listing_is_not_applicable(self):
        self.assertEqual([(NA, "keychain")], statuses(ios.keychain_rows(self.settings(), None)))


class ProfileTest(IosDir):
    def manual(self):
        return self.settings(style="Manual", identity="Apple Distribution", profile="Acme AppStore")

    def profile(self, days):
        return {"Name": "Acme AppStore", "UUID": "u-1", "ExpirationDate": NOW + timedelta(days=days)}

    def test_automatic_signing_yields_no_row(self):
        self.assertEqual([], ios.profile_rows(self.settings(), [], NOW))

    def test_installed_profile_with_time_left_passes(self):
        self.assertEqual([(PASS, "profile")], statuses(ios.profile_rows(self.manual(), [self.profile(200)], NOW)))

    def test_profile_expiring_within_thirty_days_warns(self):
        self.assertEqual([(WARN, "profile")], statuses(ios.profile_rows(self.manual(), [self.profile(16)], NOW)))

    def test_expired_profile_fails(self):
        self.assertEqual([(FAIL, "profile")], statuses(ios.profile_rows(self.manual(), [self.profile(-1)], NOW)))

    def test_newest_of_several_same_name_profiles_is_the_one_judged(self):
        profiles = [self.profile(-30), self.profile(200)]
        self.assertEqual([(PASS, "profile")], statuses(ios.profile_rows(self.manual(), profiles, NOW)))

    def test_profile_that_is_not_installed_fails(self):
        self.assertEqual([(FAIL, "profile")], statuses(ios.profile_rows(self.manual(), [], NOW)))

    def test_no_profile_listing_is_not_applicable(self):
        self.assertEqual([(NA, "profile")], statuses(ios.profile_rows(self.manual(), None, NOW)))


class ExportTest(IosDir):
    def options(self, **kw):
        write(self.ios, "ExportOptions.plist", plistlib.dumps({"method": "app-store", "teamID": TEAM, **kw}).decode())

    def test_matching_team_and_known_method_passes(self):
        self.options()
        self.assertEqual([(PASS, "export")], statuses(ios.export_rows(self.ios, self.settings(), self.root)))

    def test_malformed_options_plist_warns_instead_of_raising(self):
        write(self.ios, "ExportOptions.plist", "<plist><dict>")
        self.assertEqual([(WARN, "export")], statuses(ios.export_rows(self.ios, self.settings(), self.root)))

    def test_team_that_differs_warns(self):
        self.options(teamID="OTHERTEAM1")
        self.assertEqual([(WARN, "export")], statuses(ios.export_rows(self.ios, self.settings(), self.root)))

    def test_absent_options_plist_is_not_applicable(self):
        self.assertEqual([(NA, "export")], statuses(ios.export_rows(self.ios, self.settings(), self.root)))


class ServicesTest(IosDir):
    def rows(self):
        return ios.services_rows(self.ios, self.settings(), self.root)

    def test_project_without_firebase_yields_no_row(self):
        self.assertEqual([], self.rows())

    def test_firebase_without_the_plist_fails(self):
        write(self.ios, "Podfile.lock", "PODS:\n  - Firebase/Core (10.0.0)\n")
        self.assertEqual([(FAIL, "services")], statuses(self.rows()))

    def test_plist_with_a_matching_bundle_id_passes(self):
        write(self.ios, "Podfile.lock", "PODS:\n  - Firebase/Core (10.0.0)\n")
        write(self.ios, "Runner/GoogleService-Info.plist", plistlib.dumps({"BUNDLE_ID": "com.acme.app"}).decode())
        self.assertEqual([(PASS, "services")], statuses(self.rows()))

    def test_plist_with_another_bundle_id_fails(self):
        write(self.ios, "Podfile.lock", "PODS:\n  - Firebase/Core (10.0.0)\n")
        write(self.ios, "Runner/GoogleService-Info.plist", plistlib.dumps({"BUNDLE_ID": "com.acme.app.dev"}).decode())
        self.assertEqual([(FAIL, "services")], statuses(self.rows()))


class ToolchainTest(unittest.TestCase):
    def test_xcode_and_pods_present_pass(self):
        rows = ios.toolchain_rows(True, "Xcode 16.2\nBuild version 16C5032a", "1.16.2")
        self.assertEqual([(PASS, "toolchain")], statuses(rows))

    def test_missing_xcode_fails(self):
        self.assertEqual([(FAIL, "toolchain")], statuses(ios.toolchain_rows(False, None, None)))

    def test_missing_cocoapods_fails_when_a_podfile_exists(self):
        self.assertEqual([(FAIL, "toolchain")], statuses(ios.toolchain_rows(True, "Xcode 16.2", None)))

    def test_not_run_is_not_applicable(self):
        self.assertEqual([(NA, "toolchain")], statuses(ios.toolchain_rows(False, "", None, ran=False)))


class PodsTest(IosDir):
    def test_project_without_a_podfile_yields_no_row(self):
        self.assertEqual([], ios.pods_rows(self.ios))

    def test_podfile_without_a_lock_warns(self):
        write(self.ios, "Podfile", "platform :ios\n")
        self.assertEqual([(WARN, "pods")], statuses(ios.pods_rows(self.ios)))

    def test_lock_older_than_the_podfile_warns(self):
        write(self.ios, "Podfile", "platform :ios\n")
        write(self.ios, "Podfile.lock", "PODS: []\n")
        (self.ios / "Pods").mkdir()
        past = (self.ios / "Podfile").stat().st_mtime - 100
        os.utime(self.ios / "Podfile.lock", (past, past))
        self.assertEqual([(WARN, "pods")], statuses(ios.pods_rows(self.ios)))

    def test_current_lock_and_pods_directory_pass(self):
        write(self.ios, "Podfile", "platform :ios\n")
        write(self.ios, "Podfile.lock", "PODS: []\n")
        (self.ios / "Pods").mkdir()
        future = (self.ios / "Podfile").stat().st_mtime + 100
        os.utime(self.ios / "Podfile.lock", (future, future))
        self.assertEqual([(PASS, "pods")], statuses(ios.pods_rows(self.ios)))


class UsageTest(IosDir):
    def lock(self, *names):
        write(self.root, "pubspec.lock", "packages:\n" + "".join(f"  {n}:\n    dependency: direct main\n" for n in names))

    def test_plugin_needing_a_usage_string_that_is_absent_fails(self):
        self.lock("image_picker")
        rows = ios.usage_rows(self.ios, self.root)
        self.assertEqual([(WARN, "plist")], statuses(rows))
        self.assertIn("NSCameraUsageDescription", rows[0].text)

    def test_blank_usage_string_counts_as_absent(self):
        self.lock("record")
        write(self.ios, "Runner/Info.plist", info_plist(NSMicrophoneUsageDescription=""))
        self.assertEqual([(WARN, "plist")], statuses(ios.usage_rows(self.ios, self.root)))

    def test_all_needed_strings_present_passes(self):
        self.lock("record")
        write(self.ios, "Runner/Info.plist", info_plist(NSMicrophoneUsageDescription="Records voice notes"))
        self.assertEqual([(PASS, "plist")], statuses(ios.usage_rows(self.ios, self.root)))

    def test_no_relevant_plugin_yields_no_row(self):
        self.lock("provider")
        self.assertEqual([], ios.usage_rows(self.ios, self.root))


class StripTest(IosDir):
    def test_defaults_pass(self):
        self.assertEqual([(PASS, "strip")], statuses(ios.strip_rows(self.settings())))

    def test_stripping_turned_off_warns(self):
        self.assertEqual([(WARN, "strip")], statuses(ios.strip_rows(self.settings(app_extra="STRIP_INSTALLED_PRODUCT = NO"))))

    def test_plain_dwarf_without_a_dsym_warns(self):
        self.assertEqual([(WARN, "strip")], statuses(ios.strip_rows(self.settings(app_extra="DEBUG_INFORMATION_FORMAT = dwarf"))))


class DoctorTest(unittest.TestCase):
    def test_xcode_marker_maps_to_a_status(self):
        expected = [PASS, WARN, FAIL]
        self.assertEqual(expected, [ios.doctor_rows({"Xcode": m})[0].status for m in ("✓", "!", "✗")])

    def test_absent_report_is_not_applicable(self):
        self.assertEqual([(NA, "doctor")], statuses(ios.doctor_rows(None)))


class CheckTest(IosDir):
    def test_flutter_project_runs_every_group_without_raising(self):
        write(self.root, "pubspec.yaml", FLUTTER_PUBSPEC)
        from earendil import detect
        rows = ios.check(detect(self.root), commands=False, doctor=None, now=NOW)
        dims = {r.dim for r in rows}
        self.assertTrue({"identity", "version", "signing", "keychain", "export", "toolchain", "strip", "doctor"} <= dims)

    def test_project_with_no_xcodeproj_fails_once(self):
        write(self.root, "pubspec.yaml", FLUTTER_PUBSPEC)
        (self.ios / "Runner.xcodeproj" / "project.pbxproj").unlink()
        from earendil import detect
        rows = ios.check(detect(self.root), commands=False, doctor=None, now=NOW)
        self.assertEqual((FAIL, "project"), statuses(rows)[0])


if __name__ == "__main__":
    unittest.main()
