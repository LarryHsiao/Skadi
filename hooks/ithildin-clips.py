#!/usr/bin/env python3
"""Cut one clip per acceptance criterion out of an /ithildin recording.

Usage: ithildin-clips.py <stop.json> [--out-dir DIR]

<stop.json> is what `ithildin-record.py stop` printed: {"video", "marks",
"duration"}. Marks are taken in time order. Each starts a clip that ends where
the next mark begins; the last runs to the end of the video. Clips are cut by
re-encoding to H.264 (a stream copy could only start on a keyframe, so a clip
would begin early) and land in DIR, `clips/` beside the recording by default,
as clip-<label>.mp4. A mark is stamped once the screen it names is up, so a
clip opens on that screen; it runs to the next mark, so its tail can show the
move to the next criterion's screen.

Two labels that would share a file name (case ignored, as macOS and Windows
disks do) are refused. A clip left in DIR by an earlier run is overwritten when
this run makes one of the same label, and left alone otherwise.

A mark whose clip would be shorter than 0.5 s, or that starts at or after the
end of the video, makes no clip and is listed under "skipped" with its reason.
A clip ffmpeg could not cut is listed under "failed"; the rest are still cut.

Prints one JSON object: {"clips": [{"label", "at", "end", "clip"}],
"skipped": [{"label", "reason"}], "failed": [{"label", "reason"}]}.

Needs ffmpeg and ffprobe; any OS that has them. Stdlib only.

Exit codes: 2 the input is unusable, 3 ffmpeg or ffprobe is missing, 4 one or
more clips failed.
"""

import argparse
import json
import math
import re
import shutil
import subprocess
import sys
from pathlib import Path

MIN_CLIP_S = 0.5
CLIP_PREFIX = "clip-"
DEFAULT_DIR_NAME = "clips"


class Failure(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def _safe_name(label):
    return re.sub(r"[^A-Za-z0-9]+", "-", str(label)).strip("-") or "mark"


def _load(path):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as reason:
        raise Failure(2, f"cannot read {path}: {reason}") from None
    video = data.get("video") if isinstance(data, dict) else None
    marks = data.get("marks") if isinstance(data, dict) else None
    if not isinstance(video, str) or not isinstance(marks, list):
        raise Failure(2, f"{path} is not `ithildin-record.py stop` output (needs video and marks)")
    if not Path(video).is_file():
        raise Failure(2, f"the recording {video} is not there")
    return video, _checked(marks)


def _valid_mark(mark):
    if not isinstance(mark, dict) or not isinstance(mark.get("label"), str):
        return False
    at = mark.get("at")
    return isinstance(at, (int, float)) and not isinstance(at, bool) and math.isfinite(at) and at >= 0


def _checked(marks):
    names = {}
    for mark in marks:
        if not _valid_mark(mark):
            raise Failure(2, f"a mark needs a label and a finite, non-negative `at`: {mark!r}")
        name = _safe_name(mark["label"]).casefold()  # macOS and Windows disks ignore case
        if name in names:
            raise Failure(2, f"duplicate label {mark['label']!r} (also {names[name]!r}): clips would share one file")
        names[name] = mark["label"]
    return sorted(marks, key=lambda mark: mark["at"])


def _duration(video):
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", video],
        capture_output=True, text=True)
    try:
        return float(probe.stdout.strip())
    except ValueError:
        raise Failure(2, f"cannot read the length of {video}") from None


def _plan(marks, duration):
    """(label, start, end) for each clip worth cutting, and the marks skipped."""
    cuts, skipped = [], []
    ends = [mark["at"] for mark in marks[1:]] + [duration]
    for mark, end in zip(marks, ends):
        start = mark["at"]
        if start >= duration:
            skipped.append({"label": mark["label"], "reason": "starts at or after the end of the video"})
        elif end - start < MIN_CLIP_S:
            skipped.append({"label": mark["label"], "reason": f"its clip would be shorter than {MIN_CLIP_S} s"})
        else:
            cuts.append((mark["label"], start, end))
    return cuts, skipped


def _cut(video, start, end, out):
    command = ["ffmpeg", "-loglevel", "error", "-y", "-ss", f"{start:.3f}", "-i", video, "-t", f"{end - start:.3f}",
               "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(out)]
    return subprocess.run(command, capture_output=True).returncode


def _require_tools():
    missing = [tool for tool in ("ffmpeg", "ffprobe") if shutil.which(tool) is None]
    if missing:
        raise Failure(3, f"{' and '.join(missing)} needed to cut the clips")


def make_clips(stop_json, out_dir=None):
    video, marks = _load(stop_json)
    report = {"clips": [], "skipped": [], "failed": []}
    if not marks:
        return report
    _require_tools()
    target = Path(out_dir) if out_dir else Path(video).parent / DEFAULT_DIR_NAME
    try:
        target.mkdir(parents=True, exist_ok=True)
    except OSError as reason:
        raise Failure(2, f"cannot make {target}: {reason}") from None
    cuts, report["skipped"] = _plan(marks, _duration(video))
    for label, start, end in cuts:
        out = target / f"{CLIP_PREFIX}{_safe_name(label)}.mp4"
        status = _cut(video, start, end, out)
        if status == 0:
            report["clips"].append({"label": label, "at": round(start, 3), "end": round(end, 3), "clip": str(out)})
        else:
            report["failed"].append({"label": label, "reason": f"ffmpeg exited {status}"})
    return report


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("stop_json")
    parser.add_argument("--out-dir")
    args = parser.parse_args(argv)
    try:
        report = make_clips(args.stop_json, args.out_dir)
    except Failure as failure:
        print(f"ithildin-clips: {failure}", file=sys.stderr)
        return failure.code
    print(json.dumps(report))
    if report["failed"]:
        names = ", ".join(entry["label"] for entry in report["failed"])
        print(f"ithildin-clips: could not cut the clip for {names}", file=sys.stderr)
        return 4
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
