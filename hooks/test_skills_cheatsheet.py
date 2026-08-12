#!/usr/bin/env python3
"""Contract tests for the skills cheatsheet's parameter extraction.

The cheatsheet's cards expand to show what a skill does and how it is called.
No SKILL.md declares its parameters in frontmatter, so the grammar is read out
of prose, from two sources in order:

1. the description's own leading run of ``/<name> …`` forms — most of the 51
   skills open with one ("Use when the user runs /rumil <spec> …");
2. failing that, a line in the body that begins with ``/<name>`` — the usage
   block a handful of skills carry instead.

A skill documenting neither yields nothing, and the card says so. The trap
these tests exist to pin is the third branch collapsing into an invention:
a parser that guesses a grammar is worse than one that admits it found none.
"""

import importlib.util
import re
import unittest
from html.parser import HTMLParser
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location(
    "skills_cheatsheet_render", HERE / "skills-cheatsheet-render.py"
)
cheatsheet = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cheatsheet)

SKILLS_DIR = HERE.parent / "skills"


def first_tag_attributes(markup):
    """The attribute names a browser reads off the first tag, in order.

    Parsed rather than pattern-matched, so a quote breaking out of an attribute
    shows up as the extra attributes a browser would really invent.
    """
    found = []

    class Reader(HTMLParser):
        def handle_starttag(self, tag, attrs):
            if not found:
                found.extend(name for name, _value in attrs)

    Reader().feed(markup)
    return found


class DescriptionBranchTest(unittest.TestCase):
    """The primary source — the description's leading run of forms."""

    def test_the_leading_clause_yields_the_grammar(self):
        expected = ["/rumil <spec> [--folder=<path>]"]
        description = (
            "Use when the user runs /rumil <spec> [--folder=<path>], or asks in "
            'plain words to "break this spec into tasks". Translates a product '
            "specification into an engineering plan."
        )
        self.assertEqual(expected, cheatsheet.invocations("rumil", description, ""))

    def test_every_form_in_a_multi_form_clause_is_kept(self):
        expected = [
            "/mithrandir",
            "/mithrandir branch",
            "/mithrandir <url>",
            "/mithrandir comment <url>",
            "/mithrandir bless <url>",
        ]
        description = (
            "Use when the user runs /mithrandir, /mithrandir branch, /mithrandir "
            "<url>, /mithrandir comment <url>, or /mithrandir bless <url>. With no "
            "argument the current branch is weighed."
        )
        self.assertEqual(expected, cheatsheet.invocations("mithrandir", description, ""))

    def test_prose_beside_the_forms_is_not_mistaken_for_one(self):
        """The trap: the clause's tail is prose, comma-separated like a form list."""
        expected = ["/rumil <spec>"]
        description = (
            "Use when the user runs /rumil <spec>, or asks in plain words to "
            '"plan this out", "break this down", or anything of that shape.'
        )
        self.assertEqual(expected, cheatsheet.invocations("rumil", description, ""))

    def test_an_ellipsis_inside_a_form_is_not_a_sentence_break(self):
        """`<id>...` ends in a period and a space, but the form is not over."""
        expected = ["/amon-din remove <id>..."]
        description = (
            "Use when the user runs /amon-din remove <id>... — mutate the "
            "per-project CI routing."
        )
        self.assertEqual(expected, cheatsheet.invocations("amon-din", description, ""))

    def test_prose_running_straight_off_a_form_is_cut(self):
        """No comma separates the grammar from its explanation — the commonest shape."""
        expected = ["/branch [target] [strategy]"]
        description = (
            "Use when the user runs /branch [target] [strategy] to switch to a "
            "target branch, safely handling uncommitted work first."
        )
        self.assertEqual(expected, cheatsheet.invocations("branch", description, ""))

    def test_a_bare_or_separates_two_forms(self):
        expected = ["/lindir <url>", "/lindir approve <url>"]
        description = "Use when the user runs /lindir <url> or /lindir approve <url>."
        self.assertEqual(expected, cheatsheet.invocations("lindir", description, ""))

    def test_an_alias_in_parentheses_is_a_form_of_its_own(self):
        expected = ["/mithrandir bless <url>", "/mithrandir recheck <url>"]
        description = (
            "Use when the user runs /mithrandir bless <url> (alias /mithrandir "
            "recheck <url>). It re-weighs an amended PR."
        )
        self.assertEqual(expected, cheatsheet.invocations("mithrandir", description, ""))

    def test_a_slash_inside_a_path_is_not_read_as_an_invocation(self):
        """`build/publish/` is a directory; the real clause sits two sentences later."""
        expected = ["/publish [platform...]"]
        description = (
            "Build Flutter release archives and collect into build/publish/. "
            "Use /publish [platform...] to build. Default platforms: android ios."
        )
        self.assertEqual(expected, cheatsheet.invocations("publish", description, ""))

    def test_a_form_ending_the_sentence_keeps_no_full_stop(self):
        expected = ["/cleanup-dev [--no-analyze]"]
        description = "Free disk space by clearing dev caches. Use /cleanup-dev [--no-analyze]."
        self.assertEqual(expected, cheatsheet.invocations("cleanup-dev", description, ""))

    def test_a_flag_keeps_its_attached_value(self):
        """`--project=<KEY>` is one argument; cutting at the `=` loses the value."""
        expected = ["/scribe <file> --project=<KEY> [--target=<slug>]"]
        description = (
            "Use when the user runs /scribe <file> --project=<KEY> "
            "[--target=<slug>] to export a section."
        )
        self.assertEqual(expected, cheatsheet.invocations("scribe", description, ""))

    def test_a_placeholder_glued_to_a_bracket_survives_whole(self):
        expected = ["/amon-din add <id>[:<label>]..."]
        description = "Use when the user runs /amon-din add <id>[:<label>]... — bind a build."
        self.assertEqual(expected, cheatsheet.invocations("amon-din", description, ""))

    def test_a_repeated_form_is_listed_once(self):
        expected = ["/focus status"]
        description = "Use when the user runs /focus status, /focus status. Shows the timer."
        self.assertEqual(expected, cheatsheet.invocations("focus", description, ""))

    def test_an_em_dash_ends_the_run(self):
        """Several descriptions close the form list with an em dash, not a period."""
        expected = ["/amon-din [<count>]", "/amon-din all [<count>]"]
        description = (
            "Use when the user runs /amon-din [<count>], /amon-din all [<count>] — "
            "render the most recent CI runs, default 3, for the current branch."
        )
        self.assertEqual(expected, cheatsheet.invocations("amon-din", description, ""))


