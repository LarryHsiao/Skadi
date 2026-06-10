#!/usr/bin/env python3
"""Derive the loop's next action for a skeleton-stage YouTrack issue.

Reads the council-youtrack-fetch.sh JSON on stdin (comments must carry
id, login, text, created) and prints one line:

    action=<...> plan_id=<id|-> skeleton_id=<id|->

The thread is the record: which living comments exist (their first-line token),
and where the latest [FORTH] sits relative to each comment's watermark, decide it.
A bot [METTA] (closed on merge) is the terminal mark — its presence yields
`at_rest`, distinct from `done` (forged, not yet closed), so Aulë's close-on-merge
sweep never re-closes a ticket already laid to rest.
See docs/superpowers/specs/2026-06-08-skeleton-stage-design.md.
"""
import sys, json, re

BOT_LOGIN = "claude"  # service-account login; matches council's bot-login config
WATERMARK = re.compile(r"<!--\s*consumed:\s*(\d+)\s*-->")
VERDICT = ("[FORTH]", "[APPROVE]")
SUMMONS = ("[MELLON]", "[FRIEND]")
ALTER = ("[ENVINYA]", "[ALTER]")
# [CEIST]/[ASK] bears no constant: a question behaves as bare prose — it answers,
# never redrafts — so the answer branch (any fresh human comment) already covers it.


def _token(text):
    body = (text or "").strip()
    if not body:
        return ""
    head = body.splitlines()[0].strip().upper()
    for tok in ("[PLAN]", "[SKELETON]", "[GWAITH]", "[METTA]"):
        if head.startswith(tok):
            return tok
    return ""


def _watermark(text):
    m = WATERMARK.search(text or "")
    return int(m.group(1)) if m else 0


def _is_forth(text):
    up = (text or "").upper()
    return any(v in up for v in VERDICT)


def _is_mellon(text):
    up = (text or "").upper()
    return any(s in up for s in SUMMONS)


def _is_alter(text):
    up = (text or "").upper()
    return any(a in up for a in ALTER)


def decide(data):
    comments = data.get("comments", [])
    plan = skeleton = gwaith = metta = None
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
        elif tok == "[METTA]":
            metta = c

    humans = [c for c in comments if c.get("login") != BOT_LOGIN]
    forths = [c for c in humans if _is_forth(c.get("text", ""))]
    alters = [c for c in humans if _is_alter(c.get("text", ""))]
    newest_human = max((c.get("created", 0) for c in humans), default=0)
    newest_forth = max((c.get("created", 0) for c in forths), default=0)
    newest_alter = max((c.get("created", 0) for c in alters), default=0)

    plan_id = plan.get("id") if plan else "-"
    skel_id = skeleton.get("id") if skeleton else "-"

    def out(action):
        return {"action": action, "plan_id": plan_id, "skeleton_id": skel_id}

    if metta:
        return out("at_rest")
    if gwaith:
        return out("done")
    if skeleton:
        wm = _watermark(skeleton.get("text", ""))
        if newest_forth > wm:
            return out("forge")
        if newest_alter > wm:
            return out("redraft_skeleton")
        if newest_human > wm:
            return out("answer_skeleton")
        return out("await_skeleton")
    if plan:
        wm = _watermark(plan.get("text", ""))
        if newest_forth > wm:
            return out("draft_skeleton")
        if newest_alter > wm:
            return out("redraft_plan")
        if newest_human > wm:
            return out("answer_plan")
        return out("await_plan")
    has_mellon = any(_is_mellon(c.get("text", "")) for c in humans)
    return out("draft_plan") if has_mellon else out("await_start")


def main():
    data = json.load(sys.stdin)
    r = decide(data)
    print(f"action={r['action']} plan_id={r['plan_id']} skeleton_id={r['skeleton_id']}")


if __name__ == "__main__":
    main()
