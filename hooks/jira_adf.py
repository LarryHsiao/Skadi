"""Convert between Atlassian Document Format (ADF) JSON and markdown.

adf_to_text flattens ADF to markdown-ish text for the Jira-fetching hooks
(council-jira-fetch.sh, working-jira-ticket.sh). md_to_adf builds ADF from the
markdown subset scribe.sh renders: headings, paragraphs, nested bullet lists,
`- [ ]` checklists, links, bold and inline code. Anything else passes through
as paragraph text. Import it from an inline hook script with the hooks dir on
PYTHONPATH:

    PYTHONPATH="$(dirname "$0")" python - "$file" <<'PY'
    from jira_adf import adf_to_text
    ...
    PY
"""

import re

_HEADING = re.compile(r"^(#{1,6}) (.*)$")
_BULLET = re.compile(r"^( *)[-*] (.*)$")
_INLINE = re.compile(r"(!?)\[([^\]]*)\]\(([^)\s]+)\)|\*\*([^*]+)\*\*|`([^`]+)`")
# Jira rejects or mis-renders link marks whose href is not an absolute web address.
_WEB_HREF = re.compile(r"^https?://")
# Jira descriptions have no dependable task-list node, so a checkbox becomes a glyph.
_CHECKBOXES = {"[ ] ": "☐ ", "[x] ": "☑ ", "[X] ": "☑ "}


def walk(node, out):
    if isinstance(node, list):
        for x in node:
            walk(x, out)
        return
    if not isinstance(node, dict):
        return
    t = node.get("type")
    if t == "text":
        out.append(node.get("text", ""))
    elif t == "hardBreak":
        out.append("\n")
    elif t == "paragraph":
        walk(node.get("content", []), out)
        out.append("\n\n")
    elif t == "heading":
        lvl = (node.get("attrs") or {}).get("level", 1)
        out.append("#" * lvl + " ")
        walk(node.get("content", []), out)
        out.append("\n\n")
    elif t == "bulletList":
        for item in node.get("content", []):
            out.append("- ")
            walk(item.get("content", []), out)
            if not out or not out[-1].endswith("\n"):
                out.append("\n")
        out.append("\n")
    elif t == "orderedList":
        for i, item in enumerate(node.get("content", []), 1):
            out.append(f"{i}. ")
            walk(item.get("content", []), out)
            if not out or not out[-1].endswith("\n"):
                out.append("\n")
        out.append("\n")
    elif t == "codeBlock":
        out.append("```\n")
        walk(node.get("content", []), out)
        out.append("\n```\n\n")
    elif t == "rule":
        out.append("\n---\n\n")
    elif t == "blockquote":
        out.append("> ")
        walk(node.get("content", []), out)
        out.append("\n\n")
    else:
        walk(node.get("content", []), out)


def adf_to_text(adf):
    if adf is None:
        return ""
    if isinstance(adf, str):
        return adf
    parts = []
    walk(adf, parts)
    return "".join(parts).strip()


def md_to_adf(markdown):
    """Build an ADF doc from markdown; see the module docstring for the subset."""
    return {"type": "doc", "version": 1, "content": _blocks(markdown.split("\n"))}


def _blocks(lines):
    content, pending = [], []
    i = 0
    while i < len(lines):
        line = lines[i]
        heading = _HEADING.match(line)
        if not line.strip() or heading or _BULLET.match(line):
            _flush_paragraph(pending, content)
        if heading:
            level = len(heading.group(1))
            content.append({"type": "heading", "attrs": {"level": level},
                            "content": _inline(heading.group(2))})
        elif _BULLET.match(line):
            bullet_list, i = _bullet_list(lines, i)
            content.append(bullet_list)
            continue
        elif line.strip():
            pending.append(line)
        i += 1
    _flush_paragraph(pending, content)
    return content


def _flush_paragraph(pending, content):
    if pending:
        content.append(_paragraph(pending))
        pending.clear()


def _bullet_list(lines, i):
    """Collect the list starting at lines[i]; deeper bullets nest in the item above."""
    indent = len(_BULLET.match(lines[i]).group(1))
    items = []
    while i < len(lines):
        bullet = _BULLET.match(lines[i])
        if not bullet or len(bullet.group(1)) < indent:
            break
        if len(bullet.group(1)) > indent and items:
            nested, i = _bullet_list(lines, i)
            items[-1]["content"].append(nested)
            continue
        items.append({"type": "listItem",
                      "content": [_paragraph([_checkbox(bullet.group(2))])]})
        i += 1
    return {"type": "bulletList", "content": items}, i


def _checkbox(text):
    for box, glyph in _CHECKBOXES.items():
        if text.startswith(box):
            return glyph + text[len(box):]
    return text


def _paragraph(lines):
    nodes = []
    for n, line in enumerate(lines):
        if n > 0:
            nodes.append({"type": "hardBreak"})
        nodes.extend(_inline(line))
    return {"type": "paragraph", "content": nodes}


def _inline(text):
    nodes, cursor = [], 0
    for match in _INLINE.finditer(text):
        if match.start() > cursor:
            nodes.append({"type": "text", "text": text[cursor:match.start()]})
        nodes.append(_marked(match))
        cursor = match.end()
    if cursor < len(text):
        nodes.append({"type": "text", "text": text[cursor:]})
    return nodes


def _marked(match):
    bang, label, href, bold, code = match.groups()
    if href is not None:
        return _link(label or href, href, is_image=bool(bang))
    if bold is not None:
        return {"type": "text", "text": bold, "marks": [{"type": "strong"}]}
    return {"type": "text", "text": code, "marks": [{"type": "code"}]}


def _link(label, href, is_image):
    """A web href becomes a link mark; anything else stays readable plain text.

    ADF has no inline image a description can reference by URL, so an image
    keeps only its alt text (and its link, when the source is on the web).
    """
    if _WEB_HREF.match(href):
        return {"type": "text", "text": label,
                "marks": [{"type": "link", "attrs": {"href": href}}]}
    if is_image:
        return {"type": "text", "text": label}
    return {"type": "text", "text": f"{label} ({href})"}