class BodyBranchTest(unittest.TestCase):
    """The fallback — a usage line in the body, for a description with no clause."""

    def test_a_body_usage_line_is_read_when_the_description_has_none(self):
        expected = ["/narvi <url> --no-confirm"]
        description = "Picks up every unresolved comment on a PR or MR."
        body = "## Usage\n\n```\n/narvi <url> --no-confirm\n```\n"
        self.assertEqual(expected, cheatsheet.invocations("narvi", description, body))

    def test_a_trailing_comment_is_trimmed_from_a_usage_line(self):
        expected = ["/mandos <pr-or-mr-url>"]
        description = "Weighs a branch against its ticket's goal."
        body = "/mandos <pr-or-mr-url>       # URL-path: weigh an open PR/MR\n"
        self.assertEqual(expected, cheatsheet.invocations("mandos", description, body))

    def test_the_description_wins_when_both_sources_speak(self):
        """The description is the curated one; a body block may be a stale example."""
        expected = ["/este"]
        description = "Use when the user runs /este. Computes the adherence pulse."
        body = "/este --old-flag\n"
        self.assertEqual(expected, cheatsheet.invocations("este", description, body))


class NeitherBranchTest(unittest.TestCase):
    def test_a_skill_documenting_no_grammar_yields_nothing(self):
        expected = []
        description = "Run periodic maintenance checks across the configured repos."
        self.assertEqual(expected, cheatsheet.invocations("preflight", description, ""))

    def test_a_mention_of_another_skill_is_never_read_as_this_one(self):
        """`/durin` in moria's description must not become moria's own grammar."""
        expected = []
        description = "Loops /durin --repo over each root in the mend list."
        self.assertEqual(expected, cheatsheet.invocations("moria", description, ""))


class EscapingTest(unittest.TestCase):
    """Six descriptions carry a literal quote, and they fill a quoted attribute."""

    def test_a_quote_in_a_description_cannot_close_the_attribute(self):
        """Unescaped, the quote ended data-hay and the rest became bogus attributes."""
        expected = ["class", "data-hay", "role", "tabindex", "aria-expanded"]
        card = cheatsheet.card_html(
            "quoted", 'Use when the user runs /quoted. Say "go" to proceed.', None, ["/quoted"]
        )
        self.assertEqual(expected, first_tag_attributes(card))

    def test_the_quoted_words_survive_into_the_search_text(self):
        expected = "say &quot;go&quot; to proceed"
        card = cheatsheet.card_html(
            "quoted", 'Use when the user runs /quoted. Say "go" to proceed.', None, ["/quoted"]
        )
        self.assertIn(expected, card)


class CorpusTest(unittest.TestCase):
    """The parser bends to the 51 skills as they stand; they are not edited to suit it."""

    def test_every_skill_parses_without_raising(self):
        expected = len(list(SKILLS_DIR.glob("*/SKILL.md")))
        parsed = cheatsheet.collect(SKILLS_DIR)
        self.assertEqual(expected, len(parsed))

    def test_rumil_reports_the_grammar_its_own_skill_md_documents(self):
        expected = "/rumil <spec> [--folder=<path>]"
        by_name = {s[0]: s for s in cheatsheet.collect(SKILLS_DIR)}
        self.assertIn(expected, by_name["rumil"][3])

    def test_no_form_anywhere_in_the_corpus_swallows_prose(self):
        """The invariant that matters: a shown grammar is a grammar, not a sentence.

        Placeholders and flags may legitimately contain a connective — `<id-or-jql>`,
        `--from-json` — so only bare tokens are weighed.
        """
        expected_swallowed = []
        connective = re.compile(r"^(?:%s)$" % cheatsheet.STOP_WORDS)
        swallowed = []
        for name, _description, _purpose, forms in cheatsheet.collect(SKILLS_DIR):
            for form in forms:
                bare = re.sub(r"<[^>]*>|\[[^\]]*\]|--?[\w-]+", " ", form)
                if any(connective.match(word) for word in bare.split()):
                    swallowed.append((name, form))
        self.assertEqual(expected_swallowed, swallowed)

    def test_nearly_every_skill_yields_a_grammar(self):
        """A regression guard: if a refactor breaks the parse, this collapses."""
        parsed = cheatsheet.collect(SKILLS_DIR)
        with_params = [s for s in parsed if s[3]]
        self.assertGreaterEqual(len(with_params), int(len(parsed) * 0.85))

    def test_publish_is_read_past_the_path_in_its_own_description(self):
        """The real file, not a fixture — its description opens with `build/publish/`."""
        expected = ["/publish [platform...]"]
        by_name = {s[0]: s for s in cheatsheet.collect(SKILLS_DIR)}
        self.assertEqual(expected, by_name["publish"][3])


if __name__ == "__main__":
    unittest.main()
