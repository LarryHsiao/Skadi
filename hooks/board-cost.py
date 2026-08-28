#!/usr/bin/env python3
"""board-cost.py

Writes the spend channel the situation board reads. Scans every Claude config
root's session transcripts inside a window and sums the harness's own settled
cost — the `cost-state` record it writes near a session's close, the same
figure `/usage` shows.

It never prices anything. Re-deriving cost from token counts was tried and
failed twice: a rate table matched two sampled sessions to 2e-16 and then
missed five of eight, and adding the documented 5m/1.25x, 1h/2x, read/0.1x
cache multipliers scored zero of eight, one of them by a factor of 85. The
transcript's own usage entries are not a billing ledger — one session carried
124x the tokens the harness billed, against a different set of models. So the
only number here is one the harness settled.

That number is itself an estimate. Claude Code computes it locally at standard
list rates, so it reflects neither promotional pricing nor contracted discounts
(https://code.claude.com/docs/en/costs). Authoritative billing is the Console.

`cost-state` is undocumented and internal; the docs say the transcript format
"changes between versions" and a pipeline reading it "can break on any
release". That is accepted deliberately: the failure is loud and local — the
tile empties or says the format moved — where the supported OTel path would
put a collector in every session's startup and lose data in silence when it
was down. Hence the format guard below: a record missing what this reader
expects is counted as malformed and named on the tile, never quietly priced
at zero.

Test seams: COST_ROOTS (colon-separated roots, as pulse-scan.py's PULSE_ROOTS),
COST_WINDOW_DAYS, and BOARD_DIR.
"""
import collections
import datetime as dt
import glob
import json
import os
import subprocess
import sys
import time

SECONDS_PER_DAY = 86400
WINDOW_DAYS = int(os.environ.get("COST_WINDOW_DAYS", "90"))

# Every field this reader leans on. A record lacking one is malformed: the
# shape moved under us, and the tile must say so rather than count a zero.
REQUIRED = ("sessionId", "totalCostUSD", "modelUsage")

# What a worktree's flattened project folder carries after its parent repo.
WORKTREE_MARKER = "--claude-worktrees-"


def roots():
    override = os.environ.get("COST_ROOTS")
    if override:
        return override.split(":")
    return [os.path.expanduser("~/.%s%s" % (runtime, suffix))
            for runtime in ("claude",)
            for suffix in ("", "-personal", "-work")]


def transcripts(cutoff_ms):
    """Every transcript touched inside the window, as (path, root, project)."""
    found = []
    for root in roots():
        pattern = os.path.join(os.path.expanduser(root), "projects", "*", "*.jsonl")
        for path in glob.glob(pattern):
            try:
                if os.path.getmtime(path) * 1000 < cutoff_ms:
                    continue
            except OSError:
                continue
            found.append((path, root_label(root), os.path.basename(os.path.dirname(path))))
    return found


def root_label(root):
    """personal / work / default, from the config root's own folder name."""
    name = os.path.basename(os.path.expanduser(root).rstrip("/"))
    for suffix in ("-personal", "-work"):
        if name.endswith(suffix):
            return suffix[1:]
    return "default"


def project_label(project_dir):
    """A readable name from the flattened project folder the harness makes,
    by dropping the home prefix: -Users-me-work-vitallink-ca -> work-vitallink-ca.

    Taking the last hyphen-separated segment instead would be wrong, and
    silently so: the harness flattens '/' to '-', so a hyphen is both a path
    separator and an ordinary character in a repo's name. That reading turned
    vitallink-ca into 'ca' and psg-4630 into '4630' against real transcripts.
    The home prefix is the one boundary that can be found rather than guessed.

    A worktree folds into the repo it belongs to. `/repo/.claude/worktrees/<name>`
    flattens to `<repo>--claude-worktrees-<name>` — both '/' and '.' become '-',
    hence the doubled hyphen — and left as its own row it splits one repo's
    spend in two, which misorders the ranking rather than merely lengthening it."""
    home = os.path.expanduser("~").replace(os.sep, "-")
    label = project_dir
    if label.startswith(home + "-"):
        label = label[len(home) + 1:]
    return label.split(WORKTREE_MARKER, 1)[0]


def cost_records(path):
    """The cost-state records in one transcript, in file order. A torn line is
    skipped rather than fatal — transcripts are appended to live, so a
    half-written last line is ordinary."""
    out = []
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return out
    with fh:
        for line in fh:
            if '"cost-state"' not in line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if record.get("type") == "cost-state":
                out.append(record)
    return out


def is_well_formed(record):
    """Whether this reader can price a record without guessing.

    Checked before anything keys on it: validating after keying let two records
    both missing sessionId collide on a None key, so the second silently
    replaced the first and one of the two malformed records went uncounted.
    Each model entry is checked too — by_model is the only consumer of the
    per-model figure, and defaulting a missing one to zero understates that
    model's share while the format guard still reads green."""
    if any(record.get(field) is None for field in REQUIRED):
        return False
    usages = record["modelUsage"]
    if not isinstance(usages, dict):
        return False
    return all(isinstance(usage, dict) and usage.get("costUSD") is not None
               for usage in usages.values())


