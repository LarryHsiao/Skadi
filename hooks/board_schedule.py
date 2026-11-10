#!/usr/bin/env python3
"""board_schedule.py — timed jobs for the board server.

The board page only reads channel files; nothing refreshes them unless a writer
runs. This module lets the standing board server run its own writers on a timer,
so a channel stays current while the server is up. A job is a script that already
lives in the hooks folder (board-ci.py, board.sh attention mrs, ...) — the server
adds no new writer, only the clock.

Jobs come from `<board-dir>/schedule.json`, a small hand-kept file:

    {"jobs": [{"name": "ci", "script": "board-ci.py", "every_s": 300},
              {"name": "mrs", "script": "board.sh", "args": ["attention", "mrs"],
               "every_s": 900, "timeout_s": 60}]}

With no file, the one default job is CI every five minutes. A job names a script
by bare file name inside the hooks folder — never a path — so the file cannot
point the server at anything outside it. A bad entry is reported and skipped; it
never stops the good ones. A file that cannot be read, or whose every entry is
bad, falls back to the default rather than leaving the board with no clock; a
file that deliberately lists no jobs is respected, and schedules nothing.

Platforms: macOS and Windows; Python standard library only.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import NamedTuple

SCHEDULE_FILE = "schedule.json"
MIN_INTERVAL_S = 10
DEFAULT_TIMEOUT_S = 120
SCRIPT_SUFFIXES = (".py", ".sh")
DEFAULT_ENTRIES = [{"name": "ci", "script": "board-ci.py", "every_s": 300}]
DETAIL_TAIL_BYTES = 300
POLL_S = 1.0


class Job(NamedTuple):
    name: str
    script: str
    args: tuple
    every_s: int
    timeout_s: int


def _text(entry, key):
    value = entry.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError("%r needs a non-empty string" % key)
    return value


def _whole_number(entry, key, default, minimum):
    value = entry.get(key, default)
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ValueError("%r must be a whole number of at least %d" % (key, minimum))
    return value


def _script_name(entry, hooks_dir):
    script = _text(entry, "script")
    if Path(script).name != script or not script.endswith(SCRIPT_SUFFIXES):
        raise ValueError("script %r must be a .py or .sh file name inside the hooks folder" % script)
    if not (Path(hooks_dir) / script).is_file():
        raise ValueError("script %r is not in the hooks folder" % script)
    return script


def _args(entry):
    args = entry.get("args", [])
    if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
        raise ValueError("'args' must be a list of strings")
    return tuple(args)


def _read_entry(entry, hooks_dir):
    if not isinstance(entry, dict):
        raise ValueError("an entry must be an object")
    return Job(_text(entry, "name"), _script_name(entry, hooks_dir), _args(entry),
               _whole_number(entry, "every_s", None, MIN_INTERVAL_S),
               _whole_number(entry, "timeout_s", DEFAULT_TIMEOUT_S, 1))


def parse_jobs(text, hooks_dir):
    """Read schedule text into (jobs, errors). A bad entry is an error, not a crash."""
    try:
        data = json.loads(text)
    except ValueError as err:
        return [], ["schedule is not valid JSON: %s" % err]
    entries = data.get("jobs") if isinstance(data, dict) else None
    if not isinstance(entries, list):
        return [], ["schedule needs a top-level {\"jobs\": [...]}"]
    jobs, errors = [], []
    for position, entry in enumerate(entries):
        try:
            job = _read_entry(entry, hooks_dir)
        except ValueError as err:
            errors.append("job %d: %s" % (position + 1, err))
            continue
        if any(kept.name == job.name for kept in jobs):
            errors.append("job %d: duplicate name %r" % (position + 1, job.name))
            continue
        jobs.append(job)
    return jobs, errors


def load_jobs(board_dir, hooks_dir):
    """The board's jobs: its schedule.json when one stands, else the default CI job."""
    default = parse_jobs(json.dumps({"jobs": DEFAULT_ENTRIES}), hooks_dir)
    path = Path(board_dir) / SCHEDULE_FILE
    if not path.is_file():
        return default
    try:
        jobs, errors = parse_jobs(path.read_text(encoding="utf-8"), hooks_dir)
    except (OSError, ValueError) as err:
        return default[0], default[1] + ["cannot read %s: %s" % (path, err)]
    if errors and not jobs:
        return default[0], default[1] + errors
    return jobs, errors


