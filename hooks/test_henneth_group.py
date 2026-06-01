#!/usr/bin/env python3
"""Tests for the henneth group-stamping PostToolUse hook."""

import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("henneth_group", HERE / "henneth-group.py")
hook = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hook)


class SidecarForTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        hook.HENNETH = self.dir

    def tearDown(self):
        self._tmp.cleanup()

    def test_artifact_maps_to_stem_sidecar(self):
        expected = self.dir / "rail.json"
        result = hook.sidecar_for(self.dir / "rail.html")
        self.assertEqual(expected, result)

    def test_json_in_folder_is_its_own_sidecar(self):
        expected = self.dir / "rail.json"
        result = hook.sidecar_for(self.dir / "rail.json")
        self.assertEqual(expected, result)

    def test_non_artifact_in_folder_ignored(self):
        expected = None
        result = hook.sidecar_for(self.dir / "notes.txt")
        self.assertEqual(expected, result)

    def test_artifact_outside_folder_ignored(self):
        expected = None
        result = hook.sidecar_for(Path("/elsewhere/rail.html"))
        self.assertEqual(expected, result)


class EnsureGroupTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_missing_sidecar_gets_group(self):
        side = self.dir / "rail.json"
        expected = "729196"
        result = hook.ensure_group(side, "729196")
        self.assertEqual(expected, result)
        self.assertEqual("729196", json.loads(side.read_text())["group"])

    def test_explicit_group_is_left_untouched(self):
        side = self.dir / "rail.json"
        side.write_text(json.dumps({"title": "Nav rail", "group": "nav-rail"}), encoding="utf-8")
        expected = "nav-rail"
        result = hook.ensure_group(side, "729196")
        self.assertEqual(expected, result)
        self.assertEqual("nav-rail", json.loads(side.read_text())["group"])

    def test_sidecar_without_group_is_backfilled_keeping_fields(self):
        side = self.dir / "rail.json"
        side.write_text(json.dumps({"title": "Nav rail"}), encoding="utf-8")
        expected = {"title": "Nav rail", "group": "729196"}
        hook.ensure_group(side, "729196")
        self.assertEqual(expected, json.loads(side.read_text()))


class MainTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        hook.HENNETH = self.dir

    def tearDown(self):
        self._tmp.cleanup()

    def _run(self, payload):
        return hook.main(io.StringIO(json.dumps(payload)))

    def test_write_payload_stamps_session_group(self):
        artifact = self.dir / "wire.html"
        artifact.write_text("x", encoding="utf-8")
        expected_group = "abcdef"
        self._run({
            "session_id": "0000-aaa-abcdef",
            "tool_input": {"file_path": str(artifact)},
        })
        self.assertEqual(expected_group, json.loads((self.dir / "wire.json").read_text())["group"])

    def test_payload_outside_folder_writes_nothing(self):
        self._run({"session_id": "0000-aaa-abcdef", "tool_input": {"file_path": "/elsewhere/x.html"}})
        expected = []
        self.assertEqual(expected, list(self.dir.iterdir()))

    def test_empty_session_id_writes_no_sidecar(self):
        artifact = self.dir / "wire.html"
        artifact.write_text("x", encoding="utf-8")
        self._run({"session_id": "", "tool_input": {"file_path": str(artifact)}})
        expected = False
        self.assertEqual(expected, (self.dir / "wire.json").exists())

    def test_malformed_payload_is_swallowed(self):
        expected = 0
        result = hook.main(io.StringIO("not json at all"))
        self.assertEqual(expected, result)


if __name__ == "__main__":
    unittest.main()
