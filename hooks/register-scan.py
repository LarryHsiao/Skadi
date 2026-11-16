#!/usr/bin/env python3
"""Stop hook: log each conduct-grading word found in the reply just given.

The Register section of output-styles/tolkien-narrator.md asks a reply to
describe the thing, not the person, and lists the words that grade conduct.
Nothing checked that rule. This hook counts the misses so there is evidence to
read before the rule is given a blocking guard (docs/workflow/maintenance.md,
*Escalation ladder*).

It only counts. It prints nothing, so it adds no tokens to the session, and it
always exits 0, so a false hit ("the function should have a test") cannot
interrupt a reply. Each hit appends `date<TAB>word<TAB>snippet` to
~/.skadi/register_log; the snippet is there so a reader can tell a real miss
from a false one. The log is append-only and never rotated; delete it freely.

Text the reply shows or quotes is not its own voice and is skipped: fenced
blocks, code spans, blockquote lines, and text inside "…", “…”, 「…」 or 『…』.

WORDS mirrors the list in the Register bullet. Change both together.

Platforms: macOS, Linux, Windows (Python 3, standard library only). Tested on
macOS; on Windows run `bash hooks/register-scan.test.sh` from Git Bash.
"""

import datetime
import json
import re
import sys
from pathlib import Path

WORDS = (
    "should have", "failed to", "forgot", "careless",
    "早該", "忘了", "沒注意", "疏忽",
)
LOG = Path.home() / ".skadi" / "register_log"
REPLY_FIELD = "last_assistant_message"
SNIPPET_RADIUS = 20

# Python's \b and \w count Chinese characters as word characters, so a word
# or a quote mark set directly against Chinese text would have no boundary.
# These two test for an ASCII word character instead.
NOT_AFTER_WORD = r"(?<![A-Za-z0-9_])"
NOT_BEFORE_WORD = r"(?![A-Za-z0-9_])"

# Order matters: a fence may hold backticks and quote marks, so it goes first.
# A fence that is never closed runs to the end of the reply, as it renders.
SHOWN = (
    re.compile(
        r"^[ \t]*(`{3,}|~{3,}).*?(?:^[ \t]*\1[`~]*[ \t]*$|\Z)", re.S | re.M
    ),
    re.compile(r"^[ \t]*>[^\n]*$", re.M),
    re.compile(r"`[^`\n]*`"),
    # A quote opens after a non-word character and closes before one, so the
    # inch marks in `a 5" pipe ... a 6" one` do not pair up and hide the text
    # between them.
    re.compile(NOT_AFTER_WORD + r'"[^"\n]+"' + NOT_BEFORE_WORD),
    re.compile(r"“[^”\n]*”"),
    re.compile(r"「[^」\n]*」"),
    re.compile(r"『[^』\n]*』"),
)


def pattern(word):
    """One WORDS entry as a regex. English entries match as whole words, so
    "forgotten" and "carelessly" do not count: the log holds the listed words
    and nothing else. A space matches any run of whitespace, line breaks
    included. Chinese entries have no word boundary to test."""
    if not word.isascii():
        return re.escape(word)
    spaced = r"\s+".join(re.escape(part) for part in word.split())
    return NOT_AFTER_WORD + spaced + NOT_BEFORE_WORD


GRADING = re.compile("|".join(pattern(word) for word in WORDS), re.I)


def own_prose(reply):
    """The reply with everything it shows or quotes blanked out."""
    for shown in SHOWN:
        reply = shown.sub(" ", reply)
    return reply


def hits(prose):
    """(word, snippet) for each grading word, in reading order."""
    found = []
    for match in GRADING.finditer(prose):
        start = max(0, match.start() - SNIPPET_RADIUS)
        snippet = " ".join(prose[start:match.end() + SNIPPET_RADIUS].split())
        found.append((" ".join(match.group(0).lower().split()), snippet))
    return found


def record(found):
    today = datetime.date.today().isoformat()
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a", encoding="utf-8") as log:
        for word, snippet in found:
            log.write("%s\t%s\t%s\n" % (today, word, snippet))


def main():
    try:
        # Bytes, not sys.stdin: Windows would decode the reply with the
        # console code page and garble the Chinese words.
        payload = json.loads(sys.stdin.buffer.read())
    except ValueError:
        return
    reply = payload.get(REPLY_FIELD) if isinstance(payload, dict) else None
    if not isinstance(reply, str):
        return
    found = hits(own_prose(reply))
    if not found:
        return
    try:
        record(found)
    except OSError:
        pass  # a log that cannot be written must not disturb the session


if __name__ == "__main__":
    main()
