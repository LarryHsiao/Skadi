#!/usr/bin/env python3
"""Tests for the henneth artifact mirror server."""

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("mirror_server", HERE / "mirror-server.py")
mirror = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mirror)


class ScanTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _write(self, name, mtime):
        path = self.dir / name
        path.write_text("x", encoding="utf-8")
        os.utime(path, (mtime, mtime))
        return path

    def test_newest_first_with_sidecar_and_fallback(self):
        self._write("login-form.png", 1000)
        self._write("dark-variant.html", 2000)
        (self.dir / "dark-variant.json").write_text(
            json.dumps({"title": "Dark variant", "note": "second pass"}), encoding="utf-8")
        self._write("broken-one.png", 1500)
        (self.dir / "broken-one.json").write_text("{not json", encoding="utf-8")

        expected = [
            {"name": "dark-variant.html", "type": "html", "label": "Dark variant", "note": "second pass"},
            {"name": "broken-one.png", "type": "image", "label": "Broken One", "note": ""},
            {"name": "login-form.png", "type": "image", "label": "Login Form", "note": ""},
        ]
        result = [
            {"name": e["name"], "type": e["type"], "label": e["label"], "note": e["note"]}
            for e in mirror.scan(self.dir)
        ]
        self.assertEqual(expected, result)

    def test_non_artifacts_skipped(self):
        self._write("notes.txt", 1000)
        self._write("data.json", 1000)

        expected = []
        result = mirror.scan(self.dir)
        self.assertEqual(expected, result)


if __name__ == "__main__":
    unittest.main()
