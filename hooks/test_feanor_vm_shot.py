#!/usr/bin/env python3
"""Tests for feanor-vm-shot.py against a fake VM service on a local socket."""

import base64
import importlib.util
import json
import socket
import struct
import threading
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("vm_shot", HERE / "feanor-vm-shot.py")
vm_shot = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vm_shot)

PNG_BYTES = b"\x89PNG-fake-image"
PING_FRAME = bytes([0x89, 0x00])
CLOSE_FRAME = bytes([0x88, 0x00])
# Long enough that the reply crosses the 125-byte frame boundary into the
# 16-bit length form, which the prototype's single-byte path would not reach.
TREE = {
    "description": "MaterialApp",
    "valueId": "inspector-0",
    "children": [
        {"description": "Navigator", "valueId": "inspector-1", "children": [
            {"description": "ResidentPage", "valueId": "inspector-2" + "x" * 150},
        ]},
    ],
}


def _recv_frame(conn):
    b0, b1 = conn.recv(2)
    n = b1 & 0x7F
    if n == 126:
        n = struct.unpack("!H", conn.recv(2))[0]
    elif n == 127:
        n = struct.unpack("!Q", conn.recv(8))[0]
    mask = conn.recv(4)
    data = b""
    while len(data) < n:
        data += conn.recv(n - len(data))
    return bytes(b ^ mask[i % 4] for i, b in enumerate(data)).decode()


def _send_frame(conn, text):
    data = text.encode()
    n = len(data)
    if n < 126:
        conn.sendall(struct.pack("!BB", 0x81, n) + data)
    else:
        conn.sendall(struct.pack("!BBH", 0x81, 126, n) + data)


class FakeVmService:
    """Answers one connection: the handshake, then each JSON-RPC call by method."""

    def __init__(self, answers, status=b"101 Switching Protocols", preface=b""):
        self.answers = answers
        self.status = status
        self.preface = preface
        self.calls = []
        self.server = socket.socket()
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(1)
        self.uri = f"ws://127.0.0.1:{self.server.getsockname()[1]}/tok=/ws"
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self):
        conn, _ = self.server.accept()
        head = b""
        while b"\r\n\r\n" not in head:
            head += conn.recv(1)
        conn.sendall(b"HTTP/1.1 " + self.status + b"\r\n\r\n")
        try:
            while True:
                req = json.loads(_recv_frame(conn))
                self.calls.append(req)
                conn.sendall(self.preface)
                _send_frame(conn, json.dumps({"jsonrpc": "2.0", "id": req["id"],
                                              **self.answers[req["method"]]}))
        except (ValueError, OSError):
            pass
        finally:
            conn.close()
            self.server.close()


def _answers(**overrides):
    answers = {
        "getVM": {"result": {"isolates": [{"id": "isolates/1"}, {"id": "isolates/2"}]}},
        "getIsolate": {"result": {"extensionRPCs": ["ext.flutter.inspector.screenshot"]}},
        "ext.flutter.inspector.getRootWidgetTree": {"result": {"result": TREE}},
        "ext.flutter.inspector.screenshot": {
            "result": {"result": base64.b64encode(PNG_BYTES).decode()}},
    }
    answers.update(overrides)
    return answers


class FindWidgetsTest(unittest.TestCase):
    def test_finds_a_nested_widget_by_description_prefix(self):
        expected = ["inspector-2" + "x" * 150]
        result = [n["valueId"] for n in vm_shot.find_widgets(TREE, "ResidentPage")]
        self.assertEqual(expected, result)

    def test_absent_widget_finds_nothing(self):
        expected = []
        result = vm_shot.find_widgets(TREE, "SettingsPage")
        self.assertEqual(expected, result)


class ShootTest(unittest.TestCase):
    def test_writes_the_inspector_png_for_the_named_widget(self):
        fake = FakeVmService(_answers())
        with TemporaryDirectory() as tmp:
            out = Path(tmp) / "shot.png"
            vm_shot.shoot(fake.uri, str(out), "ResidentPage", 4096, 4096)
            expected = PNG_BYTES
            self.assertEqual(expected, out.read_bytes())
        shot_call = fake.calls[-1]
        expected_params = {"id": TREE["children"][0]["children"][0]["valueId"],
                           "maxPixelRatio": "2"}
        self.assertEqual(expected_params["id"], shot_call["params"]["id"])
        self.assertEqual(expected_params["maxPixelRatio"], shot_call["params"]["maxPixelRatio"])

    def test_missing_widget_fails_loud(self):
        fake = FakeVmService(_answers())
        with TemporaryDirectory() as tmp, self.assertRaises(SystemExit) as caught:
            vm_shot.shoot(fake.uri, str(Path(tmp) / "x.png"), "SettingsPage", 4096, 4096)
        expected = "no SettingsPage in the summary tree"
        self.assertIn(expected, str(caught.exception))

    def test_no_isolate_with_the_extension_fails_loud(self):
        fake = FakeVmService(_answers(getIsolate={"result": {"extensionRPCs": []}}))
        with TemporaryDirectory() as tmp, self.assertRaises(SystemExit) as caught:
            vm_shot.shoot(fake.uri, str(Path(tmp) / "x.png"), "ResidentPage", 4096, 4096)
        expected = "no isolate exposes"
        self.assertIn(expected, str(caught.exception))

    def test_an_rpc_error_names_the_method(self):
        fake = FakeVmService(_answers(**{"ext.flutter.inspector.screenshot": {
            "error": {"code": -32000, "message": "'hasSize': is not true"}}}))
        with TemporaryDirectory() as tmp, self.assertRaises(SystemExit) as caught:
            vm_shot.shoot(fake.uri, str(Path(tmp) / "x.png"), "ResidentPage", 4096, 4096)
        expected = "ext.flutter.inspector.screenshot: "
        self.assertIn(expected, str(caught.exception))

    def test_an_empty_image_fails_loud(self):
        fake = FakeVmService(_answers(**{"ext.flutter.inspector.screenshot": {
            "result": {"result": None}}}))
        with TemporaryDirectory() as tmp, self.assertRaises(SystemExit) as caught:
            vm_shot.shoot(fake.uri, str(Path(tmp) / "x.png"), "ResidentPage", 4096, 4096)
        expected = "inspector returned no image"
        self.assertIn(expected, str(caught.exception))

    def test_a_ping_before_a_reply_is_skipped(self):
        fake = FakeVmService(_answers(), preface=PING_FRAME)
        with TemporaryDirectory() as tmp:
            out = Path(tmp) / "shot.png"
            vm_shot.shoot(fake.uri, str(out), "ResidentPage", 4096, 4096)
            expected = PNG_BYTES
            self.assertEqual(expected, out.read_bytes())

    def test_a_close_frame_fails_loud(self):
        fake = FakeVmService(_answers(), preface=CLOSE_FRAME)
        with TemporaryDirectory() as tmp, self.assertRaises(SystemExit) as caught:
            vm_shot.shoot(fake.uri, str(Path(tmp) / "x.png"), "ResidentPage", 4096, 4096)
        expected = "socket closed"
        self.assertEqual(expected, str(caught.exception))

    def test_a_refused_handshake_fails_loud(self):
        fake = FakeVmService(_answers(), status=b"403 Forbidden")
        with self.assertRaises(SystemExit) as caught:
            vm_shot.VmSocket(fake.uri).close()
        expected = "handshake failed"
        self.assertIn(expected, str(caught.exception))


if __name__ == "__main__":
    unittest.main()
