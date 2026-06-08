#!/usr/bin/env python3
"""Derive the loop's next action for a skeleton-stage YouTrack issue.

Reads the council-youtrack-fetch.sh JSON on stdin (comments must carry
id, login, text, created) and prints one line:

    action=<...> plan_id=<id|-> skeleton_id=<id|->

The thread is the record: which living comments exist (their first-line token),
and where the latest [FORTH] sits relative to each comment's watermark, decide it.
See docs/superpowers/specs/2026-06-08-skeleton-stage-design.md.
"""
import sys, json, re

BOT_LOGIN = "claude"  # service-account login; matches council's bot-login config
WATERMARK = re.compile(r"<!--\s*consumed:\s*(\d+)\s*-->")
VERDICT = ("[FORTH]", "[APPROVE]")


def _token(text):
    body = (text or "").strip()
    if not body:
        return ""
    head = body.splitlines()[0].strip().upper()
    for tok in ("[PLAN]", "[SKELETON]", "[GWAITH]"):
        if head.startswith(tok):
            return tok
    return ""


def _watermark(text):
    m = WATERMARK.search(text or "")
    return int(m.group(1)) if m else 0


def _is_forth(text):
    up = (text or "").upper()
    return any(v in up for v in VERDICT)


def decide(data):
    comments = data.get("comments", [])
    plan = skeleton = gwaith = None
    for c in comments:
        if c.get("login") != BOT_LOGIN:
            continue
        tok = _token(c.get("text", ""))
        if tok == "[PLAN]":
            plan = c
        elif tok == "[SKELETON]":
            skeleton = c
        elif tok == "[GWAITH]":
            gwaith = c

    humans = [c for c in comments if c.get("login") != BOT_LOGIN]
    forths = [c for c in humans if _is_forth(c.get("text", ""))]
    newest_human = max((c.get("created", 0) for c in humans), default=0)
    newest_forth = max((c.get("created", 0) for c in forths), default=0)

    plan_id = plan.get("id") if plan else "-"
    skel_id = skeleton.get("id") if skeleton else "-"

    def out(action):
        return {"action": action, "plan_id": plan_id, "skeleton_id": skel_id}

    if gwaith:
        return out("done")
    if skeleton:
        wm = _watermark(skeleton.get("text", ""))
        if newest_forth > wm:
            return out("forge")
        if newest_human > wm:
            return out("redraft_skeleton")
        return out("await_skeleton")
    if plan:
        wm = _watermark(plan.get("text", ""))
        if newest_forth > wm:
            return out("draft_skeleton")
        if newest_human > wm:
            return out("redraft_plan")
        return out("await_plan")
    return out("draft_plan")


def main():
    data = json.load(sys.stdin)
    r = decide(data)
    print(f"action={r['action']} plan_id={r['plan_id']} skeleton_id={r['skeleton_id']}")


if __name__ == "__main__":
    main()
