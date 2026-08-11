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

    def test_group_from_sidecar_with_ungrouped_fallback(self):
        self._write("rail.html", 2000)
        (self.dir / "rail.json").write_text(
            json.dumps({"title": "Nav rail", "group": "nav-rail"}), encoding="utf-8")
        self._write("stray.png", 1000)

        expected = [
            {"name": "rail.html", "group": "nav-rail"},
            {"name": "stray.png", "group": "Ungrouped"},
        ]
        result = [{"name": e["name"], "group": e["group"]} for e in mirror.scan(self.dir)]
        self.assertEqual(expected, result)

    def test_non_artifacts_skipped(self):
        self._write("notes.txt", 1000)
        self._write("data.json", 1000)

        expected = []
        result = mirror.scan(self.dir)
        self.assertEqual(expected, result)

    def test_pinned_from_sidecar_defaults_false(self):
        self._write("held.png", 1000)
        (self.dir / "held.json").write_text(json.dumps({"pinned": True}), encoding="utf-8")
        self._write("plain.png", 2000)

        expected = [
            {"name": "plain.png", "pinned": False},
            {"name": "held.png", "pinned": True},
        ]
        result = [{"name": e["name"], "pinned": e["pinned"]} for e in mirror.scan(self.dir)]
        self.assertEqual(expected, result)


class SetPinnedTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_creates_sidecar_when_absent(self):
        path = self.dir / "shot.png"
        path.write_text("x", encoding="utf-8")

        mirror.set_pinned(path, True)

        expected = {"pinned": True}
        result = json.loads((self.dir / "shot.json").read_text(encoding="utf-8"))
        self.assertEqual(expected, result)

    def test_preserves_other_fields(self):
        path = self.dir / "shot.png"
        path.write_text("x", encoding="utf-8")
        (self.dir / "shot.json").write_text(
            json.dumps({"title": "Shot", "group": "nav-rail"}), encoding="utf-8")

        mirror.set_pinned(path, True)

        expected = {"title": "Shot", "group": "nav-rail", "pinned": True}
        result = json.loads((self.dir / "shot.json").read_text(encoding="utf-8"))
        self.assertEqual(expected, result)

    def test_unpin_sets_false(self):
        path = self.dir / "shot.png"
        path.write_text("x", encoding="utf-8")
        (self.dir / "shot.json").write_text(json.dumps({"pinned": True}), encoding="utf-8")

        mirror.set_pinned(path, False)

        expected = {"pinned": False}
        result = json.loads((self.dir / "shot.json").read_text(encoding="utf-8"))
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
            self.assertIn('id="tools"', page_body)
            self.assertIn("deleteSelected", page_body)
            self.assertIn("groupsOf", page_body)

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


class CharsetTest(unittest.TestCase):
    def test_html_artifact_served_with_utf8_charset(self):
        import http.client
        import threading
        from functools import partial
        from http.server import ThreadingHTTPServer

        tmp = tempfile.TemporaryDirectory()
        directory = Path(tmp.name)
        (directory / "notes.html").write_text("<p>收尾 — em dash</p>", encoding="utf-8")
        (directory / "shot.png").write_text("x", encoding="utf-8")
        server = ThreadingHTTPServer(("127.0.0.1", 0), partial(mirror.Handler, directory=str(directory)))
        port = server.server_address[1]
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port)
            conn.request("GET", "/notes.html")
            resp = conn.getresponse()
            body = resp.read().decode("utf-8")
            expected_content_type = "text/html; charset=utf-8"
            self.assertEqual(expected_content_type, resp.headers["Content-Type"])
            self.assertIn("收尾", body)

            conn.request("GET", "/shot.png")
            image = conn.getresponse()
            image.read()
            expected_image_type = "image/png"
            self.assertEqual(expected_image_type, image.headers["Content-Type"])
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


