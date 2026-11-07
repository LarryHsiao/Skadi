#!/usr/bin/env python3
"""board-ci.py

Writes the CI channel the situation board reads. Scans every `ci_routing.md`
under the profiles' project state (~/.skadi/profiles/*/projects/*/), asks each
binding's backend hook for the latest run of each build, and writes one lamp
per build, grouped by CI source and then by project.

Read-only against the CI: it only calls the same hooks `/amon-din` uses
(`amon-din-teamcity.sh`, `amon-din-github.sh`). GitLab bindings are left off
the board.

A lamp whose hook fails is `unknown` — never green. "Couldn't look" must not
read as "all fine", the same rule the Attention band keeps for its counts.

Test seams: BOARD_DIR, SKADI_PROFILES_DIR, CI_FRESH_HOURS; collect() takes the
hook runner as a parameter so the tests never reach a network.
"""
import concurrent.futures
import datetime as dt
import glob
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FRESH_HOURS = int(os.environ.get("CI_FRESH_HOURS", "6"))
HOOK_TIMEOUT_S = 30
WORKERS = 8

# Section order on the board, and each source's display label.
SOURCES = (("github", "github actions"), ("teamcity", "teamcity"))

# Worst first: a failure outranks a run in flight, and an unreachable lamp
# outranks a quiet one, so a project's group light never hides a doubt.
SEVERITY = ("failed", "running", "queued", "unknown", "cancelled", "success")

# What a lamp's `error` says. collect() reads HOOK_FAILED back to decide that a
# whole source is unreachable, so the two sites must share one spelling.
HOOK_FAILED = "hook failed"
NO_RUNS = "no runs"

TEAMCITY_STAMP = "%Y%m%dT%H%M%S%z"

_CHECKSUM_SUFFIX = re.compile(r"-[0-9a-f]{12}$")


def project_name(dirname):
    """The state directory is `<repo>-<12 hex checksum>`; the repo is what shows."""
    return _CHECKSUM_SUFFIX.sub("", dirname)


def parse_binding(text):
    """Read a ci_routing.md body into {flavor, repo, lamps}; None if it names no flavor."""
    flavor = repo = None
    lamps = []
    for raw in _body(text).splitlines():
        line = raw.rstrip()
        match = re.match(r"^flavor:\s*(\S+)", line)
        if match:
            flavor = match.group(1)
            continue
        match = re.match(r"^repo:\s*(\S+)", line)
        if match:
            repo = match.group(1)
            continue
        match = re.match(r"^buildTypeId:\s*(\S+)", line)
        if match:
            lamps.append({"id": match.group(1), "label": match.group(1)})
            continue
        match = re.match(r"^\s*-\s*id:\s*(\S+)", line)
        if match:
            lamps.append({"id": match.group(1), "label": match.group(1)})
            continue
        match = re.match(r"^\s+label:\s*(.+)$", line)
        if match and lamps:
            lamps[-1]["label"] = match.group(1).strip()
    if flavor is None:
        return None
    return {"flavor": flavor, "repo": repo, "lamps": lamps}


def _body(text):
    """The text after a leading `---` frontmatter block, or all of it when there is none."""
    if not text.startswith("---"):
        return text
    parts = text.split("---", 2)
    return parts[2] if len(parts) == 3 else text


def parse_time(stamp):
    """Normalise a TeamCity or ISO-8601 stamp to UTC `YYYY-MM-DDTHH:MM:SSZ`; None if unreadable."""
    try:
        parsed = dt.datetime.strptime(stamp, TEAMCITY_STAMP)
        return parsed.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        pass
    try:
        parsed = dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def hook_argv(flavor, repo, lamp_id):
    """The command for one build's latest run. Bash is named by full path: a bare
    `bash` under subprocess resolves, on Windows, to WSL's System32\\bash.exe ahead
    of PATH, and that one fails outright when no distribution is installed."""
    bash = shutil.which("bash") or "bash"
    if flavor == "teamcity":
        return [bash, os.path.join(HERE, "amon-din-teamcity.sh"), lamp_id, "1"]
    return [bash, os.path.join(HERE, "amon-din-github.sh"), repo or "", lamp_id, "1"]


