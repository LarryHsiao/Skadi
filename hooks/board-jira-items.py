#!/usr/bin/env python3
"""board-jira-items.py — shape `halbarad-jira.sh window` JSON for the board's Jira row.

Reads the window brief on stdin and prints one JSON object:

    {"count": N, "detail": "1 mention · 1 reassigned · 4 moved", "items": [...]}

`count` is every ticket in the window; `items` is the top five, ranked mention or
reopened first, then reassigned to the user, then the rest (each tier keeps the
brief's newest-first order). An item is {key, summary, url, why, tone}: `why` names
the strongest reason and who caused it, `tone` is "alert", "assigned" or "moved"
for the page to colour. A non-"ok" brief, or input that is not a brief, exits 1 so
the caller writes an honest "unknown" rather than a false zero.

Platforms: macOS and Windows (Git Bash) — Python 3 standard library only.
"""
import json
import sys

TOP = 5
KINDS = ("mention", "reopened", "reassigned", "moved")
# mention and reopened share the first tier; sorted() is stable, so each tier
# keeps the brief's newest-first order.
TIER = {"mention": 0, "reopened": 0, "reassigned": 1, "moved": 2}


def latest(events):
    return max(events, key=lambda event: event["at"])


def classify(ticket):
    """(kind, why, tone) for one ticket — the strongest reason wins."""
    if ticket["mentions"]:
        return "mention", f"mention · {latest(ticket['mentions'])['who']}", "alert"
    if ticket["reopened"]:
        reopeners = [c for c in ticket["changes"] if c.get("reopened")]
        return "reopened", f"reopened · {latest(reopeners)['who']}", "alert"
    if ticket["reassigned_to_me"]:
        to_me = [c for c in ticket["changes"] if c.get("to_me")]
        return "reassigned", f"assigned to you · {latest(to_me)['who']}", "assigned"
    last = latest(ticket["changes"])
    return "moved", f"{last['kind']} · {last['who']}", "moved"


def detail_line(kinds):
    parts = []
    for kind in KINDS:
        n = kinds.count(kind)
        if n:
            parts.append(f"{n} mentions" if kind == "mention" and n > 1 else f"{n} {kind}")
    return " · ".join(parts) or "—"


def shape(brief):
    ranked = []
    for ticket in brief["tickets"]:
        kind, why, tone = classify(ticket)
        item = {"key": ticket["key"], "summary": ticket["summary"],
                "url": ticket.get("url") or None, "why": why, "tone": tone}
        ranked.append((kind, item))
    ranked.sort(key=lambda row: TIER[row[0]])
    return {"count": len(ranked),
            "detail": detail_line([kind for kind, _ in ranked]),
            "items": [item for _, item in ranked[:TOP]]}


def main():
    try:
        brief = json.load(sys.stdin)
        if brief.get("status") != "ok":
            return 1
        shaped = shape(brief)
    except (ValueError, KeyError, TypeError, AttributeError):
        return 1
    print(json.dumps(shaped, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
