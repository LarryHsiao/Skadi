#!/usr/bin/env python3
"""Screenshot one widget of a running debug Flutter app through its VM service.

Usage: python3 -I feanor-vm-shot.py <ws-uri> <out.png> <Widget> [<width> <height>]

The fallback feanor-flutter-shot.sh reaches for when `flutter screenshot`
cannot shoot the device (wireless iOS). It finds the isolate exposing the
widget inspector, takes the summary tree, picks the last node in depth-first
order whose description starts with <Widget> (the innermost of a nested chain), and asks ext.flutter.inspector.screenshot for
a PNG of it. The root widget cannot be shot — offstage routes are not laid out
and the inspector trips a 'hasSize' assertion — so name an on-screen widget,
such as the page class.

<width> <height> cap the image size; the default 4096 leaves maxPixelRatio 2 in
charge, so the PNG is the widget at exactly 2 px per logical px for any widget
up to 2048 logical px, and measurements divide by 2.

Stdlib only: a minimal WebSocket client (handshake, masked text frames out,
unmasked frames in). Debug and profile builds only — release strips the
inspector. Any failure exits non-zero with a one-line reason on stderr.
"""

import base64
import json
import os
import socket
import struct
import sys
from urllib.parse import urlparse

DEFAULT_SIZE = 4096
MAX_PIXEL_RATIO = "2"
SOCKET_TIMEOUT_S = 60
SCREENSHOT_EXTENSION = "ext.flutter.inspector.screenshot"
TREE_EXTENSION = "ext.flutter.inspector.getRootWidgetTree"
OBJECT_GROUP = "feanor_vm_shot"
TEXT_FINAL_FRAME = 0x81
MASK_BIT = 0x80
FIN_BIT = 0x80
OPCODE_BITS = 0x0F
OPCODE_CLOSE = 0x8
CONTROL_OPCODES = (0x9, 0xA)  # ping, pong


class VmSocket:
    """One WebSocket connection to a Dart VM service, speaking JSON-RPC 2.0."""

    def __init__(self, uri):
        u = urlparse(uri)
        self.sock = socket.create_connection((u.hostname, u.port), timeout=SOCKET_TIMEOUT_S)
        self._handshake(u)
        self.next_id = 0

    def _handshake(self, u):
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f"GET {u.path} HTTP/1.1\r\nHost: {u.hostname}:{u.port}\r\n"
               "Upgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(1)
            if not chunk:
                break
            head += chunk
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise SystemExit(f"handshake failed: {head[:80]!r}")

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise SystemExit("socket closed")
            buf += chunk
        return buf

    def send(self, text):
        data = text.encode()
        mask = os.urandom(4)
        n = len(data)
        if n < 126:
            hdr = struct.pack("!BB", TEXT_FINAL_FRAME, MASK_BIT | n)
        elif n < 65536:
            hdr = struct.pack("!BBH", TEXT_FINAL_FRAME, MASK_BIT | 126, n)
        else:
            hdr = struct.pack("!BBQ", TEXT_FINAL_FRAME, MASK_BIT | 127, n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(hdr + mask + masked)

    def close(self):
        self.sock.close()

    def _recv_frame(self):
        b0, b1 = self._recv_exact(2)
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack("!H", self._recv_exact(2))[0]
        elif n == 127:
            n = struct.unpack("!Q", self._recv_exact(8))[0]
        return b0, self._recv_exact(n)

    def recv(self):
        """The next text message; pings and pongs are skipped, a close ends the run."""
        message = b""
        while True:
            b0, payload = self._recv_frame()
            opcode = b0 & OPCODE_BITS
            if opcode == OPCODE_CLOSE:
                raise SystemExit("socket closed")
            if opcode in CONTROL_OPCODES:
                continue
            message += payload
            if b0 & FIN_BIT:
                return message.decode()

    def call(self, method, params=None):
        self.next_id += 1
        rid = str(self.next_id)
        self.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method,
                              "params": params or {}}))
        while True:
            msg = json.loads(self.recv())
            if msg.get("id") != rid:
                continue
            if "error" in msg:
                raise SystemExit(f"{method}: {str(msg['error'])[:300]}")
            return msg["result"]


def find_widgets(node, name):
    """Every summary-tree node whose description starts with name, outermost first."""
    hits = [node] if node.get("description", "").startswith(name) else []
    for child in node.get("children") or []:
        hits.extend(find_widgets(child, name))
    return hits


def inspector_isolate(ws):
    for iso in ws.call("getVM")["isolates"]:
        info = ws.call("getIsolate", {"isolateId": iso["id"]})
        if SCREENSHOT_EXTENSION in info.get("extensionRPCs", []):
            return iso["id"]
    raise SystemExit("no isolate exposes the inspector screenshot extension (a release build?)")


def shoot(uri, out, widget, width, height):
    ws = VmSocket(uri)
    try:
        _shoot_over(ws, out, widget, width, height)
    finally:
        ws.close()


def _shoot_over(ws, out, widget, width, height):
    iid = inspector_isolate(ws)
    tree = ws.call(TREE_EXTENSION, {
        "isolateId": iid, "groupName": OBJECT_GROUP, "isSummaryTree": "true",
        "withPreviews": "false"})["result"]
    found = find_widgets(tree, widget)
    if not found:
        raise SystemExit(f"no {widget} in the summary tree")
    shot = ws.call(SCREENSHOT_EXTENSION, {
        "isolateId": iid, "id": found[-1]["valueId"], "width": str(width),
        "height": str(height), "margin": "0", "maxPixelRatio": MAX_PIXEL_RATIO,
        "debugPaint": "false"})["result"]
    if not shot:
        raise SystemExit("inspector returned no image")
    with open(out, "wb") as f:
        f.write(base64.b64decode(shot))


def main(argv):
    if len(argv) not in (4, 6):
        raise SystemExit("usage: feanor-vm-shot.py <ws-uri> <out.png> <Widget> [<width> <height>]")
    size = (float(argv[4]), float(argv[5])) if len(argv) == 6 else (DEFAULT_SIZE, DEFAULT_SIZE)
    shoot(argv[1], argv[2], argv[3], *size)
    print(argv[2])


if __name__ == "__main__":
    main(sys.argv)
