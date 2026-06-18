"""Flatten Atlassian Document Format (ADF) JSON to plain markdown-ish text.

Shared by the Jira-fetching hooks (council-jira-fetch.sh, working-jira-ticket.sh).
Import it from an inline hook script with the hooks dir on PYTHONPATH:

    PYTHONPATH="$(dirname "$0")" python - "$file" <<'PY'
    from jira_adf import adf_to_text
    ...
    PY
"""


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
