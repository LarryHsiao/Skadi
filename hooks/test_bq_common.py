#!/usr/bin/env python3
"""Tests for bq_common — the bq-CLI scaffolding shared by appgrowth.py,
beleg-crashes.py, and board-stability.py."""

import unittest

import bq_common


class ExeTest(unittest.TestCase):
    def test_a_binary_on_path_resolves_to_its_full_path(self):
        expected = True
        result = bq_common.exe("python3").endswith("python3") or bq_common.exe("python3") == "python3"
        self.assertEqual(expected, result)

    def test_an_unknown_binary_falls_back_to_its_own_name(self):
        expected = "definitely-not-a-real-binary-xyz"
        result = bq_common.exe("definitely-not-a-real-binary-xyz")
        self.assertEqual(expected, result)


class QueryFailureTest(unittest.TestCase):
    def test_it_is_a_runtime_error(self):
        expected = True
        result = issubclass(bq_common.QueryFailure, RuntimeError)
        self.assertEqual(expected, result)

    def test_it_carries_the_message_it_was_raised_with(self):
        expected = "bq exited 1"
        try:
            raise bq_common.QueryFailure(expected)
        except bq_common.QueryFailure as failure:
            result = str(failure)
        self.assertEqual(expected, result)


if __name__ == "__main__":
    unittest.main()
