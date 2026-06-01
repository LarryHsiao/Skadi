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


class ServerTest(unittest.TestCase):
    def test_routes_serve_page_scan_and_files(self):
        import http.client
        import threading
        from functools import partial
        from http.server import ThreadingHTTPServer

        tmp = tempfile.TemporaryDirectory()
        directory = Path(tmp.name)
        (directory / "a.png").write_text("x", encoding="utf-8")
        server = ThreadingHTTPServer(("127.0.0.1", 0), partial(mirror.Handler, directory=str(directory)))
        port = server.server_address[1]
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port)

            conn.request("GET", "/")
            page = conn.getresponse()
            page_body = page.read().decode("utf-8")
            self.assertEqual(200, page.status)
            self.assertIn("HENNETH", page_body)

            conn.request("GET", "/favicon.svg")
            favicon = conn.getresponse()
            favicon_body = favicon.read().decode("utf-8")
            expected_favicon_type = "image/svg+xml"
            self.assertEqual(200, favicon.status)
            self.assertEqual(expected_favicon_type, favicon.headers["Content-Type"])
            self.assertIn("<svg", favicon_body)

            conn.request("GET", "/index.json")
            index = conn.getresponse()
            index_names = [e["name"] for e in json.loads(index.read())]
            self.assertEqual(["a.png"], index_names)

            conn.request("GET", "/a.png")
            file_resp = conn.getresponse()
            file_body = file_resp.read().decode("utf-8")
            self.assertEqual(200, file_resp.status)
            self.assertEqual("x", file_body)
        finally:
            server.shutdown()
            server.server_close()
            tmp.cleanup()


class DeleteTest(unittest.TestCase):
    def setUp(self):
        import threading
        from functools import partial
        from http.server import ThreadingHTTPServer

        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.server = ThreadingHTTPServer(
            ("127.0.0.1", 0), partial(mirror.Handler, directory=str(self.dir)))
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self._tmp.cleanup()

    def _delete(self, path):
        import http.client

        conn = http.client.HTTPConnection("127.0.0.1", self.port)
        conn.request("DELETE", path)
        resp = conn.getresponse()
        resp.read()
        return resp

    def test_delete_removes_artifact_and_sidecar(self):
        (self.dir / "shot.png").write_text("x", encoding="utf-8")
        (self.dir / "shot.json").write_text("{}", encoding="utf-8")

        expected_status = 204
        resp = self._delete("/shot.png")
        self.assertEqual(expected_status, resp.status)
        self.assertFalse((self.dir / "shot.png").exists())
        self.assertFalse((self.dir / "shot.json").exists())

    def test_delete_missing_returns_404(self):
        expected_status = 404
        resp = self._delete("/ghost.png")
        self.assertEqual(expected_status, resp.status)

    def test_delete_traversal_refused(self):
        outside = self.dir.parent / "henneth-outside.png"
        outside.write_text("x", encoding="utf-8")
        try:
            expected_status = 404
            resp = self._delete("/../henneth-outside.png")
            self.assertEqual(expected_status, resp.status)
            self.assertTrue(outside.exists())
        finally:
            outside.unlink()


if __name__ == "__main__":
    unittest.main()
