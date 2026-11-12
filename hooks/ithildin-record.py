#!/usr/bin/env python3
"""Record the iOS Simulator for /ithildin: one continuous video, a mark per AC.

Usage:
  ithildin-record.py start [--device booted|<udid>]
  ithildin-record.py mark <label>
  ithildin-record.py stop [--out FILE.mp4]
  (each also takes --state-dir DIR; default ~/.skadi/ithildin)

`start` launches `xcrun simctl io <device> recordVideo` detached and prints the
raw .mov path. Time zero is the instant simctl prints "Recording started", so
its start-up delay never skews a mark. `mark` stamps the seconds since then
under a label. `stop` ends the recording, converts it to an H.264 .mp4 that
browsers play, and prints one JSON object: {"video", "marks", "duration"}.

simctl writes a frame only when the screen changes, so the raw file stops at
the last change and runs shorter than the real session. `stop` pads the end by
repeating the last frame up to the wall-clock duration, so a mark taken after
the final change still lies inside the video.

macOS with Xcode only (it needs `xcrun`); `ffmpeg` and `ffprobe` convert and
measure. Any other host exits 3 naming the need. State lives in
<state-dir>/current.json and survives a failed `stop`, so fixing ffmpeg and
running `stop` again finishes the job: the stop time is kept, so the retry pads
to when the recorder stopped, not to now, and `start` refuses to overwrite the
unfinished recording. Marks are meant to be taken one at a time; two at once
could lose one. Stdlib only.

Exit codes: 2 no recording in progress, 3 already recording or no xcrun,
4 the recorder failed, 5 ffmpeg missing or failed.
"""

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_STATE_DIR = Path.home() / ".skadi" / "ithildin"
STATE_FILE = "current.json"
LOG_FILE = "recorder.log"
STARTED_LINE = "Recording started"
RECORDER_MARKER = "recordVideo"
START_TIMEOUT_S = 15
STOP_TIMEOUT_S = 30
POLL_INTERVAL_S = 0.05
PAD_THRESHOLD_S = 0.25
OUTPUT_FPS = 30