class PinTest(unittest.TestCase):
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

    def _pin(self, name, pinned):
        import http.client

        conn = http.client.HTTPConnection("127.0.0.1", self.port)
        conn.request("POST", "/pin", body=json.dumps({"name": name, "pinned": pinned}))
        resp = conn.getresponse()
        resp.read()
        return resp

    def test_pin_sets_sidecar_flag(self):
        (self.dir / "shot.png").write_text("x", encoding="utf-8")

        expected_status = 204
        resp = self._pin("shot.png", True)
        self.assertEqual(expected_status, resp.status)
        sidecar = json.loads((self.dir / "shot.json").read_text(encoding="utf-8"))
        self.assertTrue(sidecar["pinned"])

    def test_unpin_clears_sidecar_flag(self):
        (self.dir / "shot.png").write_text("x", encoding="utf-8")
        (self.dir / "shot.json").write_text(json.dumps({"pinned": True}), encoding="utf-8")

        expected_status = 204
        resp = self._pin("shot.png", False)
        self.assertEqual(expected_status, resp.status)
        sidecar = json.loads((self.dir / "shot.json").read_text(encoding="utf-8"))
        self.assertFalse(sidecar["pinned"])

    def test_pin_missing_artifact_returns_404(self):
        expected_status = 404
        resp = self._pin("ghost.png", True)
        self.assertEqual(expected_status, resp.status)

    def test_pin_traversal_refused(self):
        outside = self.dir.parent / "henneth-outside.png"
        outside.write_text("x", encoding="utf-8")
        try:
            expected_status = 404
            resp = self._pin("../henneth-outside.png", True)
            self.assertEqual(expected_status, resp.status)
            self.assertFalse(outside.with_suffix(".json").exists())
        finally:
            outside.unlink()

    def test_pin_malformed_body_returns_400(self):
        import http.client

        (self.dir / "shot.png").write_text("x", encoding="utf-8")
        conn = http.client.HTTPConnection("127.0.0.1", self.port)
        conn.request("POST", "/pin", body="not json")
        resp = conn.getresponse()
        resp.read()

        expected_status = 400
        self.assertEqual(expected_status, resp.status)


class GroupSelectionTest(unittest.TestCase):
    def test_group_header_checkbox_wiring_present(self):
        expected_markers = [
            "toggleGroupSel",
            "groupSel",
            'class="gchk"',
            ".indeterminate",
            ".selecting .gchk { display:inline-block; }",
        ]
        for marker in expected_markers:
            self.assertIn(marker, mirror.PAGE)


class PageLayoutTest(unittest.TestCase):
    def test_collapsed_panel_keeps_main_full_width(self):
        # With the side panel hidden (display:none), a two-track collapsed grid
        # ("0 1fr") would auto-place the lone .main into the 0-width first track,
        # blanking the page. The collapsed frame must be a single 1fr column.
        expected_rule = "body.side-collapsed .frame { grid-template-columns:1fr; }"
        self.assertIn(expected_rule, mirror.PAGE)

        starved_rule = "grid-template-columns:0 1fr"
        self.assertNotIn(starved_rule, mirror.PAGE)


class ImageZoomTest(unittest.TestCase):
    def test_image_click_toggles_native_size(self):
        expected_markers = [
            ".stage img { max-width:100%; max-height:100%; object-fit:contain; cursor:zoom-in; }",
            ".stage.zoomed img { max-width:none; max-height:none; cursor:zoom-out; }",
            'classList.toggle("zoomed")',
        ]
        for marker in expected_markers:
            self.assertIn(marker, mirror.PAGE)


class PinnedSortTest(unittest.TestCase):
    def test_pinned_items_sort_first_within_their_group(self):
        expected_markers = [
            "bucket.filter(a => a.pinned)",
            "bucket.filter(a => !a.pinned)",
            'data-pin="${esc(a.name)}"',
            "async function togglePin(name, on)",
            'fetch("/pin", {method:"POST"',
        ]
        for marker in expected_markers:
            self.assertIn(marker, mirror.PAGE)


if __name__ == "__main__":
    unittest.main()
