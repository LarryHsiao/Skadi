#!/usr/bin/env python3
"""Tests for the board's Stability tile — app discovery and crash-free % math."""

import importlib.util
import json
import tempfile
import unittest
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("board_stability", HERE / "board-stability.py")
board_stability = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(board_stability)


class TableIdTest(unittest.TestCase):
    def test_a_bundle_id_becomes_the_export_table_name(self):
        expected = "com_jubohealth_vitallink_ca_ANDROID"
        result = board_stability.table_id("com.jubohealth.vitallink_ca", "android")
        self.assertEqual(expected, result)


class ParseCrashRoutingTest(unittest.TestCase):
    def test_a_legacy_six_field_row_parses_with_no_ga_pairing(self):
        text = "- /Users/x/work/vitallink-ca | na | vitallink-ca | com.jubohealth.vitallink_ca | ANDROID | a@work.com"
        expected = {"label": "vitallink-ca · na · ANDROID", "project": "vitallink-ca",
                    "bundle": "com.jubohealth.vitallink_ca", "platform": "ANDROID",
                    "account": "a@work.com", "ga_project": None, "ga_dataset": None}
        result = board_stability.parse_crash_routing(text)[0]
        self.assertEqual(expected, result)

    def test_an_extended_eight_field_row_carries_the_ga_pairing(self):
        text = ("- /Users/x/work/vitallink-ca | jp | jubolink | com.jubohealth.jubogo | ANDROID | "
                "a@work.com | jubolink | analytics_123456")
        row = board_stability.parse_crash_routing(text)[0]
        expected = ("jubolink", "analytics_123456")
        result = (row["ga_project"], row["ga_dataset"])
        self.assertEqual(expected, result)

    def test_a_malformed_row_is_skipped_not_raised_on(self):
        text = "- only | three | fields"
        expected = []
        result = board_stability.parse_crash_routing(text)
        self.assertEqual(expected, result)

    def test_frontmatter_is_not_read_as_an_app_row(self):
        text = "---\nname: crash-routing\ndescription: repo -> Firebase coordinates\n---\n"
        expected = []
        result = board_stability.parse_crash_routing(text)
        self.assertEqual(expected, result)

    def test_the_label_reads_repo_basename_flavor_platform(self):
        text = "- /Users/x/work/vitallink-ca | jp | jubolink | com.jubohealth.jubogo | android | a@work.com"
        expected = "vitallink-ca · jp · ANDROID"
        result = board_stability.parse_crash_routing(text)[0]["label"]
        self.assertEqual(expected, result)


class MergeAppsTest(unittest.TestCase):
    def app(self, label, **over):
        base = {"label": label, "project": "p", "bundle": "b", "platform": "ANDROID",
                "account": "a@work.com", "ga_project": None, "ga_dataset": None}
        base.update(over)
        return base

    def test_a_local_entry_overrides_a_discovered_one_with_the_same_label(self):
        discovered = [self.app("vitallink-ca · na · ANDROID", ga_project=None)]
        local = [self.app("vitallink-ca · na · ANDROID", ga_project="vitallink-ca", ga_dataset="analytics_1")]
        expected = ("vitallink-ca", "analytics_1")
        result = board_stability.merge_apps(discovered, local)[0]
        result = (result["ga_project"], result["ga_dataset"])
        self.assertEqual(expected, result)

    def test_distinct_labels_all_survive_sorted(self):
        discovered = [self.app("b-app · na · ANDROID"), self.app("a-app · na · ANDROID")]
        expected = ["a-app · na · ANDROID", "b-app · na · ANDROID"]
        result = [a["label"] for a in board_stability.merge_apps(discovered, [])]
        self.assertEqual(expected, result)

    def test_no_apps_anywhere_yields_an_empty_list(self):
        expected = []
        result = board_stability.merge_apps([], [])
        self.assertEqual(expected, result)


class CrashFreePctTest(unittest.TestCase):
    def test_a_normal_ratio_reads_as_a_percentage(self):
        expected = 99.0
        result = board_stability.crash_free_pct(10, 1000)
        self.assertEqual(expected, result)

    def test_zero_active_users_has_no_denominator(self):
        expected = None
        result = board_stability.crash_free_pct(5, 0)
        self.assertEqual(expected, result)

    def test_an_absent_active_count_has_no_denominator(self):
        expected = None
        result = board_stability.crash_free_pct(5, None)
        self.assertEqual(expected, result)

    def test_crashed_exceeding_active_clamps_to_zero_not_negative(self):
        expected = 0.0
        result = board_stability.crash_free_pct(500, 100)
        self.assertEqual(expected, result)


