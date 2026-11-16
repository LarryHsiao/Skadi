"""Refuse a comment, PR or ticket body that grades a person's conduct.

Usage: python -I register-check.py <body-file> [label]
  exit 0  the body may be posted
  exit 1  a conduct-grading word stands in the body's own prose; prints the
          JSON error the posting hooks emit, naming each word and its sentence

Posting hooks run this on the body file once it is read (after
body-to-utf8.sh, where the hook normalises) and before any network call. They
call it through `python -I`, the interpreter body-to-utf8.sh already asks for.

A post is read by other people and cannot be unsaid, so here the Register rule
(output-styles/tolkien-narrator.md, "describe the thing, not the person") is
enforced rather than counted. The words and the reading of what is quoted or
shown are register-scan.py's own, loaded from beside this file, so the check
and the counter cannot drift apart.

There is no override. A word that is being quoted goes in quotation marks or a
code span, which the reading skips; anything else is reworded.

Fails open: a body that cannot be read or is not UTF-8, or a register-scan.py
that cannot be loaded, lets the post through with one line on stderr. A broken
check must not stop a post. A call with no file is a wiring fault and exits 1.

Platforms: macOS, Linux, Windows (Python 3, standard library only). Tested on
macOS; on Windows run `bash hooks/register-check.test.sh` from Git Bash.
"""

import importlib.util
import json
import sys
from pathlib import Path

SCAN = Path(__file__).resolve().parent / "register-scan.py"
DEFAULT_LABEL = "comment"
USAGE = "usage: register-check.py <body-file> [label]"
REFUSAL = (
    "{label} body grades a person's conduct: {hits}. Describe the thing, not "
    "the person, then post again. Text you are quoting belongs in quotation "
    "marks or a code span."
)


def load_scan():
    spec = importlib.util.spec_from_file_location("register_scan", SCAN)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def grading(body_file):
    """(word, snippet) for each grading word in the body's own prose."""
    scan = load_scan()
    body = Path(body_file).read_bytes().decode("utf-8")
    return scan.hits(scan.own_prose(body))


def refuse(message):
    print(json.dumps({"error": message}, ensure_ascii=False))
    return 1


def main(args):
    if not args:
        return refuse(USAGE)
    label = args[1] if len(args) > 1 else DEFAULT_LABEL
    try:
        found = grading(args[0])
    except Exception as trouble:  # fail open: see the module docstring
        print("register-check: skipped (%s)" % trouble, file=sys.stderr)
        return 0
    if not found:
        return 0
    hits = "; ".join("「%s」 in 「%s」" % hit for hit in found)
    return refuse(REFUSAL.format(label=label, hits=hits))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