def run_hook(flavor, repo, lamp_id):
    """Call the backend hook for one build; returns (returncode, stdout)."""
    argv = hook_argv(flavor, repo, lamp_id)
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=HOOK_TIMEOUT_S)
    except (OSError, subprocess.TimeoutExpired) as err:
        return 1, str(err)
    return done.returncode, done.stdout


def make_lamp(lamp, result):
    returncode, stdout = result
    base = {"id": lamp["id"], "label": lamp["label"], "status": "unknown", "number": None,
            "branch": None, "finished": None, "url": None, "error": None}
    if returncode != 0:
        base["error"] = HOOK_FAILED
        return base
    rows = [line.split("|") for line in stdout.splitlines() if line.strip()]
    if not rows or len(rows[0]) < 5:
        base["error"] = NO_RUNS
        return base
    number, status, branch, stamp, url = (field.strip() for field in rows[0][:5])
    base.update(status=status, number=number, branch=branch, url=url,
                finished=parse_time(stamp) if stamp else None)
    return base


def worst(lamps):
    ranked = [lamp["status"] for lamp in lamps]
    return min(ranked, key=SEVERITY.index) if ranked else "unknown"


def scan(profiles_dir):
    """Yield (project dirname, binding) for every readable, non-GitLab binding."""
    seen = set()
    pattern = os.path.join(profiles_dir, "*", "projects", "*", "ci_routing.md")
    for path in sorted(glob.glob(pattern)):
        dirname = os.path.basename(os.path.dirname(path))
        try:
            with open(path, encoding="utf-8") as fh:
                binding = parse_binding(fh.read())
        except OSError:
            continue
        if binding is None or binding["flavor"] not in dict(SOURCES):
            continue
        key = (binding["flavor"], dirname)
        if key in seen:
            continue
        seen.add(key)
        yield dirname, binding


def collect(profiles_dir, hook=run_hook):
    jobs = [(binding["flavor"], dirname, binding["repo"], lamp)
            for dirname, binding in scan(profiles_dir) for lamp in binding["lamps"]]
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        results = list(pool.map(lambda job: hook(job[0], job[2], job[3]["id"]), jobs))
    grouped = {}
    for (flavor, dirname, _repo, lamp), result in zip(jobs, results):
        grouped.setdefault(flavor, {}).setdefault(dirname, []).append(make_lamp(lamp, result))
    sources = []
    for flavor, label in SOURCES:
        if flavor not in grouped:
            continue
        projects = [{"name": project_name(dirname), "worst": worst(lamps), "lamps": lamps}
                    for dirname, lamps in grouped[flavor].items()]
        projects.sort(key=lambda p: (SEVERITY.index(p["worst"]), p["name"]))
        every = [lamp for p in projects for lamp in p["lamps"]]
        sources.append({"source": flavor, "label": label, "projects": projects,
                        "unreachable": all(lamp["error"] == HOOK_FAILED for lamp in every)})
    return {"channel": "ci", "id": "ci", "fresh_window_hours": FRESH_HOURS, "sources": sources}


def main():
    board = os.environ.get("BOARD_DIR", os.path.expanduser("~/.skadi/board"))
    profiles = os.environ.get("SKADI_PROFILES_DIR", os.path.expanduser("~/.skadi/profiles"))
    os.makedirs(board, exist_ok=True)
    channel = collect(profiles)
    channel["updated"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    path = os.path.join(board, "ci.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(channel, fh, ensure_ascii=False, indent=2)
    subprocess.run([sys.executable, os.path.join(HERE, "board-manifest.py"), board], check=False)

    lamps = [lamp for s in channel["sources"] for p in s["projects"] for lamp in p["lamps"]]
    red = sum(1 for lamp in lamps if lamp["status"] == "failed")
    print("wrote %s — %d builds across %d sources, %d red" % (path, len(lamps), len(channel["sources"]), red))


if __name__ == "__main__":
    main()
