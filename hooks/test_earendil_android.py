"""Tests for the ANDROID block of /earendil (earendil_android.py)."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import earendil_android as android  # noqa: E402
from earendil_common import FAIL, NA, PASS, WARN  # noqa: E402
from test_earendil import FLUTTER_PUBSPEC, Workdir, write  # noqa: E402

KEY_PROPS = "storeFile=acme.jks\nstorePassword=secret1\nkeyAlias=acme\nkeyPassword=secret2\n"
LOADS_KEY_PROPS = 'val keystoreProperties = Properties()\nkeystoreProperties.load(FileInputStream(rootProject.file("key.properties")))\n'
RELEASE_SIGNING = 'signingConfigs {\n  create("release") {\n    keyAlias = keystoreProperties["keyAlias"] as String\n    keyPassword = keystoreProperties["keyPassword"] as String\n    storePassword = keystoreProperties["storePassword"] as String\n    storeFile = keystoreProperties["storeFile"]?.let { file(it) }\n  }\n}\n'


def gradle(app_id="com.acme.app", min_sdk="24", compile_sdk="35", version_code="flutter.versionCode",
           version_name="flutter.versionName", sign='signingConfigs.getByName("release")',
           minify="isMinifyEnabled = true", head=LOADS_KEY_PROPS, signing=RELEASE_SIGNING, extra=""):
    ids = f'applicationId = "{app_id}"\n' if app_id else ""
    comp = f"compileSdk = {compile_sdk}\n" if compile_sdk else ""
    sign_line = f"signingConfig = {sign}\n" if sign else ""
    return (
        f'{head}plugins {{ id("com.android.application") }}\n'
        f'android {{\n namespace = "com.acme.app"\n {comp}\n'
        f' defaultConfig {{\n  {ids}  minSdk = {min_sdk}\n  targetSdk = 35\n'
        f"  versionCode = {version_code}\n  versionName = {version_name}\n }}\n"
        f" {signing}\n buildTypes {{\n  release {{\n   {sign_line}   {minify}\n"
        f'   proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")\n  }}\n }}\n{extra}}}\n'
    )


def statuses(findings):
    return [(f.status, f.dim) for f in findings]


def git_init(root):
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
    subprocess.run(["git", "-C", str(root), "init", "-q"], check=True, env=env, capture_output=True)


class AndroidDir(Workdir):
    def setUp(self):
        super().setUp()
        self.android = self.root / "android"
        write(self.android, "app/build.gradle.kts", gradle())
        write(self.android, "app/proguard-rules.pro", "# rules\n")
        self.module = self.android / "app"

    def text(self):
        return (self.module / "build.gradle.kts").read_text(encoding="utf-8")

    def put(self, **kwargs):
        write(self.android, "app/build.gradle.kts", gradle(**kwargs))


class ModuleTest(AndroidDir):
    def test_app_directory_is_the_application_module(self):
        self.assertEqual(self.module, android.app_module(self.android))

    def test_module_is_found_by_its_plugin_when_not_named_app(self):
        (self.module / "build.gradle.kts").rename(self.android / "build.gradle.kts")
        os.rename(self.module, self.android / "mobile")
        (self.android / "build.gradle.kts").rename(self.android / "mobile" / "build.gradle.kts")
        self.assertEqual(self.android / "mobile", android.app_module(self.android))

    def test_version_catalog_plugin_alias_marks_the_application_module(self):
        for alias in ("alias(libs.plugins.android.application)", "alias(libs.plugins.androidApplication)"):
            (self.module / "build.gradle.kts").write_text(f"plugins {{ {alias} }}\n")
            self.assertEqual(self.module, android.app_module(self.android), alias)

    def test_no_application_module_yields_none(self):
        (self.module / "build.gradle.kts").write_text("// library only\n")
        self.assertIsNone(android.app_module(self.android))


class IdentityTest(AndroidDir):
    def test_application_id_and_namespace_pass(self):
        self.assertEqual([(PASS, "identity")], statuses(android.identity_rows(self.text(), self.module, self.root)))

    def test_application_id_left_to_default_to_the_namespace_passes(self):
        self.put(app_id="")
        self.assertEqual([(PASS, "identity")], statuses(android.identity_rows(self.text(), self.module, self.root)))

    def test_computed_application_id_is_not_applicable(self):
        text = self.text().replace('applicationId = "com.acme.app"', "applicationId = computeId()")
        self.assertEqual([(NA, "identity")], statuses(android.identity_rows(text, self.module, self.root)))

    def test_neither_application_id_nor_namespace_warns(self):
        text = self.text().replace('applicationId = "com.acme.app"', "").replace('namespace = "com.acme.app"', "")
        self.assertEqual([(WARN, "identity")], statuses(android.identity_rows(text, self.module, self.root)))


class SdkTest(AndroidDir):
    def test_numeric_levels_pass(self):
        self.assertEqual([(PASS, "sdk")], statuses(android.sdk_rows(self.text())))

    def test_flutter_managed_min_sdk_passes(self):
        self.put(min_sdk="flutter.minSdkVersion")
        self.assertEqual([(PASS, "sdk")], statuses(android.sdk_rows(self.text())))

    def test_missing_compile_sdk_warns(self):
        self.put(compile_sdk="")
        self.assertEqual([(WARN, "sdk")], statuses(android.sdk_rows(self.text())))


class VersionTest(AndroidDir):
    def test_flutter_references_follow_pubspec(self):
        rows = android.version_rows(self.text(), ("2.4.0", "57"), self.module, self.root)
        self.assertEqual([(PASS, "version")], statuses(rows))

    def test_literal_that_differs_from_pubspec_fails(self):
        self.put(version_code="12", version_name='"1.0.0"')
        rows = android.version_rows(self.text(), ("2.4.0", "57"), self.module, self.root)
        self.assertEqual([(FAIL, "version")], statuses(rows))

    def test_literal_that_matches_pubspec_passes(self):
        self.put(version_code="57", version_name='"2.4.0"')
        rows = android.version_rows(self.text(), ("2.4.0", "57"), self.module, self.root)
        self.assertEqual([(PASS, "version")], statuses(rows))

    def test_native_project_missing_a_value_warns_that_a_plugin_may_set_it(self):
        text = self.text().replace("versionCode = flutter.versionCode\n", "")
        rows = android.version_rows(text, None, self.module, self.root)
        self.assertEqual([(WARN, "version")], statuses(rows))

    def test_trailing_comment_after_a_literal_does_not_cause_a_mismatch(self):
        text = self.text().replace("versionName = flutter.versionName", 'versionName = "2.4.0" // release').replace("versionCode = flutter.versionCode", "versionCode = 57 // n")
        rows = android.version_rows(text, ("2.4.0", "57"), self.module, self.root)
        self.assertEqual([(PASS, "version")], statuses(rows))


class ReleaseTest(AndroidDir):
    def test_release_signed_with_the_release_config_passes(self):
        self.assertEqual([(PASS, "release")], statuses(android.release_rows(self.text(), self.module, self.root)))

    def test_release_signed_with_debug_fails_at_its_line(self):
        self.put(sign='signingConfigs.getByName("debug")')
        rows = android.release_rows(self.text(), self.module, self.root)
        self.assertEqual((FAIL, "release"), statuses(rows)[0])
        self.assertRegex(rows[0].anchor, r"build\.gradle\.kts:\d+")

    def test_release_with_no_signing_config_warns_that_it_may_be_set_elsewhere(self):
        self.put(sign="")
        self.assertEqual([(WARN, "release")], statuses(android.release_rows(self.text(), self.module, self.root)))

    def test_conditional_that_can_fall_back_to_debug_warns(self):
        self.put(sign='if (true) signingConfigs.getByName("release") else signingConfigs.getByName("debug")')
        self.assertEqual([(WARN, "release")], statuses(android.release_rows(self.text(), self.module, self.root)))

    def test_release_config_defined_in_no_visible_block_warns(self):
        self.put(signing="")
        self.assertEqual([(WARN, "release")], statuses(android.release_rows(self.text(), self.module, self.root)))

    def test_release_config_missing_from_an_existing_block_fails(self):
        self.put(signing='signingConfigs { create("other") { } }\n')
        self.assertEqual([(FAIL, "release")], statuses(android.release_rows(self.text(), self.module, self.root)))


class KeyTest(AndroidDir):
    def rows(self):
        return android.key_rows(self.text(), self.android, self.module, self.root)

    def test_complete_key_properties_with_existing_keystore_passes(self):
        write(self.android, "key.properties", KEY_PROPS)
        write(self.android, "acme.jks", "store")
        self.assertEqual([(PASS, "key")], statuses(self.rows()))

    def test_property_names_are_taken_from_the_gradle_that_reads_them(self):
        self.put(signing='signingConfigs {\n create("release") {\n  keyAlias = props["RELEASE_KEY_ALIAS"]\n  keyPassword = props["RELEASE_KEY_PASSWORD"]\n  storePassword = props["RELEASE_STORE_PASSWORD"]\n  storeFile = file(props["RELEASE_STORE_FILE"])\n }\n}\n')
        write(self.android, "key.properties", "RELEASE_KEY_ALIAS=a\nRELEASE_KEY_PASSWORD=b\nRELEASE_STORE_PASSWORD=c\nRELEASE_STORE_FILE=acme.jks\n")
        write(self.android, "acme.jks", "store")
        self.assertEqual([(PASS, "key")], statuses(self.rows()))

    def test_absent_key_properties_warns_that_ci_may_write_it(self):
        self.assertEqual([(WARN, "key")], statuses(self.rows()))

    def test_empty_password_fails_without_printing_it(self):
        write(self.android, "key.properties", KEY_PROPS.replace("secret1", ""))
        write(self.android, "acme.jks", "store")
        rows = self.rows()
        self.assertEqual([(FAIL, "key")], statuses(rows))
        self.assertIn("storePassword", rows[0].text)
        self.assertNotIn("secret2", rows[0].text)

    def test_keystore_file_that_is_absent_fails_and_names_key_properties(self):
        write(self.android, "key.properties", KEY_PROPS)
        rows = self.rows()
        self.assertEqual([(FAIL, "key", "android/key.properties")], [(r.status, r.dim, r.anchor) for r in rows])

    def test_signing_from_environment_variables_is_not_applicable(self):
        self.put(head="", signing='signingConfigs { create("release") { storePassword = System.getenv("STORE_PW") } }\n')
        self.assertEqual([(NA, "key")], statuses(self.rows()))


class SecretsTest(AndroidDir):
    def test_ignored_key_material_passes(self):
        git_init(self.root)
        write(self.root, ".gitignore", "key.properties\n*.jks\n")
        write(self.android, "key.properties", KEY_PROPS)
        self.assertEqual([(PASS, "secrets")], statuses(android.secrets_rows(self.android, self.root)))

    def test_key_properties_not_ignored_warns(self):
        git_init(self.root)
        write(self.android, "key.properties", KEY_PROPS)
        self.assertEqual([(WARN, "secrets")], statuses(android.secrets_rows(self.android, self.root)))

    def test_tracked_key_properties_fails(self):
        git_init(self.root)
        write(self.android, "key.properties", KEY_PROPS)
        subprocess.run(["git", "-C", str(self.root), "add", "-f", "android/key.properties"], check=True, capture_output=True)
        self.assertEqual((FAIL, "secrets"), statuses(android.secrets_rows(self.android, self.root))[0])

    def test_tracked_keystore_fails(self):
        git_init(self.root)
        write(self.android, "app/release.jks", "store")
        subprocess.run(["git", "-C", str(self.root), "add", "-f", "android/app/release.jks"], check=True, capture_output=True)
        self.assertEqual((FAIL, "secrets"), statuses(android.secrets_rows(self.android, self.root))[0])

    def test_tracked_debug_keystore_is_not_a_secret(self):
        git_init(self.root)
        write(self.android, "app/debug.keystore", "store")
        subprocess.run(["git", "-C", str(self.root), "add", "-f", "android/app/debug.keystore"], check=True, capture_output=True)
        self.assertNotIn(FAIL, [r.status for r in android.secrets_rows(self.android, self.root)])

    def test_android_directory_outside_the_root_does_not_raise(self):
        git_init(self.root)
        with tempfile.TemporaryDirectory() as elsewhere:
            self.assertEqual([], android.secrets_rows(Path(elsewhere), self.root))

    def test_git_repo_holding_no_key_material_yields_no_row(self):
        git_init(self.root)
        self.assertEqual([], android.secrets_rows(self.android, self.root))

    def test_outside_a_git_work_tree_yields_no_row(self):
        write(self.android, "key.properties", KEY_PROPS)
        self.assertEqual([], android.secrets_rows(self.android, self.root))


class MinifyTest(AndroidDir):
    def rows(self):
        return android.minify_rows(self.text(), self.module, self.root)

    def test_minify_enabled_with_rules_present_passes(self):
        self.assertEqual([(PASS, "minify")], statuses(self.rows()))

    def test_minify_enabled_with_only_default_rules_does_not_claim_a_rules_file(self):
        text = self.text().replace(', "proguard-rules.pro"', "")
        rows = android.minify_rows(text, self.module, self.root)
        self.assertEqual("R8 on", rows[0].text)

    def test_minify_disabled_warns(self):
        self.put(minify="isMinifyEnabled = false")
        self.assertEqual([(WARN, "minify")], statuses(self.rows()))

    def test_minify_unset_warns_that_the_default_was_not_verified(self):
        self.put(minify="")
        rows = self.rows()
        self.assertEqual([(WARN, "minify")], statuses(rows))
        self.assertIn("not set", rows[0].text)

    def test_referenced_rules_file_that_is_absent_warns(self):
        (self.module / "proguard-rules.pro").unlink()
        self.assertEqual((WARN, "minify"), statuses(self.rows())[0])


class SymbolsTest(AndroidDir):
    def test_native_code_without_debug_symbols_warns(self):
        self.put(extra='externalNativeBuild { cmake { path = file("CMakeLists.txt") } }\n')
        self.assertEqual([(WARN, "symbols")], statuses(android.symbols_rows(self.text())))

    def test_native_code_with_debug_symbols_passes(self):
        self.put(extra='externalNativeBuild { }\nndk { debugSymbolLevel = "FULL" }\n')
        self.assertEqual([(PASS, "symbols")], statuses(android.symbols_rows(self.text())))

    def test_project_without_native_code_yields_no_row(self):
        self.assertEqual([], android.symbols_rows(self.text()))


class ServicesTest(AndroidDir):
    GMS = '    id("com.google.gms.google-services")\n'

    def rows(self):
        return android.services_rows(self.text(), self.module, self.root)

    def test_no_google_services_plugin_yields_no_row(self):
        self.assertEqual([], self.rows())

    def test_plugin_applied_but_file_absent_fails(self):
        self.put(head=self.GMS)
        self.assertEqual([(FAIL, "services")], statuses(self.rows()))

    def test_matching_package_name_passes(self):
        self.put(head=self.GMS)
        write(self.module, "google-services.json", json.dumps({"client": [{"client_info": {"android_client_info": {"package_name": "com.acme.app"}}}]}, indent=2))
        self.assertEqual([(PASS, "services")], statuses(self.rows()))

    def test_package_name_that_differs_fails_at_its_line(self):
        self.put(head=self.GMS)
        write(self.module, "google-services.json", json.dumps({"client": [{"client_info": {"android_client_info": {"package_name": "com.acme.app.dev"}}}]}, indent=2))
        rows = self.rows()
        self.assertEqual([(FAIL, "services")], statuses(rows))
        self.assertRegex(rows[0].anchor, r"google-services\.json:\d+")


class ToolchainTest(AndroidDir):
    def project(self, agp="8.7.3", gradle_version="8.10.2"):
        write(self.android, "settings.gradle.kts", f'plugins {{ id("com.android.application") version "{agp}" apply false\n id("org.jetbrains.kotlin.android") version "2.0.21" apply false }}\n')
        write(self.android, "gradle/wrapper/gradle-wrapper.properties", f"distributionUrl=https\\://services.gradle.org/distributions/gradle-{gradle_version}-all.zip\n")

    def rows(self, **kw):
        return android.toolchain_rows(self.android, self.root, **{"jdk": 0, **kw})

    def test_agp_with_a_new_enough_gradle_passes(self):
        self.project()
        self.assertEqual([(PASS, "toolchain")], statuses(self.rows()))

    def test_gradle_below_the_agp_minimum_fails_at_the_wrapper_line(self):
        self.project(gradle_version="8.5")
        rows = self.rows()
        self.assertEqual([(FAIL, "toolchain")], statuses(rows))
        self.assertRegex(rows[0].anchor, r"gradle-wrapper\.properties:1")

    def test_agp_missing_from_the_table_is_not_applicable(self):
        self.project(agp="99.0.0")
        self.assertEqual([(NA, "toolchain")], statuses(self.rows()))

    def test_jdk_below_the_agp_minimum_fails(self):
        self.project()
        self.assertEqual([(FAIL, "toolchain")], statuses(self.rows(jdk=11)))

    def test_jdk_that_meets_the_minimum_is_named_in_the_row(self):
        self.project()
        rows = self.rows(jdk=17)
        self.assertEqual([(PASS, "toolchain")], statuses(rows))
        self.assertIn("JDK 17", rows[0].text)

    def test_jdk_from_path_in_a_native_project_only_warns(self):
        self.project()
        self.assertEqual([(WARN, "toolchain")], statuses(self.rows(jdk=11, authoritative=False)))

    def test_agp_version_is_read_from_a_version_catalog(self):
        write(self.android, "settings.gradle.kts", "// plugins come from the catalog\n")
        write(self.android, "gradle/libs.versions.toml", '[versions]\nagp = "8.7.3"\n')
        write(self.android, "gradle/wrapper/gradle-wrapper.properties", "distributionUrl=https\\://services.gradle.org/distributions/gradle-8.10.2-all.zip\n")
        self.assertEqual([(PASS, "toolchain")], statuses(self.rows()))

    def test_agp_not_found_is_not_applicable(self):
        self.assertEqual([(NA, "toolchain")], statuses(self.rows()))

    def test_requirements_follow_the_published_table(self):
        self.assertEqual(("8.9", 17), android.agp_requirements("8.7.3"))
        self.assertEqual(("7.5", 11), android.agp_requirements("7.4.2"))

    def test_java_major_is_read_from_version_output(self):
        self.assertEqual(17, android.java_major('openjdk version "17.0.9" 2023-10-17'))
        self.assertEqual(8, android.java_major('java version "1.8.0_391"'))


class NativeJdkTest(Workdir):
    def stub_java(self, folder, major):
        bin_dir = self.root / folder / "bin"
        bin_dir.mkdir(parents=True)
        script = bin_dir / "java"
        script.write_text(f'#!/bin/bash\necho \'openjdk version "{major}.0.1"\' >&2\n')
        script.chmod(0o755)
        return self.root / folder

    def test_java_home_wins_over_the_java_on_path(self):
        home, other = self.stub_java("home", 17), self.stub_java("other", 11)
        with mock.patch.dict(os.environ, {"JAVA_HOME": str(home), "PATH": f"{other / 'bin'}{os.pathsep}{os.environ['PATH']}"}):
            self.assertEqual(17, android.native_jdk())

    def test_java_on_path_is_used_when_java_home_is_unset(self):
        other = self.stub_java("other", 11)
        env = {k: v for k, v in os.environ.items() if k != "JAVA_HOME"}
        with mock.patch.dict(os.environ, {**env, "PATH": f"{other / 'bin'}{os.pathsep}{env['PATH']}"}, clear=True):
            self.assertEqual(11, android.native_jdk())


class PluginFloorTest(AndroidDir):
    def plugins(self, floor):
        plugin = self.root / "pub-cache" / "firebase_messaging"
        write(plugin, "android/build.gradle", f"android {{ defaultConfig {{ minSdkVersion {floor} }} }}\n")
        meta = {"plugins": {"android": [{"name": "firebase_messaging", "path": str(plugin) + "/"}]}}
        write(self.root, ".flutter-plugins-dependencies", json.dumps(meta))

    def rows(self):
        return android.plugin_floor_rows(self.text(), self.root)

    def test_plugin_needing_more_than_the_app_declares_warns(self):
        self.plugins(26)
        rows = self.rows()
        self.assertEqual([(WARN, "plugins")], statuses(rows))
        self.assertIn("firebase_messaging", rows[0].text)

    def test_plugins_within_the_app_floor_pass(self):
        self.plugins(21)
        self.assertEqual([(PASS, "plugins")], statuses(self.rows()))

    def test_flutter_managed_app_floor_is_not_compared(self):
        self.put(min_sdk="flutter.minSdkVersion")
        self.plugins(26)
        self.assertEqual([], self.rows())

    def test_plugin_entry_without_a_path_is_skipped_not_resolved_against_cwd(self):
        write(self.root, ".flutter-plugins-dependencies", json.dumps({"plugins": {"android": [{"name": "x"}]}}))
        self.assertIsInstance(self.rows(), list)

    def test_missing_plugin_manifest_yields_no_row(self):
        self.assertEqual([], self.rows())


class DoctorTest(unittest.TestCase):
    def test_toolchain_marker_maps_to_a_status(self):
        expected = [(PASS, "doctor"), (WARN, "doctor"), (FAIL, "doctor")]
        actual = [statuses(android.doctor_rows({"Android toolchain": m}))[0] for m in ("✓", "!", "✗")]
        self.assertEqual(expected, actual)

    def test_absent_report_is_not_applicable(self):
        self.assertEqual([(NA, "doctor")], statuses(android.doctor_rows(None)))


class CheckTest(AndroidDir):
    def test_flutter_project_runs_every_group_without_raising(self):
        write(self.root, "pubspec.yaml", FLUTTER_PUBSPEC)
        from earendil import detect
        rows = android.check(detect(self.root), commands=False, doctor=None)
        dims = {r.dim for r in rows}
        self.assertTrue({"identity", "sdk", "version", "release", "key", "minify", "toolchain", "doctor"} <= dims)

    def test_project_with_no_application_module_fails_once(self):
        (self.module / "build.gradle.kts").unlink()
        write(self.root, "pubspec.yaml", FLUTTER_PUBSPEC)
        from earendil import detect
        rows = android.check(detect(self.root), commands=False, doctor=None)
        self.assertEqual((FAIL, "module"), statuses(rows)[0])


if __name__ == "__main__":
    unittest.main()