class Failure(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def _state_file(state_dir):
    return state_dir / STATE_FILE


def _read(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except ValueError:
        raise Failure(2, f"unreadable state file {path}; delete it to start over") from None


def _load(state_dir):
    path = _state_file(state_dir)
    if not path.is_file():
        raise Failure(2, "no recording in progress")
    return _read(path)


def _save(state_dir, state):
    state_dir.mkdir(parents=True, exist_ok=True)
    target = _state_file(state_dir)
    scratch = target.with_suffix(".tmp")
    scratch.write_text(json.dumps(state), encoding="utf-8")
    os.replace(scratch, target)


def _alive(pid):
    """True while pid is a running simctl recorder; a bare pid may have been reused."""
    probe = subprocess.run(
        ["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True)
    return RECORDER_MARKER in probe.stdout


def _clock(seconds):
    minutes, secs = divmod(int(seconds), 60)
    return f"{minutes}:{secs:02d}"


def _wait_for_start(log, process):
    """Return the wall-clock instant the recorder reported it had started."""
    deadline = time.time() + START_TIMEOUT_S
    while time.time() < deadline:
        text = log.read_text(encoding="utf-8", errors="replace") if log.exists() else ""
        if STARTED_LINE in text:
            return time.time()
        if process.poll() is not None:
            raise Failure(4, text.strip() or "the recorder exited at once")
        time.sleep(POLL_INTERVAL_S)
    process.kill()
    raise Failure(4, f"the recorder did not report \"{STARTED_LINE}\" in {START_TIMEOUT_S}s")


def _recorder_command(device, mov):
    return ["xcrun", "simctl", "io", device, "recordVideo", "--codec", "h264", str(mov)]


def _refuse_if_busy(state_dir):
    path = _state_file(state_dir)
    if not path.is_file():
        return
    state = _read(path)
    if _alive(state["pid"]):
        raise Failure(3, "already recording; run stop first")
    if Path(state["mov"]).is_file():
        raise Failure(3, f"an unfinished recording is kept at {state['mov']}; run stop to finish it")


def start(state_dir, device):
    if shutil.which("xcrun") is None:
        raise Failure(3, "recording the iOS Simulator needs macOS with Xcode (xcrun not found)")
    _refuse_if_busy(state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    mov, log = state_dir / "recording.mov", state_dir / LOG_FILE
    log.write_text("", encoding="utf-8")
    with log.open("ab") as sink:
        process = subprocess.Popen(
            _recorder_command(device, mov), stdout=subprocess.DEVNULL, stderr=sink,
            start_new_session=True)
        started_at = _wait_for_start(log, process)
    _save(state_dir, {"pid": process.pid, "started_at": started_at, "mov": str(mov), "marks": []})
    return str(mov)


def mark(state_dir, label):
    state = _load(state_dir)
    offset = round(time.time() - state["started_at"], 3)
    state["marks"].append({"label": label, "at": offset})
    _save(state_dir, state)
    return f"{label} at {_clock(offset)}"


def _stop_recorder(pid):
    if not _alive(pid):
        return
    try:
        os.kill(pid, signal.SIGINT)
    except ProcessLookupError:
        return
    deadline = time.time() + STOP_TIMEOUT_S
    while _alive(pid) and time.time() < deadline:
        time.sleep(POLL_INTERVAL_S)
    if _alive(pid):
        raise Failure(4, f"the recorder did not stop within {STOP_TIMEOUT_S}s")


def _duration(path):
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(path)],
        capture_output=True, text=True)
    try:
        return float(probe.stdout.strip())
    except ValueError:
        return 0.0


def _convert(mov, mp4, wall_seconds):
    if shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None:
        raise Failure(5, "ffmpeg and ffprobe are needed to make the .mp4; the raw .mov is kept at " + str(mov))
    pad = wall_seconds - _duration(mov)
    command = ["ffmpeg", "-loglevel", "error", "-y", "-i", str(mov)]
    if pad > PAD_THRESHOLD_S:
        command += ["-vf", f"tpad=stop_mode=clone:stop_duration={pad:.3f}"]
    command += ["-r", str(OUTPUT_FPS), "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-movflags", "+faststart", str(mp4)]
    if subprocess.run(command).returncode != 0:
        raise Failure(5, f"ffmpeg failed; the raw .mov is kept at {mov}")


def stop(state_dir, out):
    state = _load(state_dir)
    state.setdefault("stopped_at", time.time())
    _save(state_dir, state)
    wall_seconds = state["stopped_at"] - state["started_at"]
    _stop_recorder(state["pid"])
    mov = Path(state["mov"])
    if not mov.is_file():
        raise Failure(4, f"the recorder left no file at {mov}")
    mp4 = Path(out) if out else mov.with_suffix(".mp4")
    _convert(mov, mp4, wall_seconds)
    mov.unlink()
    _state_file(state_dir).unlink()
    return {"video": str(mp4), "marks": state["marks"], "duration": round(wall_seconds, 3)}


def _parse(argv):
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--state-dir", type=Path, default=DEFAULT_STATE_DIR)
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    verbs = parser.add_subparsers(dest="verb", required=True)
    verbs.add_parser("start", parents=[common]).add_argument("--device", default="booted")
    verbs.add_parser("mark", parents=[common]).add_argument("label")
    verbs.add_parser("stop", parents=[common]).add_argument("--out")
    return parser.parse_args(argv)


def main(argv):
    args = _parse(argv)
    try:
        if args.verb == "start":
            print(start(args.state_dir, args.device))
        elif args.verb == "mark":
            print(mark(args.state_dir, args.label))
        else:
            print(json.dumps(stop(args.state_dir, args.out)))
    except Failure as failure:
        print(f"ithildin-record: {failure}", file=sys.stderr)
        return failure.code
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
