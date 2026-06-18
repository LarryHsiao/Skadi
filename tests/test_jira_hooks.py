"""Offline tests for the Jira council hooks.

`jira-comment-edit.sh` is exercised through its COUNCIL_DRY_RUN path, which builds
the ADF payload without touching the network. `council-jira-fetch.sh` is exercised
through a `curl` stub placed first on PATH, feeding canned Jira REST responses so
the embedded ADF-flatten + comment-map runs for real. Both rely on the env-var
fallback in secret.sh (JIRA_URL / JIRA_USERNAME / JIRA_API_TOKEN).
"""
import json, os, stat, subprocess, tempfile, textwrap, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EDIT_HOOK = ROOT / "hooks" / "jira-comment-edit.sh"
FETCH_HOOK = ROOT / "hooks" / "council-jira-fetch.sh"

JIRA_ENV = {
    "JIRA_URL": "https://jira.example.test",
    "JIRA_USERNAME": "elrond@example.test",
    "JIRA_API_TOKEN": "test-token",
}


def _run(argv, body=None, env_extra=None):
    env = {**os.environ, **JIRA_ENV}
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        ["bash", str(argv[0]), *argv[1:]],
        input=body, capture_output=True, text=True, env=env)


class EditHookDryRunTest(unittest.TestCase):
    """The new edit hook's ADF construction (COUNCIL_DRY_RUN, no network)."""

    def _payload(self, stdout):
        # Dry-run prints a header line, then the one-line JSON payload.
        body = "\n".join(stdout.splitlines()[1:])
        return json.loads(body)

    def _edit(self, body):
        return _run([EDIT_HOOK, "MET-7", "10099"], body=body,
                    env_extra={"COUNCIL_DRY_RUN": "1"})

    def test_doc_shape_is_adf(self):
        expected = {"version": 1, "type": "doc"}
        r = self._edit("hello")
        self.assertEqual(r.returncode, 0, r.stderr)
        doc = self._payload(r.stdout)["body"]
        self.assertEqual(doc["version"], expected["version"])
        self.assertEqual(doc["type"], expected["type"])

    def test_blank_line_splits_paragraphs(self):
        expected_paragraphs = 2
        r = self._edit("[COUNSEL v3] First para.\n\nSecond para.")
        content = self._payload(r.stdout)["body"]["content"]
        self.assertEqual(len(content), expected_paragraphs)

    def test_single_newline_is_hardbreak(self):
        expected_types = ["text", "hardBreak", "text"]
        r = self._edit("line one\nline two")
        nodes = self._payload(r.stdout)["body"]["content"][0]["content"]
        self.assertEqual([n["type"] for n in nodes], expected_types)

    def test_bracket_token_survives(self):
        expected = "[COUNSEL v3] Renewed."
        r = self._edit("[COUNSEL v3] Renewed.")
        text = self._payload(r.stdout)["body"]["content"][0]["content"][0]["text"]
        self.assertEqual(text, expected)

    def test_missing_comment_id_errors(self):
        expected_fragment = "usage"
        r = _run([EDIT_HOOK, "MET-7"], body="hello")  # no comment id
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(expected_fragment, json.loads(r.stdout)["error"])

    def test_empty_body_errors(self):
        expected_fragment = "empty"
        r = self._edit("")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(expected_fragment, json.loads(r.stdout)["error"])


class FetchHookIdTest(unittest.TestCase):
    """council-jira-fetch.sh emits each comment's id (drives edit-in-place)."""

    ISSUE = {"fields": {"summary": "Renew the plan", "description": "do it"}}
    COMMENTS = {"comments": [
        {"id": "10042",
         "author": {"displayName": "Elrond", "emailAddress": "elrond@x.test"},
         "body": "[COUNSEL v1] the plan",
         "created": "2026-06-18T10:00:00.000+0000"},
    ]}

    def _run_with_curl_stub(self):
        with tempfile.TemporaryDirectory() as d:
            stub = Path(d) / "curl"
            stub.write_text(textwrap.dedent(f"""\
                #!/usr/bin/env bash
                # Minimal curl stub: route by URL (the final arg), honor -o <file>.
                out=""; url=""; prev=""
                for a in "$@"; do
                  [[ "$prev" == "-o" ]] && out="$a"
                  url="$a"; prev="$a"
                done
                case "$url" in
                  *"/comment"*) payload='{json.dumps(self.COMMENTS)}' ;;
                  *"/rest/api/3/issue/"*) payload='{json.dumps(self.ISSUE)}' ;;
                  *) echo 200; exit 0 ;;
                esac
                if [[ -n "$out" ]]; then printf '%s' "$payload" > "$out"; fi
                echo 200
            """))
            stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
            env = {**os.environ, **JIRA_ENV, "PATH": f"{d}:{os.environ['PATH']}"}
            return subprocess.run(
                ["bash", str(FETCH_HOOK), "MET-7"],
                capture_output=True, text=True, env=env)

    def test_comment_carries_id(self):
        expected_id = "10042"
        r = self._run_with_curl_stub()
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertEqual(out["comments"][0]["id"], expected_id)

    def test_summary_and_text_survive(self):
        expected_summary = "Renew the plan"
        r = self._run_with_curl_stub()
        out = json.loads(r.stdout)
        self.assertEqual(out["summary"], expected_summary)
        self.assertTrue(out["comments"][0]["text"].startswith("[COUNSEL v1]"))


if __name__ == "__main__":
    unittest.main()
