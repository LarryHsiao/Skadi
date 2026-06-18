import json, subprocess, sys, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "hooks"))
import importlib.util
spec = importlib.util.spec_from_file_location(
    "skeleton_rung", Path(__file__).resolve().parents[1] / "hooks" / "skeleton-rung.py")
skeleton_rung = importlib.util.module_from_spec(spec)
spec.loader.exec_module(skeleton_rung)
decide = skeleton_rung.decide

BOT = "claude"

def human(text, created): return {"login": "elrond", "text": text, "created": created, "id": f"h{created}"}
def bot(text, created, cid): return {"login": BOT, "text": text, "created": created, "id": cid}

class DecideTest(unittest.TestCase):
    def test_empty_thread_awaits_start(self):
        expected = "await_start"
        self.assertEqual(decide({"comments": []})["action"], expected)

    def test_mellon_drafts_plan(self):
        expected = "draft_plan"
        data = {"comments": [human("[MELLON]", 100)]}
        self.assertEqual(decide(data)["action"], expected)

    def test_friend_alias_drafts_plan(self):
        expected = "draft_plan"
        data = {"comments": [human("please look at this [FRIEND]", 100)]}
        self.assertEqual(decide(data)["action"], expected)

    def test_plan_present_awaits(self):
        expected = "await_plan"
        data = {"comments": [bot("[PLAN]\n<!-- consumed: 0 -->\nthe plan", 100, "c1")]}
        self.assertEqual(decide(data)["action"], expected)

    def test_prose_after_plan_answers(self):
        expected = "answer_plan"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nthe plan", 100, "c1"),
            human("why a service class here?", 200)]}
        self.assertEqual(decide(data)["action"], expected)

    def test_ask_after_plan_answers(self):
        expected = "answer_plan"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nthe plan", 100, "c1"),
            human("[ASK] why a service class here?", 200)]}
        self.assertEqual(decide(data)["action"], expected)

    def test_ceist_after_plan_answers(self):
        expected = "answer_plan"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nthe plan", 100, "c1"),
            human("[CEIST] why a service class here?", 200)]}
        self.assertEqual(decide(data)["action"], expected)

    def test_forth_beats_alter_after_plan(self):
        expected = "draft_skeleton"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nthe plan", 100, "c1"),
            human("[ALTER] use a service class", 200),
            human("[FORTH]", 300)]}
        self.assertEqual(decide(data)["action"], expected)

    def test_alter_after_plan_redrafts(self):
        expected = "redraft_plan"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nthe plan", 100, "c1"),
            human("[ALTER] use a service class", 200)]}
        self.assertEqual(decide(data)["action"], expected)

    def test_envinya_alias_after_plan_redrafts(self):
        expected = "redraft_plan"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nthe plan", 100, "c1"),
            human("[ENVINYA] use a service class", 200)]}
        self.assertEqual(decide(data)["action"], expected)

    def test_forth_after_plan_drafts_skeleton(self):
        expected = "draft_skeleton"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nthe plan", 100, "c1"),
            human("[FORTH]", 200)]}
        out = decide(data)
        self.assertEqual(out["action"], expected)
        self.assertEqual(out["plan_id"], "c1")

    def test_skeleton_present_awaits(self):
        expected = "await_skeleton"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nplan", 100, "c1"),
            human("[FORTH]", 200),
            bot("[SKELETON]\n<!-- consumed: 200 -->\nstubs", 300, "c2")]}
        self.assertEqual(decide(data)["action"], expected)

    def test_second_forth_after_skeleton_forges(self):
        expected = "forge"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nplan", 100, "c1"),
            human("[FORTH]", 200),
            bot("[SKELETON]\n<!-- consumed: 200 -->\nstubs", 300, "c2"),
            human("[FORTH]", 400)]}
        out = decide(data)
        self.assertEqual(out["action"], expected)
        self.assertEqual(out["skeleton_id"], "c2")

    def test_prose_after_skeleton_answers(self):
        expected = "answer_skeleton"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nplan", 100, "c1"),
            human("[FORTH]", 200),
            bot("[SKELETON]\n<!-- consumed: 200 -->\nstubs", 300, "c2"),
            human("why split here?", 400)]}
        self.assertEqual(decide(data)["action"], expected)

    def test_alter_after_skeleton_redrafts(self):
        expected = "redraft_skeleton"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nplan", 100, "c1"),
            human("[FORTH]", 200),
            bot("[SKELETON]\n<!-- consumed: 200 -->\nstubs", 300, "c2"),
            human("[ALTER] split the test file", 400)]}
        self.assertEqual(decide(data)["action"], expected)

    def test_forth_beats_alter_after_skeleton(self):
        expected = "forge"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nplan", 100, "c1"),
            human("[FORTH]", 200),
            bot("[SKELETON]\n<!-- consumed: 200 -->\nstubs", 300, "c2"),
            human("[ALTER] tweak", 400),
            human("[FORTH]", 500)]}
        self.assertEqual(decide(data)["action"], expected)

    def test_gwaith_is_done(self):
        expected = "done"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nplan", 100, "c1"),
            human("[FORTH]", 200),
            bot("[SKELETON]\n<!-- consumed: 200 -->\nstubs", 300, "c2"),
            human("[FORTH]", 400),
            bot("[GWAITH] https://pr", 500, "c3")]}
        self.assertEqual(decide(data)["action"], expected)

    def test_metta_is_at_rest(self):
        expected = "at_rest"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nplan", 100, "c1"),
            human("[FORTH]", 200),
            bot("[SKELETON]\n<!-- consumed: 200 -->\nstubs", 300, "c2"),
            human("[FORTH]", 400),
            bot("[GWAITH] https://pr", 500, "c3"),
            bot("[METTA] closed on merge", 600, "c4")]}
        self.assertEqual(decide(data)["action"], expected)

    def test_vinya_notice_after_redraft_is_quiet(self):
        # After an [ALTER], council edits the plan in place (watermark → 200) and
        # appends a [VINYA] notice. The notice is the bot's word, not fresh
        # counsel, so the next ride must read the thread as quiet.
        # Note: the plan's `created` stays at 100 (its original post date — an
        # in-place edit does not advance it); only the watermark moves to 200.
        expected = "await_plan"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 200 -->\nthe renewed plan", 100, "c1"),
            human("[ALTER] use a service class", 200),
            bot("[VINYA] renewed to v2 — see the plan above", 250, "c9")]}
        self.assertEqual(decide(data)["action"], expected)

    def test_vinya_notice_does_not_mask_later_question(self):
        # A [VINYA] notice in the thread must not suppress a genuine human
        # question that lands after it.
        expected = "answer_plan"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nthe plan", 100, "c1"),
            bot("[VINYA] renewed to v2 — see the plan above", 150, "c9"),
            human("why a service class here?", 200)]}
        self.assertEqual(decide(data)["action"], expected)

if __name__ == "__main__":
    unittest.main()
