#!/usr/bin/env python3
"""Tests for the appstatus Firebase health snapshot."""

import importlib.util
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("appstatus", HERE / "appstatus.py")
app = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(app)


class HumanizeTest(unittest.TestCase):
    def test_none_reads_not_available(self):
        expected = "n/a"
        result = app.humanize("Firestore rd", None)
        self.assertEqual(expected, result)

    def test_storage_renders_as_gigabytes(self):
        expected = "4.89"
        result = app.humanize(app.STORAGE_COL, 4_890_000_000)
        self.assertEqual(expected, result)

    def test_large_count_gets_thousands_separators(self):
        expected = "12,400"
        result = app.humanize("Firestore rd", 12_400)
        self.assertEqual(expected, result)

    def test_small_count_is_plain_integer(self):
        expected = "5"
        result = app.humanize("Fn calls", 5)
        self.assertEqual(expected, result)


class SumPointsTest(unittest.TestCase):
    def test_empty_response_sums_to_zero(self):
        expected = 0.0
        result = app._sum_points({})
        self.assertEqual(expected, result)

    def test_int64_points_are_summed(self):
        data = {"timeSeries": [{"points": [
            {"value": {"int64Value": "10"}},
            {"value": {"int64Value": "5"}},
        ]}]}
        expected = 15.0
        result = app._sum_points(data)
        self.assertEqual(expected, result)

    def test_double_points_are_summed_across_series(self):
        data = {"timeSeries": [
            {"points": [{"value": {"doubleValue": 1.5}}]},
            {"points": [{"value": {"doubleValue": 2.5}}]},
        ]}
        expected = 4.0
        result = app._sum_points(data)
        self.assertEqual(expected, result)

    def test_missing_value_counts_as_zero(self):
        data = {"timeSeries": [{"points": [{"value": {}}, {"value": {"int64Value": "7"}}]}]}
        expected = 7.0
        result = app._sum_points(data)
        self.assertEqual(expected, result)


if __name__ == "__main__":
    unittest.main()