def due(jobs, last_started, running, now):
    """The jobs to start now: never run, or a full interval since the last start —
    and never one that is still running, so a slow run is skipped, not stacked."""
    return [job for job in jobs
            if job.name not in running
            and (job.name not in last_started or now - last_started[job.name] >= job.every_s)]


def argv_for(job, hooks_dir):
    """The command for one job. Bash is named by full path: a bare `bash` under
    subprocess resolves, on Windows, to WSL's System32\\bash.exe ahead of PATH."""
    path = str(Path(hooks_dir) / job.script)
    interpreter = sys.executable if job.script.endswith(".py") else (shutil.which("bash") or "bash")
    return [interpreter, path, *job.args]


def run_job(job, hooks_dir, env=None):
    """Run one job to completion; returns (ok, detail). A job past its timeout is
    killed — the direct child only: a grandchild it spawned may outlive it. Output
    goes to a temp file, not a pipe, so such a survivor cannot hold the run open
    (on Windows, `subprocess.run` keeps reading the pipes after the kill)."""
    with tempfile.TemporaryFile() as out:
        try:
            done = subprocess.run(argv_for(job, hooks_dir), stdin=subprocess.DEVNULL, stdout=out,
                                  stderr=subprocess.STDOUT, timeout=job.timeout_s, env=env)
        except subprocess.TimeoutExpired:
            return False, "timed out after %ds" % job.timeout_s
        except OSError as err:
            return False, str(err)
        if done.returncode == 0:
            return True, ""
        return False, "exit %d: %s" % (done.returncode, _tail(out))


def _tail(out):
    size = out.seek(0, 2)
    out.seek(max(0, size - DETAIL_TAIL_BYTES))
    return out.read().decode("utf-8", "replace").strip()


def log_line(message):
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
    print("%s board-schedule: %s" % (stamp, message), file=sys.stderr, flush=True)


def _start_thread(work):
    threading.Thread(target=work, daemon=True).start()


class Schedule:
    """Starts each job when it falls due. `run(job)` returns (ok, detail); `spawn`
    runs a piece of work off the caller's thread — injected so a test can join it."""

    def __init__(self, jobs, run, log, spawn=_start_thread):
        self.jobs = jobs
        self._run = run
        self._log = log
        self._spawn = spawn
        self._last_started = {}
        self._running = set()
        self._lock = threading.Lock()

    def tick(self, now):
        with self._lock:
            starting = due(self.jobs, self._last_started, self._running, now)
            for job in starting:
                self._running.add(job.name)
                self._last_started[job.name] = now
        for job in starting:
            self._spawn(lambda job=job: self._execute(job))

    def _execute(self, job):
        try:
            ok, detail = self._run(job)
        except Exception as err:  # a job must never take the server down
            ok, detail = False, "%s: %s" % (type(err).__name__, err)
        with self._lock:
            self._running.discard(job.name)
        self._log("%s %s" % (job.name, "ok" if ok else "FAILED — %s" % detail))


def loop(schedule, stop, clock=time.monotonic):
    while not stop.is_set():
        schedule.tick(clock())
        stop.wait(POLL_S)


def start(board_dir, hooks_dir, env=None, log=log_line):
    """Load the board's jobs and run them on a background thread; returns the Event
    that stops it. Problems in the schedule file are logged, never raised."""
    jobs, errors = load_jobs(board_dir, hooks_dir)
    for error in errors:
        log("schedule: %s" % error)
    log("schedule: %d job(s): %s" % (len(jobs), ", ".join("%s/%ds" % (j.name, j.every_s) for j in jobs)))
    schedule = Schedule(jobs, lambda job: run_job(job, hooks_dir, env), log)
    stop = threading.Event()
    threading.Thread(target=loop, args=(schedule, stop), daemon=True).start()
    return stop
