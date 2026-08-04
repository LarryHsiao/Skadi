#!/usr/bin/env python3
"""Tests for /beleg's crash ranking — the scorer must not care where issues came from."""

import importlib.util
import unittest
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("beleg", HERE / "beleg-crashes.py")
beleg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(beleg)

TODAY = date(2026, 8, 4)


def issue(**over):
    """A middling issue; each test bends one signal so the effect is isolated."""
    base = {
        "id": "abc123",
        "title": "NullPointerException",
        "users": 100,
        "events": 400,
        "first_seen": "2026-06-01",
        "last_seen": "2026-08-04",
        "versions": ["1.9.0", "1.10.0"],
        "blame_frame": None,
        "in_package": None,
    }
    base.update(over)
    return base


class TrendTest(unittest.TestCase):
    def test_first_seen_inside_the_window_reads_new(self):
        expected = "new"
        result = beleg.trend_of(issue(first_seen="2026-08-01"), TODAY)
        self.assertEqual(expected, result)

    def test_last_seen_long_ago_reads_fading(self):
        expected = "fading"
        result = beleg.trend_of(issue(last_seen="2026-07-01"), TODAY)
        self.assertEqual(expected, result)

    def test_old_but_still_landing_reads_steady(self):
        expected = "steady"
        result = beleg.trend_of(issue(), TODAY)
        self.assertEqual(expected, result)

    def test_an_explicit_trend_is_taken_over_the_derived_one(self):
        expected = "regressed"
        result = beleg.trend_of(issue(trend="regressed"), TODAY)
        self.assertEqual(expected, result)


class ActionabilityTest(unittest.TestCase):
    def test_first_party_frame_scores_full(self):
        expected = 1.0
        result = beleg.actionability_of(issue(in_package=True), beleg.RUBRIC)
        self.assertEqual(expected, result)

    def test_third_party_frame_is_discounted(self):
        expected = 0.3
        result = beleg.actionability_of(issue(in_package=False), beleg.RUBRIC)
        self.assertEqual(expected, result)

    def test_unknown_origin_is_neutral_not_penalised(self):
        expected = 1.0
        result = beleg.actionability_of(issue(in_package=None), beleg.RUBRIC)
        self.assertEqual(expected, result)


class RankTest(unittest.TestCase):
    def test_many_users_outrank_many_events(self):
        loop = issue(id="loop", users=2, events=50000)
        fleet = issue(id="fleet", users=800, events=900)
        expected = ["fleet", "loop"]
        result = [i["id"] for i in beleg.rank([loop, fleet], TODAY)]
        self.assertEqual(expected, result)

    def test_a_new_crash_outranks_an_equal_fading_one(self):
        fresh = issue(id="fresh", first_seen="2026-08-02")
        stale = issue(id="stale", last_seen="2026-07-01")
        expected = ["fresh", "stale"]
        result = [i["id"] for i in beleg.rank([fresh, stale], TODAY)]
        self.assertEqual(expected, result)

    def test_a_reachable_crash_outranks_a_louder_vendor_one(self):
        vendor = issue(id="vendor", users=300, in_package=False)
        ours = issue(id="ours", users=150, in_package=True)
        expected = ["ours", "vendor"]
        result = [i["id"] for i in beleg.rank([vendor, ours], TODAY)]
        self.assertEqual(expected, result)

    def test_every_ranked_issue_carries_its_score_and_trend(self):
        expected = {"value", "trend"}
        ranked = beleg.rank([issue()], TODAY)
        result = expected & set(ranked[0])
        self.assertEqual(expected, result)

    def test_no_issues_ranks_to_an_empty_list(self):
        expected = []
        result = beleg.rank([], TODAY)
        self.assertEqual(expected, result)


class DegradedSourceTest(unittest.TestCase):
    """The console collector sees no frame and no versions — ranking must still stand."""

    def test_console_shaped_issues_rank_without_frame_or_versions(self):
        thin = [
            {"id": "a", "title": "A", "users": 10, "events": 10,
             "first_seen": "2026-08-03", "last_seen": "2026-08-04"},
            {"id": "b", "title": "B", "users": 400, "events": 400,
             "first_seen": "2026-08-03", "last_seen": "2026-08-04"},
        ]
        expected = ["b", "a"]
        result = [i["id"] for i in beleg.rank(thin, TODAY)]
        self.assertEqual(expected, result)

    def test_missing_signals_are_named_for_the_report(self):
        thin = [{"id": "a", "title": "A", "users": 1, "events": 1,
                 "first_seen": "2026-08-03", "last_seen": "2026-08-04"}]
        expected = ["actionability", "version concentration"]
        result = beleg.missing_signals(thin)
        self.assertEqual(expected, result)

    def test_full_issues_report_no_missing_signals(self):
        full = [issue(in_package=True, versions=["1.10.0"], latest_version="1.10.0")]
        expected = []
        result = beleg.missing_signals(full)
        self.assertEqual(expected, result)


