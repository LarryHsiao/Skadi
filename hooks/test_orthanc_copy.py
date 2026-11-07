#!/usr/bin/env python3
"""Tests for orthanc-copy.py — the copy-marker helper Orthanc turns into a clickable line."""

import importlib.util
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
HELPER = HERE / "orthanc-copy.py"
_spec = importlib.util.spec_from_file_location("orthanc_copy", HELPER)
orthanc_copy = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(orthanc_copy)


class ValidNameTest(unittest.TestCase):
    def test_plain_names_with_an_extension_are_accepted(self):
        for name in ("block-1.sh", "a", "x.y-z_1", "Block2.PY"):
            self.assertTrue(orthanc_copy.valid_name(name), name)

    def test_separators_leading_dots_and_spaces_are_refused(self):
        for name in ("", ".hidden", "a/b", "a\\b", "-lead", "a b", "a:b"):
            self.assertFalse(orthanc_copy.valid_name(name), name)

    def test_windows_device_names_are_refused_with_or_without_an_extension(self):
        for name in ("con", "NUL.txt", "com1", "LPT9.sh", "Aux", "prn.sh", "COM9"):
            self.assertFalse(orthanc_copy.valid_name(name), name)

    def test_names_that_merely_start_like_a_device_are_accepted(self):
        for name in ("console.sh", "com10.sh", "nullable"):
            self.assertTrue(orthanc_copy.valid_name(name), name)


class WriteBlockTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name) / "orthanc-copy"

    def test_the_block_lands_byte_for_byte_and_the_folder_is_created(self):
        expected = b"git status\r\necho 'x'\n\nno trailing newline"
        orthanc_copy.write_block("block-1.sh", expected, self.directory)
        self.assertEqual(expected, (self.directory / "block-1.sh").read_bytes())

    def test_a_second_write_overwrites_the_first(self):
        orthanc_copy.write_block("block-1.sh", b"old", self.directory)
        orthanc_copy.write_block("block-1.sh", b"new", self.directory)
        self.assertEqual(b"new", (self.directory / "block-1.sh").read_bytes())


class MarkerTest(unittest.TestCase):
    def test_the_marker_names_the_full_file_name(self):
        self.assertEqual("⧉ copy:block-1.sh", orthanc_copy.marker("block-1.sh"))


class RunTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name) / "orthanc-copy"

    def test_the_file_exists_before_the_marker_is_printed(self):
        target = self.directory / "block-1.sh"
        seen = []

        class Out(io.BytesIO):
            def write(inner, data):
                seen.append(target.exists())
                return super().write(data)

        out = Out()
        code = orthanc_copy.run("block-1.sh", b"ls\n", self.directory, out)
        self.assertEqual((0, [True], "⧉ copy:block-1.sh\n".encode("utf-8")),
                         (code, seen, out.getvalue()))

    def test_an_invalid_name_writes_nothing_and_prints_no_marker(self):
        out = io.BytesIO()
        code = orthanc_copy.run("../evil", b"x", self.directory, out)
        self.assertEqual((2, b"", False), (code, out.getvalue(), self.directory.exists()))


class CommandLineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def invoke(self, *args, stdin=b""):
        env = {**os.environ, "ORTHANC_COPY_DIR": str(Path(self.tmp.name) / "orthanc-copy")}
        return subprocess.run([sys.executable, str(HELPER), *args], input=stdin, capture_output=True, env=env)

    def test_the_marker_is_written_as_utf8_bytes_whatever_the_console_encoding(self):
        done = self.invoke("block-1.sh", stdin=b"echo hi\n")
        self.assertEqual((0, "⧉ copy:block-1.sh\n".encode("utf-8")), (done.returncode, done.stdout))

    def test_a_missing_name_is_a_usage_error(self):
        self.assertEqual(2, self.invoke().returncode)


class CopyDirTest(unittest.TestCase):
    def test_the_default_folder_is_orthanc_copy_under_the_system_temp(self):
        saved = os.environ.pop("ORTHANC_COPY_DIR", None)
        self.addCleanup(lambda: os.environ.__setitem__("ORTHANC_COPY_DIR", saved) if saved else None)
        expected = Path(tempfile.gettempdir()) / "orthanc-copy"
        self.assertEqual(expected, orthanc_copy.copy_dir())


if __name__ == "__main__":
    unittest.main()