def settle(records):
    """(one record per sessionId, sessions that carried more than one).

    Two shapes have to be told apart. Repeated records for ONE sessionId are
    successive snapshots of a running total — summing them double-counts, so
    the last wins. Distinct sessionIds in one file are separate bills: /clear
    starts a fresh session and resets the totals, so those do sum.

    The second return counts SESSIONS that repeated, not extra records: three
    snapshots of one session are one multi-record session, and the field it
    feeds is named for sessions."""
    by_session = {}
    repeated = set()
    for record in records:
        key = record["sessionId"]
        if key in by_session:
            repeated.add(key)
        by_session[key] = record
    return by_session, len(repeated)


def _rate(total, denominator):
    """A ratio, or None when its denominator is empty — a session that changed
    no lines has no cost per line, and 0 would read as one."""
    return round(total / denominator, 4) if denominator else None


def _ranked(counter):
    return [{"name": name, "usd": round(usd, 4)}
            for name, usd in counter.most_common()]


class Tally:
    """The running sums one pass over the transcripts fills in."""

    def __init__(self):
        self.total = 0.0
        self.by_project = collections.Counter()
        self.by_root = collections.Counter()
        self.by_model = collections.Counter()
        self.sessions = self.malformed = self.multi = self.unknown = 0
        self.lines = 0
        self.transcripts = self.transcripts_settled = 0

    def add(self, record, project, root):
        self.sessions += 1
        cost = record["totalCostUSD"]
        self.total += cost
        self.by_project[project_label(project)] += cost
        self.by_root[root] += cost
        for model, usage in record["modelUsage"].items():
            self.by_model[model] += usage["costUSD"]
        self.lines += record.get("totalLinesAdded", 0) + record.get("totalLinesRemoved", 0)
        if record.get("hasUnknownModelCost"):
            self.unknown += 1


def read_transcript(tally, path, root, project):
    """Fold one transcript into the tally."""
    tally.transcripts += 1
    records = cost_records(path)
    good = [r for r in records if is_well_formed(r)]
    tally.malformed += len(records) - len(good)
    by_session, multi = settle(good)
    tally.multi += multi
    if by_session:
        tally.transcripts_settled += 1
    for record in by_session.values():
        # The window is the file's own mtime, applied once in transcripts() —
        # not the record's startTime. A session carrying no cost-state has no
        # startTime to test, so the denominator can only be timed by the file;
        # timing the numerator any other way makes coverage a fraction of two
        # different windows.
        tally.add(record, project, root)


def collect(cutoff_ms):
    tally = Tally()
    for path, root, project in transcripts(cutoff_ms):
        read_transcript(tally, path, root, project)
    return channel(tally)


def channel(tally):
    """The board channel a filled tally describes.

    Coverage is counted in TRANSCRIPTS on both sides. Sessions are a different
    unit — one file holds several once /clear has run — and mixing the two let
    the ratio read 200%. The session tally stands beside it under its own name,
    where per_session_usd needs it."""
    return {
        "channel": "cost",
        "window_days": WINDOW_DAYS,
        # None, not 0.0, when nothing settled: an empty tile and a zero-cost
        # tile are different claims, and the board renders them differently.
        "total_usd": round(tally.total, 4) if tally.sessions else None,
        "transcripts_settled": tally.transcripts_settled,
        "transcripts_in_window": tally.transcripts,
        "sessions_settled": tally.sessions,
        "by_project": _ranked(tally.by_project),
        "by_root": _ranked(tally.by_root),
        "by_model": _ranked(tally.by_model),
        # No per-hour rate. totalDuration is wall clock, which counts every
        # hour a terminal sat open: across ten real sessions it read $0.84/h
        # against a working rate several times that, because two of them were
        # left running. A number that invites one reading and means another is
        # worse on a tile than no number.
        "per_session_usd": _rate(tally.total, tally.sessions),
        "per_changed_line_usd": _rate(tally.total, tally.lines),
        "changed_lines": tally.lines,
        "multi_record_sessions": tally.multi,
        "unknown_model_cost": tally.unknown,
        "malformed": tally.malformed,
        "format_ok": tally.malformed == 0,
        "source": "cost-state",
        "url": None,
    }


def main():
    board = os.environ.get("BOARD_DIR", os.path.expanduser("~/.skadi/board"))
    os.makedirs(board, exist_ok=True)
    cutoff_ms = (time.time() - WINDOW_DAYS * SECONDS_PER_DAY) * 1000

    channel = collect(cutoff_ms)
    channel["updated"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    path = os.path.join(board, "cost.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(channel, fh, ensure_ascii=False, indent=2)

    manifest = os.path.join(os.path.dirname(os.path.abspath(__file__)), "board-manifest.py")
    subprocess.run([sys.executable, manifest, board], check=False)

    total = channel["total_usd"]
    print("wrote %s — %s over %d of %d sessions in %dd"
          % (path, "$%.2f" % total if total is not None else "no settled cost",
             channel["transcripts_settled"], channel["transcripts_in_window"], WINDOW_DAYS))


if __name__ == "__main__":
    main()