class LabelSlugTest(unittest.TestCase):
    def test_a_label_becomes_a_lowercase_dash_joined_slug(self):
        expected = "vitallink-ca-jp-android"
        result = board_stability.label_slug("vitallink-ca · jp · ANDROID")
        self.assertEqual(expected, result)

    def test_no_leading_or_trailing_dashes(self):
        expected = "a-b"
        result = board_stability.label_slug("· a · b ·")
        self.assertEqual(expected, result)


class BucketByAvailabilityTest(unittest.TestCase):
    def app(self, label):
        return {"label": label, "project": "p", "bundle": "b", "platform": "ANDROID", "account": "a@work.com"}

    def test_a_result_with_a_percentage_buckets_ok(self):
        pairs = [(self.app("ok-app"), {"crash_free_pct": 99.0})]
        expected = {"ok": ["ok-app"], "needs_scrape": []}
        result = board_stability.bucket_by_availability(pairs)
        result = {k: [a["label"] for a in v] for k, v in result.items()}
        self.assertEqual(expected, result)

    def test_a_null_percentage_buckets_needs_scrape_regardless_of_why(self):
        pairs = [
            (self.app("no-ga4"), {"crash_free_pct": None, "note": "GA4 not configured"}),
            (self.app("query-failed"), {"crash_free_pct": None, "note": "bq exited 1"}),
        ]
        expected = {"ok": [], "needs_scrape": ["no-ga4", "query-failed"]}
        result = board_stability.bucket_by_availability(pairs)
        result = {k: [a["label"] for a in v] for k, v in result.items()}
        self.assertEqual(expected, result)

    def test_no_apps_buckets_both_empty(self):
        expected = {"ok": [], "needs_scrape": []}
        result = board_stability.bucket_by_availability([])
        self.assertEqual(expected, result)


class SweepTest(unittest.TestCase):
    """sweep() itself calls list_apps()/fetch() — both stubbed here so the
    bucketing behavior is provable without a real bq CLI or crash_routing.md."""

    def app(self, label):
        return {"label": label, "project": "p", "bundle": "b", "platform": "ANDROID", "account": "a@work.com"}

    def test_a_query_failure_for_one_app_does_not_abort_the_sweep(self):
        original_list_apps, original_fetch = board_stability.list_apps, board_stability.fetch
        board_stability.list_apps = lambda: [self.app("ok-app"), self.app("bad-app")]

        def fake_fetch(app):
            if app["label"] == "bad-app":
                raise board_stability.QueryFailure("bq exited 1")
            return {"crash_free_pct": 99.0}

        board_stability.fetch = fake_fetch
        try:
            result = board_stability.sweep()
        finally:
            board_stability.list_apps, board_stability.fetch = original_list_apps, original_fetch
        expected = {"ok": ["ok-app"], "needs_scrape": ["bad-app"]}
        result = {k: [a["label"] for a in v] for k, v in result.items()}
        self.assertEqual(expected, result)

    def test_no_bound_apps_sweeps_to_both_buckets_empty(self):
        original_list_apps = board_stability.list_apps
        board_stability.list_apps = lambda: []
        try:
            result = board_stability.sweep()
        finally:
            board_stability.list_apps = original_list_apps
        expected = {"ok": [], "needs_scrape": []}
        self.assertEqual(expected, result)


