#!/usr/bin/env python3
"""orthanc-copy.py <name>   (the block to copy arrives on stdin)

Writes a block the user will copy by hand to a file, then prints the marker line
Orthanc (the terminal app) turns into a clickable link. A click puts the file's
exact text on the clipboard, with none of the gutter or hard wraps that dragging
across drawn output picks up. Outside Orthanc the marker is one harmless line.

Contract (Orthanc's lib/copy_marker.dart):
  - <name> matches ^[A-Za-z0-9][A-Za-z0-9._-]*$ and is not a Windows device
    name (CON PRN AUX NUL COM1-9 LPT1-9), with or without an extension. It is
    the file's FULL name, extension included: block-1.sh, not block-1.
  - The file lives in <system temp>/orthanc-copy/. Python's gettempdir() agrees
    with Dart's Directory.systemTemp on both platforms: %TEMP% on Windows and
    $TMPDIR (a /var/folders/... path) on macOS — never a hard-coded /tmp.
  - The marker is `⧉ copy:<name>` on its own line, printed AFTER the file is
    written: a click on a marker whose file is missing does nothing, silently.
  - The file holds the block exactly as pasted — no fences, no gutter.

Print the marker on the line above the block in the reply; reuse names like
block-1.sh and overwrite freely.

Test seam: ORTHANC_COPY_DIR replaces the folder.
Exit status: 0 written, 2 usage error or an invalid name (nothing written).
Platforms: Windows (Git Bash, PowerShell) and macOS; standard library only.
"""
import os
import re
import sys
import tempfile
from pathlib import Path

FOLDER = "orthanc-copy"
NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
DEVICE_NAME = re.compile(r"^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$", re.IGNORECASE)
USAGE_ERROR = 2


def valid_name(name):
    return bool(NAME_PATTERN.match(name)) and not DEVICE_NAME.match(name)


def copy_dir():
    override = os.environ.get("ORTHANC_COPY_DIR")
    return Path(override) if override else Path(tempfile.gettempdir()) / FOLDER


def write_block(name, data, directory):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / name).write_bytes(data)


def marker(name):
    return "⧉ copy:" + name


def run(name, data, directory, out):
    if not valid_name(name):
        sys.stderr.write("orthanc-copy: %r is not a usable file name\n" % name)
        return USAGE_ERROR
    write_block(name, data, directory)
    out.write((marker(name) + "\n").encode("utf-8"))
    return 0


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: orthanc-copy.py <name>   (block on stdin)\n")
        return USAGE_ERROR
    # Bytes in and out: text mode would translate newlines, and a Windows
    # console's default encoding cannot print the marker's glyph.
    code = run(sys.argv[1], sys.stdin.buffer.read(), copy_dir(), sys.stdout.buffer)
    sys.stdout.buffer.flush()
    return code


if __name__ == "__main__":
    sys.exit(main())
