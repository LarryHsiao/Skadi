#!/usr/bin/env python3
"""Council plan preview — Henneth HTML mirror + diagram/wireframe extraction.

Usage:
  council-plan-html.py detect                          < markdown on stdin
  council-plan-html.py render-plan <ticket-id> <out>    < markdown on stdin
  council-plan-html.py render-diagram <ticket-id> <out> < diagram body on stdin
  council-plan-html.py replace <replacement-file>       < markdown on stdin, writes stdout

`detect` prints "FOUND tag=<diagram|wireframe>" followed by the raw block
body and exits 0, or prints "NONE" and exits 1 if no block is present.
`replace` splices the contents of <replacement-file> in place of the first
diagram/wireframe fence and writes the result to stdout.
"""

import html
import re
import sys

_FENCE_RE = re.compile(r"```(diagram|wireframe)\n(.*?)\n```", re.DOTALL)


def find_diagram_block(markdown_text):
    match = _FENCE_RE.search(markdown_text)
    if not match:
        return None
    return {
        "tag": match.group(1),
        "body": match.group(2),
        "start": match.start(),
        "end": match.end(),
    }


def replace_diagram_block(markdown_text, replacement_text):
    block = find_diagram_block(markdown_text)
    if block is None:
        raise ValueError("no diagram/wireframe block found")
    return markdown_text[: block["start"]] + replacement_text + markdown_text[block["end"] :]