class FormatSweepReportTest(unittest.TestCase):
    def test_nothing_needing_a_scrape_reads_as_all_clear(self):
        expected = "board: stability — every bound app already has a live number, nothing to scrape"
        result = board_stability.format_sweep_report({"ok": ["a"], "needs_scrape": []})
        self.assertEqual(expected, result)

    def test_apps_needing_a_scrape_are_named_with_their_routing(self):
        bucketed = {"ok": [], "needs_scrape": [
            {"label": "vitallink-ca · na · ANDROID", "project": "vitallink-ca",
             "bundle": "com.jubohealth.vitallink_ca", "platform": "ANDROID", "account": "a@work.com"},
        ]}
        report = board_stability.format_sweep_report(bucketed)
        expected = True
        result = ("vitallink-ca · na · ANDROID" in report
                   and "project=vitallink-ca" in report
                   and "bundle=com.jubohealth.vitallink_ca" in report
                   and "board.sh stability-write" in report)
        self.assertEqual(expected, result)

    def test_the_count_in_the_headline_matches_the_roster(self):
        bucketed = {"ok": [], "needs_scrape": [{"label": "a"}, {"label": "b"}]}
        expected = True
        result = "2 app(s) need a console scrape" in board_stability.format_sweep_report(bucketed)
        self.assertEqual(expected, result)


class WriteTest(unittest.TestCase):
    def test_a_scraped_reading_becomes_a_stability_channel(self):
        app = {"label": "vitallink-ca · jp · ANDROID", "project": "p", "bundle": "b",
               "platform": "ANDROID", "account": "a@work.com"}
        expected = {"channel": "stability", "label": "vitallink-ca · jp · ANDROID",
                    "crash_free_pct": 97.5, "window_days": None, "source": "console",
                    "note": None, "slug": "vitallink-ca-jp-android"}
        result = board_stability.write(app, {"crash_free_pct": 97.5, "note": None})
        self.assertEqual(expected, result)

    def test_a_scrape_that_found_nothing_carries_its_note_through(self):
        app = {"label": "vitallink-ca · na · ANDROID"}
        expected = "console dashboard showed no crash-free figure"
        result = board_stability.write(app, {"crash_free_pct": None,
                                              "note": "console dashboard showed no crash-free figure"})["note"]
        self.assertEqual(expected, result)


class WriteCliTest(unittest.TestCase):
    """The `write` CLI subcommand's own error path — board.sh checks the file
    exists before calling in, but malformed *content* only surfaces here."""

    def test_malformed_from_json_content_exits_loud_not_silent(self):
        original_stability_apps = board_stability.STABILITY_APPS
        tmp = Path(tempfile.mkdtemp())
        apps_file = tmp / "stability-apps.json"
        apps_file.write_text(json.dumps([
            {"label": "x", "project": "p", "bundle": "b", "platform": "ANDROID", "account": "a"}]))
        bad_json = tmp / "bad.json"
        bad_json.write_text("not json")
        board_stability.STABILITY_APPS = apps_file
        try:
            with self.assertRaises(SystemExit):
                board_stability.main(["write", "x", "--from-json", str(bad_json)])
        finally:
            board_stability.STABILITY_APPS = original_stability_apps


class SqlBuilderTest(unittest.TestCase):
    def test_crashed_users_sql_names_the_export_table_and_window(self):
        sql = board_stability.crashed_users_sql("proj", "firebase_crashlytics", "bundle_ANDROID", 7)
        expected = True
        result = "`proj.firebase_crashlytics.bundle_ANDROID`" in sql and "INTERVAL 7 DAY" in sql
        self.assertEqual(expected, result)

    def test_active_users_sql_bounds_the_window_by_anchor(self):
        anchor = date(2026, 8, 5)
        sql = board_stability.active_users_sql("gaproj", "analytics_1", "com.foo", 7, anchor)
        expected = True
        result = ('BETWEEN "20260730" AND "20260805"' in sql
                  and 'app_info.id = "com.foo"' in sql
                  and "`gaproj.analytics_1.events_*`" in sql)
        self.assertEqual(expected, result)


class FetchTest(unittest.TestCase):
    """fetch() itself shells to bq — only the no-GA4-pairing degrade path is
    provable offline; the live query path waits on a real export, as beleg's does."""

    def test_an_app_with_no_ga_pairing_degrades_with_a_note(self):
        board_stability.bq_count = lambda project, sql, account: 3  # stub the one bq call fetch makes
        app = {"label": "vitallink-ca · na · ANDROID", "project": "p", "bundle": "b",
               "platform": "ANDROID", "account": "a@work.com", "ga_project": None, "ga_dataset": None}
        result = board_stability.fetch(app)
        expected = {"crash_free_pct": None, "active_users": None, "crashed_users": 3}
        result = {k: result[k] for k in expected}
        self.assertEqual(expected, result)


if __name__ == "__main__":
    unittest.main()
