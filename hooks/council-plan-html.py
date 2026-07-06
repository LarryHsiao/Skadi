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


PLAN_TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Plan Preview — {ticket_id}</title>
<link rel="stylesheet" href="skadi-theme.css">
<style>
  main {{ max-width: 900px; margin: 0 auto; padding: 2rem 1.5rem 4rem; }}
  pre.plan {{ white-space: pre-wrap; font-family: "Iowan Old Style", Georgia, serif; font-size: 1rem; line-height: 1.6; }}
</style>
</head>
<body>
<main>
  <h1>Plan Preview — {ticket_id}</h1>
  <div class="panel full"><pre class="plan">{body}</pre></div>
</main>
</body>
</html>
"""

DIAGRAM_TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Diagram — {ticket_id}</title>
<link rel="stylesheet" href="skadi-theme.css">
</head>
<body>
<main style="max-width: 700px; margin: 2rem auto;">
  <div class="prec">{body}</div>
</main>
</body>
</html>
"""


def render_plan_html(markdown_text, ticket_id):
    return PLAN_TEMPLATE.format(ticket_id=html.escape(ticket_id), body=html.escape(markdown_text))


def render_diagram_html(diagram_body, ticket_id):
    return DIAGRAM_TEMPLATE.format(ticket_id=html.escape(ticket_id), body=html.escape(diagram_body))


def _cmd_detect():
    text = sys.stdin.read()
    block = find_diagram_block(text)
    if block is None:
        print("NONE")
        return 1
    print(f"FOUND tag={block['tag']}")
    sys.stdout.write(block["body"])
    return 0


def _cmd_render_plan(ticket_id, out_path):
    text = sys.stdin.read()
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(render_plan_html(text, ticket_id))
    return 0


def _cmd_render_diagram(ticket_id, out_path):
    text = sys.stdin.read()
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(render_diagram_html(text, ticket_id))
    return 0


def _cmd_replace(replacement_file):
    text = sys.stdin.read()
    with open(replacement_file, "r", encoding="utf-8") as f:
        replacement = f.read()
    sys.stdout.write(replace_diagram_block(text, replacement))
    return 0


def main(argv):
    if not argv:
        print('{"error":"usage: council-plan-html.py <detect|render-plan|render-diagram|replace> [args...]"}')
        return 1
    cmd = argv[0]
    try:
        if cmd == "detect":
            return _cmd_detect()
        if cmd == "render-plan":
            return _cmd_render_plan(argv[1], argv[2])
        if cmd == "render-diagram":
            return _cmd_render_diagram(argv[1], argv[2])
        if cmd == "replace":
            return _cmd_replace(argv[1])
    except (IndexError, ValueError) as exc:
        print(f'{{"error":"{exc}"}}')
        return 1
    print(f'{{"error":"unknown command: {cmd}"}}')
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
