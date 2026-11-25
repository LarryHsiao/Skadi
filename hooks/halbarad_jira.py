#!/usr/bin/env python3
"""Jira delta + cursor for /halbarad. Read-only: GET requests only.

    halbarad-jira.sh                  print the delta as JSON, advance the cursor
    halbarad-jira.sh window <hours>   print the delta over the last <hours>, touching no state
    halbarad-jira.sh cursor get <s>   print source <s>'s cursor (empty if unset)
    halbarad-jira.sh cursor set <s> <iso>
    halbarad-jira.sh last put <s>     keep stdin as <s>'s list from the latest brief
    halbarad-jira.sh last get <s>     print it (empty if none)

A run that finds tickets also keeps its list for the drill-down (`last get jira`).

A ticket is news when it is assigned to the user, was created by them, or one of
its comments has ever named them, and someone else changed or commented on it
after the cursor.
Mentions are read from the comments' ADF `mention` nodes: Jira's own docs offer
no reliable JQL mention operator (JRACLOUD-27594), so JQL only narrows the
candidates and the nodes decide.

Exit codes: 0 ok · 2 not configured · 4 Jira failed (cursor left where it was).
Platforms: macOS and Windows (Git Bash) — Python 3 standard library only.

Environment (set by halbarad-jira.sh; tests set them directly):
    HALBARAD_JIRA_URL / _EMAIL / _TOKEN   credentials
    HALBARAD_CURSOR_FILE                  cursor store
    HALBARAD_NOW                          fixed clock, ISO 8601 (tests)
    HALBARAD_JIRA_FIXTURE_DIR             offline answers (tests)
"""
import base64
import json
import math
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

EXIT_NOT_CONFIGURED = 2
EXIT_JIRA_FAILED = 4
FIRST_RUN_WINDOW = timedelta(hours=24)
JQL_SLACK_MINUTES = 2
PAGE_SIZE = 100
MAX_PAGES = 5
QUOTE_LIMIT = 200
HTTP_TIMEOUT_SECONDS = 30
DONE_CATEGORY = "done"
SOURCE_LINE = re.compile(r"^(\w+):\s*(\S+)\s*$")


class JiraFailure(Exception):
    """A Jira answer that did not arrive or could not be read."""


def parse_ts(text):
    """Parse an ISO 8601 stamp, with Z or +HHMM offsets, into aware UTC."""
    text = re.sub(r"Z$", "+00:00", text)
    text = re.sub(r"([+-]\d\d)(\d\d)$", r"\1:\2", text)
    return datetime.fromisoformat(text).astimezone(timezone.utc)


