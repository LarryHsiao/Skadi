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
    def test_empty_thread_drafts_plan(self):
        expected = "draft_plan"
        self.assertEqual(decide({"comments": []})["action"], expected)

    def test_plan_present_awaits(self):
        expected = "await_plan"
        data = {"comments": [bot("[PLAN]\n<!-- consumed: 0 -->\nthe plan", 100, "c1")]}
        self.assertEqual(decide(data)["action"], expected)

    def test_instruction_after_plan_redrafts(self):
        expected = "redraft_plan"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nthe plan", 100, "c1"),
            human("use a service class", 200)]}
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

    def test_instruction_after_skeleton_redrafts(self):
        expected = "redraft_skeleton"
        data = {"comments": [
            bot("[PLAN]\n<!-- consumed: 100 -->\nplan", 100, "c1"),
            human("[FORTH]", 200),
            bot("[SKELETON]\n<!-- consumed: 200 -->\nstubs", 300, "c2"),
            human("split the test file", 400)]}
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

if __name__ == "__main__":
    unittest.main()