class ConcentrationTest(unittest.TestCase):
    def test_a_crash_only_in_the_newest_build_is_weighted_up(self):
        expected = 1.5
        confined = issue(versions=["1.10.0"], latest_version="1.10.0")
        result = beleg.concentration_of(confined, beleg.RUBRIC)
        self.assertEqual(expected, result)

    def test_a_crash_across_releases_is_not(self):
        expected = 1.0
        spread = issue(versions=["1.9.0", "1.10.0"], latest_version="1.10.0")
        result = beleg.concentration_of(spread, beleg.RUBRIC)
        self.assertEqual(expected, result)


class TableIdTest(unittest.TestCase):
    def test_a_bundle_id_becomes_the_export_table_name(self):
        expected = "com_jubohealth_vitallink_ca_ANDROID"
        result = beleg.table_id("com.jubohealth.vitallink_ca", "android")
        self.assertEqual(expected, result)

    def test_hyphens_in_an_ios_bundle_are_flattened_too(self):
        expected = "com_jubohealth_vitallink_ca_IOS"
        result = beleg.table_id("com.jubohealth.vitallink-ca", "IOS")
        self.assertEqual(expected, result)


class RowMappingTest(unittest.TestCase):
    """blame_frame.owner is the export's own word on who can fix a crash."""

    def row(self, owner):
        return {"issue_id": "i1", "issue_title": "Boom", "issue_subtitle": "at foo",
                "users": "12", "events": "30", "first_seen": "2026-07-01",
                "last_seen": "2026-08-04", "versions": "1.10.0",
                "blame_file": "lib/foo.dart", "blame_line": "88",
                "blame_symbol": "foo", "blame_owner": owner}

    def test_a_developer_frame_is_first_party(self):
        expected = True
        result = beleg.issue_from_row(self.row("DEVELOPER"), "1.10.0")["in_package"]
        self.assertEqual(expected, result)

    def test_a_vendor_frame_is_not(self):
        expected = False
        result = beleg.issue_from_row(self.row("VENDOR"), "1.10.0")["in_package"]
        self.assertEqual(expected, result)

    def test_an_absent_owner_stays_unknown(self):
        expected = None
        result = beleg.issue_from_row(self.row(None), "1.10.0")["in_package"]
        self.assertEqual(expected, result)

    def test_counts_arrive_as_numbers_not_strings(self):
        expected = 12
        result = beleg.issue_from_row(self.row("DEVELOPER"), "1.10.0")["users"]
        self.assertEqual(expected, result)

    def test_the_batch_latest_version_is_stamped_on_each_issue(self):
        expected = "1.10.0"
        result = beleg.issue_from_row(self.row("DEVELOPER"), "1.10.0")["latest_version"]
        self.assertEqual(expected, result)

    def test_the_blaming_frame_is_carried_for_the_code_read(self):
        expected = {"file": "lib/foo.dart", "line": 88, "symbol": "foo"}
        result = beleg.issue_from_row(self.row("DEVELOPER"), "1.10.0")["blame_frame"]
        self.assertEqual(expected, result)


class NewestVersionTest(unittest.TestCase):
    """A string sort would put 1.9.0 above 1.10.0 and mis-weight every concentration."""

    def test_a_double_digit_minor_outranks_a_single_digit_one(self):
        expected = "1.10.0"
        result = beleg.newest_version([{"versions": "1.9.0,1.10.0"}])
        self.assertEqual(expected, result)

    def test_versions_are_gathered_across_rows(self):
        expected = "2.0.1"
        result = beleg.newest_version([{"versions": "1.9.0"}, {"versions": "2.0.1,1.2.3"}])
        self.assertEqual(expected, result)

    def test_no_versions_yields_an_empty_string(self):
        expected = ""
        result = beleg.newest_version([{"versions": ""}])
        self.assertEqual(expected, result)


if __name__ == "__main__":
    unittest.main()
