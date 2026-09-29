import json, subprocess, sys, unittest
from pathlib import Path
import importlib.util

HOOK = Path(__file__).resolve().parents[1] / "hooks" / "jira-skeleton-rung.py"
spec = importlib.util.spec_from_file_location("jira_skeleton_rung", HOOK)
jira_skeleton_rung = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jira_skeleton_rung)
decide = jira_skeleton_rung.decide

# On Jira the bot posts as the human (shared identity): only the first-line token tells them apart.
ME = "elrond@example.test"

def say(text, created, cid=None):
    return {"login": ME, "text": text, "created": created, "id": cid or f"c{created}"}

COUNSEL = say("[COUNSEL v1]\nthe plan", 100, "counsel")
PLAN_FORTH = say("[FORTH]", 200)
SKELETON = say("[SKELETON] — awaiting [FORTH]\n\ntree + stubs", 300, "skel")

def action(*comments):
    return decide({"comments": list(comments)})["action"]


class JiraSkeletonRungTest(unittest.TestCase):
    def test_no_counsel_has_no_plan(self):
        expected = "no_plan"
        self.assertEqual(expected, action(say("please build this", 50)))

    def test_counsel_without_verdict_awaits_the_plan(self):
        expected = "await_plan"
        self.assertEqual(expected, action(COUNSEL))

    def test_forth_after_counsel_approves_the_plan(self):
        expected = "plan_approved"
        self.assertEqual(expected, action(COUNSEL, PLAN_FORTH))

    def test_approve_alias_approves_the_plan(self):
        expected = "plan_approved"
        self.assertEqual(expected, action(COUNSEL, say("looks right [APPROVE]", 200)))

    def test_forth_before_a_newer_counsel_does_not_approve_it(self):
        expected = "await_plan"
        self.assertEqual(expected, action(COUNSEL, PLAN_FORTH, say("[COUNSEL v2]\nnew plan", 250, "counsel2")))

    def test_the_plan_forth_does_not_approve_the_skeleton(self):
        expected = "await_skeleton"
        self.assertEqual(expected, action(COUNSEL, PLAN_FORTH, SKELETON))

    def test_forth_after_skeleton_forges(self):
        expected = "forge"
        self.assertEqual(expected, action(COUNSEL, PLAN_FORTH, SKELETON, say("[FORTH]", 400)))

    def test_envinya_after_skeleton_redrafts_it(self):
        expected = "redraft_skeleton"
        self.assertEqual(expected, action(COUNSEL, PLAN_FORTH, SKELETON, say("[ENVINYA] split the repo", 400)))

    def test_forth_beats_alter_after_skeleton(self):
        expected = "forge"
        self.assertEqual(expected, action(COUNSEL, PLAN_FORTH, SKELETON,
                                          say("[ALTER] rename it", 400), say("[FORTH]", 410)))

    def test_prose_after_skeleton_is_answered(self):
        expected = "answer_skeleton"
        self.assertEqual(expected, action(COUNSEL, PLAN_FORTH, SKELETON, say("why two services?", 400)))

    def test_bot_answer_consumes_the_question(self):
        expected = "await_skeleton"
        self.assertEqual(expected, action(COUNSEL, PLAN_FORTH, SKELETON, say("why two services?", 400),
                                          say("[PEDO] one per seam", 410)))

    def test_renewal_notice_consumes_the_alter(self):
        expected = "await_skeleton"
        self.assertEqual(expected, action(COUNSEL, PLAN_FORTH, SKELETON, say("[ENVINYA] split it", 400),
                                          say("[VINYA] The skeleton is renewed", 410)))

    def test_gwaith_is_done(self):
        expected = "done"
        self.assertEqual(expected, action(COUNSEL, PLAN_FORTH, SKELETON, say("[FORTH]", 400),
                                          say("[GWAITH] https://x.test/pr/1", 500)))

    def test_metta_is_at_rest(self):
        expected = "at_rest"
        self.assertEqual(expected, action(COUNSEL, PLAN_FORTH, say("[GWAITH] pr", 500), say("[METTA] merged", 600)))

    def test_cli_prints_action_and_ids(self):
        expected = "action=forge counsel_id=counsel skeleton_id=skel"
        thread = {"comments": [COUNSEL, PLAN_FORTH, SKELETON, say("[FORTH]", 400)]}
        run = subprocess.run([sys.executable, str(HOOK)], input=json.dumps(thread),
                             capture_output=True, text=True, check=True)
        self.assertEqual(expected, run.stdout.strip())


if __name__ == "__main__":
    unittest.main()