def iso(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def local_label(moment):
    return moment.astimezone().strftime("%Y-%m-%d %H:%M")


def read_cursors(path):
    cursors = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                found = SOURCE_LINE.match(line)
                if found:
                    cursors[found.group(1)] = found.group(2)
    return cursors


def write_cursor(path, source, value):
    cursors = read_cursors(path)
    cursors[source] = value
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    temp = path + ".tmp"
    with open(temp, "w", encoding="utf-8") as handle:
        handle.write("".join(f"{name}: {stamp}\n" for name, stamp in sorted(cursors.items())))
    os.replace(temp, path)


def fetch(path, params=None):
    """GET one Jira path as JSON; a fixture file stands in when one is set."""
    fixture_dir = os.environ.get("HALBARAD_JIRA_FIXTURE_DIR")
    if fixture_dir:
        return fetch_fixture(fixture_dir, path)
    url = os.environ["HALBARAD_JIRA_URL"].rstrip("/") + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    login = f'{os.environ["HALBARAD_JIRA_EMAIL"]}:{os.environ["HALBARAD_JIRA_TOKEN"]}'
    request = urllib.request.Request(
        url, headers={"Authorization": "Basic " + base64.b64encode(login.encode()).decode()}
    )
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise JiraFailure(f"HTTP {error.code}") from error
    except TimeoutError as error:
        raise JiraFailure("timeout") from error
    except (urllib.error.URLError, ValueError, OSError) as error:
        raise JiraFailure(f"unreachable ({error})") from error


def fetch_fixture(fixture_dir, path):
    failure = os.path.join(fixture_dir, "fail")
    if os.path.exists(failure):
        with open(failure, encoding="utf-8") as handle:
            raise JiraFailure(handle.read().strip())
    if path.endswith("/comment"):
        name = "comments-" + path.split("/")[-2] + ".json"
    else:
        name = {"/rest/api/3/myself": "myself.json", "/rest/api/3/status": "status.json",
                "/rest/api/3/search/jql": "search.json"}[path]
    with open(os.path.join(fixture_dir, name), encoding="utf-8") as handle:
        return json.load(handle)


def search_candidates(now, since):
    minutes = math.ceil((now - since).total_seconds() / 60) + JQL_SLACK_MINUTES
    jql = (f"updated >= -{minutes}m AND (assignee = currentUser() "
           "OR reporter = currentUser() OR comment ~ currentUser()) ORDER BY updated DESC")
    issues, token = [], None
    for _ in range(MAX_PAGES):
        params = {"jql": jql, "fields": "summary,status,assignee,reporter,updated",
                  "expand": "changelog", "maxResults": PAGE_SIZE}
        if token:
            params["nextPageToken"] = token
        page = fetch("/rest/api/3/search/jql", params)
        issues += page.get("issues", [])
        token = page.get("nextPageToken")
        if not token:
            break
    return issues


def flatten(node):
    """Plain text of an ADF node, mentions rendered as their @name."""
    if isinstance(node, list):
        return "".join(flatten(child) for child in node)
    if not isinstance(node, dict):
        return ""
    if node.get("type") == "mention":
        return node.get("attrs", {}).get("text", "")
    return node.get("text", "") + flatten(node.get("content", []))


def mentions_user(node, account_id):
    if isinstance(node, list):
        return any(mentions_user(child, account_id) for child in node)
    if not isinstance(node, dict):
        return False
    if node.get("type") == "mention" and node.get("attrs", {}).get("id") == account_id:
        return True
    return mentions_user(node.get("content", []), account_id)


def shorten(text):
    text = " ".join(text.split())
    return text if len(text) <= QUOTE_LIMIT else text[:QUOTE_LIMIT - 1] + "…"


def event(moment, who, kind, **extra):
    return {"at": iso(moment), "local": local_label(moment), "who": who, "kind": kind, **extra}


def history_changes(issue, since, me, done_names):
    """Changelog items by others after the cursor, as events."""
    changes = []
    for history in issue.get("changelog", {}).get("histories", []):
        when = parse_ts(history["created"])
        author = history.get("author", {})
        if when <= since or author.get("accountId") == me:
            continue
        for item in history.get("items", []):
            changes.append(event(
                when, author.get("displayName", "someone"), item["field"],
                **{"from": item.get("fromString"), "to": item.get("toString")},
                reopened=(item["field"] == "status" and item.get("fromString") in done_names
                          and item.get("toString") not in done_names),
                to_me=(item["field"] == "assignee" and item.get("to") == me)))
    return changes


def comment_events(key, since, me):
    """Comments by others after the cursor, as changes and mentions; also whether
    anyone, at any time, has named the user in this ticket's comments."""
    changes, mentions, named_ever = [], [], False
    reply = fetch(f"/rest/api/3/issue/{key}/comment", {"orderBy": "-created", "maxResults": PAGE_SIZE})
    for comment in reply.get("comments", []):
        author = comment.get("author", {})
        named = author.get("accountId") != me and mentions_user(comment["body"], me)
        named_ever = named_ever or named
        when = parse_ts(comment["created"])
        if when <= since or author.get("accountId") == me:
            continue
        who = author.get("displayName", "someone")
        changes.append(event(when, who, "comment"))
        if named:
            mentions.append(event(when, who, "mention", quote=shorten(flatten(comment["body"]))))
    return changes, mentions, named_ever


def build_ticket(issue, since, me, done_names, base_url):
    key = issue["key"]
    fields = issue["fields"]
    comment_changes, mentions, named_ever = comment_events(key, since, me)
    changes = history_changes(issue, since, me, done_names) + comment_changes
    assigned = (fields.get("assignee") or {}).get("accountId") == me
    created_by_me = (fields.get("reporter") or {}).get("accountId") == me
    if not changes or not (assigned or created_by_me or named_ever):
        return None
    return {
        "key": key, "summary": fields["summary"], "status": fields["status"]["name"],
        "url": f"{base_url.rstrip('/')}/browse/{key}",
        "updated": fields["updated"],
        "assigned": assigned,
        "created_by_me": created_by_me,
        "reopened": any(change.get("reopened") for change in changes),
        "reassigned_to_me": any(change.get("to_me") for change in changes),
        "changes": sorted(changes, key=lambda change: change["at"]),
        "mentions": sorted(mentions, key=lambda mention: mention["at"]),
    }


def delta(now, since):
    me = fetch("/rest/api/3/myself")["accountId"]
    statuses = fetch("/rest/api/3/status")
    done_names = {s["name"] for s in statuses if s["statusCategory"]["key"] == DONE_CATEGORY}
    base_url = os.environ.get("HALBARAD_JIRA_URL", "")
    tickets = []
    for issue in search_candidates(now, since):
        if parse_ts(issue["fields"]["updated"]) <= since:
            continue
        ticket = build_ticket(issue, since, me, done_names, base_url)
        if ticket:
            tickets.append(ticket)
    return sorted(tickets, key=lambda ticket: parse_ts(ticket["updated"]), reverse=True)


def report_failure(reason):
    print(json.dumps({"source": "jira", "status": "error", "reason": reason}, ensure_ascii=False))
    return EXIT_JIRA_FAILED


def clock():
    if os.environ.get("HALBARAD_NOW"):
        return parse_ts(os.environ["HALBARAD_NOW"])
    return datetime.now(timezone.utc).replace(microsecond=0)


def brief_json(since, now, tickets):
    return json.dumps({"source": "jira", "status": "ok", "since": iso(since),
                       "since_local": local_label(since), "now": iso(now),
                       "now_local": local_label(now), "tickets": tickets}, ensure_ascii=False)


def run_delta(cursor_path):
    now = clock()
    stored = read_cursors(cursor_path).get("jira")
    try:
        since = parse_ts(stored) if stored else now - FIRST_RUN_WINDOW
        tickets = delta(now, since)
    except JiraFailure as failure:
        return report_failure(str(failure))
    except (KeyError, TypeError, ValueError) as error:
        return report_failure(f"unexpected answer or cursor ({type(error).__name__}: {error})")
    brief = brief_json(since, now, tickets)
    if tickets:
        with open(last_path(cursor_path, "jira"), "w", encoding="utf-8") as handle:
            handle.write(brief)
        write_cursor(cursor_path, "jira", iso(now))
    print(brief)
    return 0


def run_window(args):
    """The delta over the last <hours>, read-only: no cursor moves, no list is kept."""
    if len(args) != 1 or not args[0].isdigit() or int(args[0]) < 1:
        print("usage: window <hours> (a whole number, at least 1)", file=sys.stderr)
        return 1
    now = clock()
    since = now - timedelta(hours=int(args[0]))
    try:
        tickets = delta(now, since)
    except JiraFailure as failure:
        return report_failure(str(failure))
    except (KeyError, TypeError, ValueError) as error:
        return report_failure(f"unexpected answer ({type(error).__name__}: {error})")
    print(brief_json(since, now, tickets))
    return 0


def run_cursor(cursor_path, args):
    if len(args) == 2 and args[0] == "get":
        print(read_cursors(cursor_path).get(args[1], ""))
        return 0
    if len(args) == 3 and args[0] == "set":
        write_cursor(cursor_path, args[1], args[2])
        return 0
    print("usage: cursor get <source> | cursor set <source> <iso>", file=sys.stderr)
    return 1


def last_path(cursor_path, source):
    return os.path.join(os.path.dirname(cursor_path), f"halbarad_last_{source}.json")


def run_last(cursor_path, args):
    """Keep each source's full list from the latest brief, for the drill-down."""
    if len(args) != 2 or args[0] not in ("get", "put"):
        print("usage: last get <source> | last put <source> (JSON on stdin)", file=sys.stderr)
        return 1
    path = last_path(cursor_path, args[1])
    if args[0] == "put":
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(sys.stdin.read())
    elif os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            print(handle.read())
    return 0


def main(argv):
    # Ticket text is often CJK; a Windows console defaults to cp1252 and would crash on print.
    sys.stdout.reconfigure(encoding="utf-8")
    if argv[:1] == ["window"]:
        return run_window(argv[1:])
    cursor_path = os.environ.get("HALBARAD_CURSOR_FILE")
    if not cursor_path:
        print("halbarad-jira: HALBARAD_CURSOR_FILE is not set", file=sys.stderr)
        return EXIT_NOT_CONFIGURED
    if argv[:1] == ["cursor"]:
        return run_cursor(cursor_path, argv[1:])
    if argv[:1] == ["last"]:
        return run_last(cursor_path, argv[1:])
    if argv:
        print("usage: halbarad-jira.sh [window <hours> | cursor get|set … | last get|put …]", file=sys.stderr)
        return 1
    return run_delta(cursor_path)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
