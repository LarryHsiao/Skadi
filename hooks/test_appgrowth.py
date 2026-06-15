#!/usr/bin/env python3
"""Tests for the appgrowth dashboard's pure helpers."""

import importlib.util
import unittest
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("appgrowth", HERE / "appgrowth.py")
app = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(app)


class PctWordTest(unittest.TestCase):
    def test_increase_reads_up(self):
        expected = "up 39%"
        result = app.pct_word(32, 23)
        self.assertEqual(expected, result)

    def test_decrease_reads_down(self):
        expected = "down 58%"
        result = app.pct_word(8, 19)
        self.assertEqual(expected, result)

    def test_no_change_reads_flat(self):
        expected = "flat"
        result = app.pct_word(5, 5)
        self.assertEqual(expected, result)

    def test_from_zero_reads_new(self):
        expected = "new"
        result = app.pct_word(3, 0)
        self.assertEqual(expected, result)


class DeltaTest(unittest.TestCase):
    def test_up_gets_up_arrow(self):
        expected = ("up", "▲ 39%")
        result = app.delta(32, 23)
        self.assertEqual(expected, result)

    def test_down_gets_down_arrow(self):
        expected = ("down", "▼ 58%")
        result = app.delta(8, 19)
        self.assertEqual(expected, result)

    def test_flat_has_no_arrow(self):
        expected = ("flat", "flat")
        result = app.delta(5, 5)
        self.assertEqual(expected, result)


class PointsTest(unittest.TestCase):
    def test_empty_values_yield_empty_string(self):
        expected = ""
        result = app.points([], 10)
        self.assertEqual(expected, result)

    def test_single_value_is_centered_at_max(self):
        expected = "370,20"
        result = app.points([5], 5)
        self.assertEqual(expected, result)

    def test_two_values_span_the_axis(self):
        expected = "40,220 700,20"
        result = app.points([0, 5], 5)
        self.assertEqual(expected, result)


class FmtDayTest(unittest.TestCase):
    def test_ymd_becomes_short_label(self):
        expected = "Jun 9"
        result = app.fmt_day("20260609")
        self.assertEqual(expected, result)


class WindowsTest(unittest.TestCase):
    def test_week_window_is_seven_days_through_anchor(self):
        expected = (date(2026, 6, 4), date(2026, 6, 10))
        result = app.windows(date(2026, 6, 10))["wau"]
        self.assertEqual(expected, result)


class RenderResilienceTest(unittest.TestCase):
    def test_renders_with_no_data_without_crashing(self):
        headline = {"wau": 0, "wau_prev": 0, "mau": 0, "mau_prev": 0}
        page = app.render_page(headline, [], [], date(2026, 6, 10))
        expected = True
        result = "METIS · GROWTH" in page
        self.assertEqual(expected, result)


if __name__ == "__main__":
    unittest.main()
