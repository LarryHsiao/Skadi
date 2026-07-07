#!/usr/bin/env python3
"""Tests for the YouTrack skeleton-stage decider.

Focus: the [ENWINA] description-drift notice council posts at approval must be
invisible to the decider — it is a bot comment bearing an unrecognized token, so
it must neither be read as a plan/skeleton nor shift the derived action. These
tests pin that invariant (the [ENWINA] feature depends on it) and anchor the
draft_skeleton approval branch it hooks into.
"""

import importlib.util
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("skeleton_rung", HERE / "skeleton-rung.py")
rung = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rung)

BOT = "claude"
HUMAN = "elrond"


def _plan(created, consumed=0):
    return {"id": "p1", "login": BOT, "created": created,
            "text": f"[PLAN] — awaiting [FORTH]\n<!-- consumed: {consumed} -->\n\nbody"}


def _forth(created):
    return {"id": "h1", "login": HUMAN, "created": created, "text": "[FORTH]"}


def _enwina(created):
    return {"id": "e1", "login": BOT, "created": created,
            "text": "[ENWINA] The approved [PLAN] has moved past the description."}


class ApprovalBranchTest(unittest.TestCase):
    def test_forth_over_plan_yields_draft_skeleton(self):
        expected = "draft_skeleton"
        data = {"comments": [_plan(100), _forth(200)]}
        self.assertEqual(rung.decide(data)["action"], expected)


class EnwinaIsInvisibleTest(unittest.TestCase):
    def test_enwina_does_not_change_the_action(self):
        # The notice council posts at approval must not perturb the decision.
        without = {"comments": [_plan(100), _forth(200)]}
        with_notice = {"comments": [_plan(100), _forth(200), _enwina(300)]}
        expected = rung.decide(without)["action"]
        self.assertEqual(rung.decide(with_notice)["action"], expected)
        self.assertEqual(expected, "draft_skeleton")

    def test_enwina_is_not_read_as_a_plan(self):
        # A bare [ENWINA] bot comment must not be mistaken for the [PLAN] rung;
        # with a [MELLON] summons and no real plan, the decider still drafts one.
        expected = "draft_plan"
        data = {"comments": [
            {"id": "m1", "login": HUMAN, "created": 50, "text": "[MELLON]"},
            _enwina(100),
        ]}
        self.assertEqual(rung.decide(data)["action"], expected)

    def test_enwina_is_not_counted_as_human_counsel(self):
        # Posted as the bot, [ENWINA] is excluded from the human set, so it does
        # not read as fresh counsel that would flip an awaiting plan to answer.
        expected = "await_plan"
        data = {"comments": [_plan(100, consumed=100), _enwina(300)]}
        self.assertEqual(rung.decide(data)["action"], expected)


if __name__ == "__main__":
    unittest.main()
