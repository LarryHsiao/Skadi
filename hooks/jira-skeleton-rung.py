#!/usr/bin/env python3
"""Derive the next action for a Jira ticket on the skeleton road.

Reads the council-jira-fetch.sh JSON on stdin and prints one line:

    action=<...> counsel_id=<id|-> skeleton_id=<id|->

Jira is shared-identity: the bot posts as the human, so a comment is the bot's
only when its first line opens with a bot token (the same rule /council's Jira
path uses). Jira comments carry no watermark either — a `<!-- consumed -->`
line would render as visible text — so freshness is measured from the bot's
last word instead: a human comment counts only when it follows the latest bot
comment on the rung in question.

The skeleton rung is opt-in on Jira. `plan_approved` with no [SKELETON] forges
as it always has; once a [SKELETON] exists, only a [FORTH] after it forges.

Actions: no_plan, await_plan, plan_approved, await_skeleton, answer_skeleton,
redraft_skeleton, forge, done, at_rest.
"""
import json
import re
import sys

BOT_HEAD = re.compile(
    r"^\[(COUNSEL v\d+|PLAN v\d+|PARLEY|AGENT-ASK|PEDO|ANSWER|VINYA|RENEWED|ENWINA|STALE"
    r"|DOOM|VERDICT|GWAITH|FORGED|SHIPPED|SKELETON|METTA)\]",
    re.IGNORECASE)
COUNSEL_HEAD = re.compile(r"^\[(COUNSEL|PLAN) v\d+\]", re.IGNORECASE)
GWAITH_HEAD = re.compile(r"^\[(GWAITH|FORGED|SHIPPED)\]", re.IGNORECASE)
SKELETON_HEAD = re.compile(r"^\[SKELETON\]", re.IGNORECASE)
METTA_HEAD = re.compile(r"^\[METTA\]", re.IGNORECASE)
VERDICT = ("[FORTH]", "[APPROVE]")
ALTER = ("[ENVINYA]", "[ALTER]")


def _head(comment):
    lines = (comment.get("text") or "").strip().splitlines()
    return lines[0].strip() if lines else ""


def _created(comment):
    return comment.get("created", 0)


def _is_bot(comment):
    return bool(BOT_HEAD.match(_head(comment)))


def _has(comment, tokens):
    body = (comment.get("text") or "").upper()
    return any(t in body for t in tokens)


def _latest(comments, pattern):
    matches = [c for c in comments if _is_bot(c) and pattern.match(_head(c))]
    return max(matches, key=_created, default=None)


def _fresh_humans(comments, since):
    """Human comments after the bot's last word at or after `since`."""
    last_bot = max((_created(c) for c in comments
                    if _is_bot(c) and _created(c) >= since), default=since)
    return [c for c in comments if not _is_bot(c) and _created(c) > last_bot]


def _skeleton_action(comments, skeleton):
    fresh = _fresh_humans(comments, _created(skeleton))
    if any(_has(c, VERDICT) for c in fresh):
        return "forge"
    if any(_has(c, ALTER) for c in fresh):
        return "redraft_skeleton"
    return "answer_skeleton" if fresh else "await_skeleton"


def decide(data):
    comments = data.get("comments", [])
    counsel = _latest(comments, COUNSEL_HEAD)
    skeleton = _latest(comments, SKELETON_HEAD)
    ids = {"counsel_id": counsel.get("id") if counsel else "-",
           "skeleton_id": skeleton.get("id") if skeleton else "-"}

    if _latest(comments, METTA_HEAD):
        return {"action": "at_rest", **ids}
    if _latest(comments, GWAITH_HEAD):
        return {"action": "done", **ids}
    if skeleton:
        return {"action": _skeleton_action(comments, skeleton), **ids}
    if not counsel:
        return {"action": "no_plan", **ids}
    approved = any(not _is_bot(c) and _has(c, VERDICT) and _created(c) > _created(counsel)
                   for c in comments)
    return {"action": "plan_approved" if approved else "await_plan", **ids}


def main():
    r = decide(json.load(sys.stdin))
    print(f"action={r['action']} counsel_id={r['counsel_id']} skeleton_id={r['skeleton_id']}")


if __name__ == "__main__":
    main()
