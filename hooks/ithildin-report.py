#!/usr/bin/env python3
"""Render the proof page /ithildin hands to a reviewer: one row per AC.

Usage: python3 -I ithildin-report.py <manifest.json> [--out-dir <dir>]

The manifest names one page and its acceptance criteria:

    {"slug": "psg5056", "title": "PSG-5056 proof", "lede": "optional",
     "video": "/abs/recording.mp4", "videoHint": "start the recording first",
     "acs": [{"text": "The empty list shows the placeholder",
              "shot": "/abs/ac-1.png",
              "at": 83,
              "verdict": "fail", "reason": "the list still shows 4 posts",
              "hint": "open the settings screen and I'll shoot it",
              "notes": ["optional line", ...]}]}

An AC whose shot is absent, or names a file that does not exist, draws a dashed
missing-proof row carrying its hint, so a failed capture is visible rather than
a silent gap.

An optional per-AC verdict ("pass", "fail" or "unclear", with an optional
`reason` and `verdictBy` of "model" (default) or "human") shows as a badge, a
coloured left rule and the reason, labelled with who read it. A verdict needs a
shot; an unknown verdict, an unknown `verdictBy`, or a verdict with no shot is a
manifest error naming the AC. The page opens with five exact counts (pass, fail,
unclear, not judged, not captured), every AC in exactly one, and a link to the
first failure when there is one.

An optional `video` is embedded once, pinned at the top of the page. An AC that
carries `at` (seconds into the recording) gets a "play from here" button that
seeks the one player there. A `video` naming an absent file draws a missing
block carrying `videoHint`, and no buttons. A negative or non-numeric `at` is a
manifest error.

Images and the video are copied beside the page, one page and one image folder per slug, so
the page is self-contained in the Henneth folder.

Prints the page path on stdout; any failure exits non-zero with a reason on
stderr. Stdlib only.
"""

import argparse
import html
import json
import math
import re
import shutil
import sys
from pathlib import Path

DEFAULT_OUT_DIR = Path.home() / ".skadi" / "henneth"
PAGE_PREFIX = "ithildin-"
DEFAULT_MISSING_HINT = "not captured yet"
VERDICTS = {"pass": ("yes", "PASS"), "fail": ("no", "FAIL"), "unclear": ("unclear", "UNCLEAR")}
READERS = {"model": "model's reading", "human": "your reading"}
TALLY = (
    ("pass", "yes", "pass"),
    ("fail", "no", "fail"),
    ("unclear", "unclear", "unclear"),
    ("unjudged", "info", "not judged"),
    ("uncaptured", "none", "not captured"),
)

STYLE = """
  body { margin: 0; }
  .proof { max-width: 1100px; margin: 0 auto; padding: 16px; }
  h1 { margin: 0 0 4px; }
  .lede { margin: 0 0 8px; opacity: .8; }
  .tally { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; margin: 0 0 16px; font-size: .8rem; }
  .tally .badge { margin-bottom: 0; }
  .tally .first { margin-left: auto; color: var(--accent); }
  .badge.none { background: var(--line); color: var(--ink); }
  section { margin: 0 0 40px; }
  section h2 { margin: 0 0 8px; font-size: 1.15rem; }
  .ac { border-left: 4px solid var(--line); padding-left: 10px; }
  .ac.pass { border-left-color: var(--green); }
  .ac.fail { border-left-color: var(--red); }
  .ac.unclear { border-left-color: #8a8472; }
  .proof.has-video .ac { scroll-margin-top: calc(40vh + 36px); }
  .ac h2 { display: flex; gap: 8px; align-items: baseline; justify-content: space-between; }
  .ac h2 .badge { flex: none; margin: 0 0 0 auto; }
  .badge.unclear { background: #8a8472; color: var(--bg); }
  .reason { font-size: .88rem; margin: 4px 0 2px; }
  .reason.clamp { display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
  .more { font: inherit; font-size: .75rem; margin-left: 8px; padding: 0; border: 0; background: none; text-decoration: underline; cursor: pointer; color: inherit; }
  .meta { font-size: .75rem; opacity: .65; margin: 0 0 8px; }
  img { max-width: 100%; max-height: 55vh; width: auto; height: auto; display: block; border: 1px solid #0003; }
  .missing { border: 1px dashed #0004; padding: 40px 16px; text-align: center; font-size: .9rem; opacity: .7; }
  .notes { font-size: .88rem; margin: 6px 0 0; padding-left: 18px; }
  .recording { position: sticky; top: 0; z-index: 2; background: var(--bg); padding: 8px 0 12px; margin: 0 0 16px; }
  .recording video { width: 100%; max-height: 40vh; background: #000; display: block; }
  .jump { font: inherit; font-size: .85rem; margin: 0 0 8px; cursor: pointer; }
"""

SEEK_SCRIPT = """
  const recording = document.getElementById('recording');
  document.querySelectorAll('button.jump').forEach(button => {
    button.addEventListener('click', () => {
      recording.currentTime = Number(button.dataset.at);
      recording.play();
    });
  });
"""

REASON_SCRIPT = """
  document.querySelectorAll('.reason').forEach(reason => {
    const more = reason.nextElementSibling.querySelector('.more');
    if (reason.scrollHeight > reason.clientHeight + 1) more.hidden = false;
    more.addEventListener('click', () => {
      const clamped = reason.classList.toggle('clamp');
      more.textContent = clamped ? 'show full reason' : 'show less';
    });
  });
"""


def _text(value):
    return html.escape(str(value), quote=True)


def _slug(raw):
    slug = re.sub(r"[^A-Za-z0-9]+", "-", str(raw)).strip("-")
    if not slug:
        raise ValueError("manifest slug has no usable characters")
    return slug


def _present(path):
    return bool(path) and Path(path).is_file()


def _copy_file(source, images_dir, name):
    """Copy one file beside the page; return its path relative to the page."""
    target = f"{name}{Path(source).suffix}"
    images_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, images_dir / target)
    return f"{images_dir.name}/{target}"


def _proof(image, hint):
    if image:
        return f'<img src="{_text(image)}">'
    return f'<div class="missing">{_text(hint or DEFAULT_MISSING_HINT)}</div>'


def _notes(notes):
    if not notes:
        return ""
    items = "".join(f"<li>{_text(note)}</li>" for note in notes)
    return f'<ul class="notes">{items}</ul>'


def _clock(seconds):
    total = int(seconds)
    hours, rest = divmod(total, 3600)
    minutes, secs = divmod(rest, 60)
    return f"{hours}:{minutes:02d}:{secs:02d}" if hours else f"{minutes}:{secs:02d}"


def _start_time(number, ac):
    """The AC's start offset in seconds, or None when it names none."""
    raw = ac.get("at")
    if raw is None:
        return None
    problem = f"AC {number}: at must be a finite, non-negative number of seconds"
    if isinstance(raw, bool):
        raise ValueError(problem)
    try:
        seconds = float(raw)
    except (TypeError, ValueError):
        raise ValueError(problem) from None
    if not math.isfinite(seconds) or seconds < 0:
        raise ValueError(problem)
    return seconds


def _seconds_attribute(seconds):
    """Exact seconds for a data attribute: whole numbers bare, fractions to the millisecond."""
    return f"{seconds:.3f}".rstrip("0").rstrip(".")


def _jump(seconds):
    label = f"\u25b6 {_clock(seconds)}"
    return f'<button class="jump" type="button" data-at="{_seconds_attribute(seconds)}">{label}</button>'


def _verdict(number, ac, has_shot):
    """The AC's verdict key, or None when it carries none."""
    _reader(number, ac)
    raw = ac.get("verdict")
    if raw is None:
        if ac.get("reason"):
            raise ValueError(f"AC {number}: a reason needs a verdict")
        return None
    key = str(raw).strip().lower()
    if key not in VERDICTS:
        raise ValueError(f"AC {number}: verdict must be pass, fail or unclear")
    if not has_shot:
        raise ValueError(f"AC {number}: a verdict needs a shot")
    return key


def _reader(number, ac):
    by = str(ac.get("verdictBy", "model"))
    if by not in READERS:
        raise ValueError(f"AC {number}: verdictBy must be model or human")
    return READERS[by]


def _judgment(number, ac, key):
    """Badge markup and the reason block for an AC that carries a verdict."""
    badge_class, word = VERDICTS[key]
    badge = f'<span class="badge {badge_class}">{word}</span>'
    who = f'<span class="who">{_reader(number, ac)}</span>'
    if not ac.get("reason"):
        return badge, f'<p class="meta">{who}</p>'
    toggle = '<button class="more" type="button" hidden>show full reason</button>'
    return badge, f'<div class="reason clamp">{_text(ac["reason"])}</div><p class="meta">{who}{toggle}</p>'


def _state(key, has_shot):
    if key:
        return key
    return "unjudged" if has_shot else "uncaptured"


def _section(number, ac, images_dir, has_video):
    shot = _copy_file(ac["shot"], images_dir, f"ac-{number}") if _present(ac.get("shot")) else None
    key = _verdict(number, ac, shot is not None)
    badge, judgment = _judgment(number, ac, key) if key else ("", "")
    start = _start_time(number, ac)
    jump = _jump(start) if has_video and start is not None else ""
    classes = f"ac {key}" if key else "ac"
    return (
        f'<section id="ac-{number}" class="{classes}"><h2>{number}. {_text(ac["text"])}{badge}</h2>'
        f'{jump}{judgment}{_proof(shot, ac.get("hint"))}{_notes(ac.get("notes"))}</section>',
        _state(key, shot is not None),
    )


def _tally(states):
    """Five exact counts, every AC in exactly one, plus a link to the first failure."""
    badges = "".join(
        f'<span class="badge {style}">{states.count(key)} {label}</span>' for key, style, label in TALLY)
    first = f'<a class="first" href="#ac-{states.index("fail") + 1}">first fail \u2193</a>' if "fail" in states else ""
    return f'<p class="tally">{badges}{first}</p>'


def _recording(manifest, images_dir):
    """The pinned player, or a missing block; second value says whether a player stands."""
    if not manifest.get("video"):
        return "", False
    if not _present(manifest["video"]):
        hint = _text(manifest.get("videoHint") or DEFAULT_MISSING_HINT)
        return f'<div class="recording"><div class="missing">{hint}</div></div>', False
    source = _copy_file(manifest["video"], images_dir, "recording")
    player = f'<video id="recording" controls preload="auto" src="{_text(source)}"></video>'
    return f'<div class="recording">{player}</div>', True


def _page(manifest, sections, tally, recording, has_reasons):
    player, has_video = recording
    scripts = [SEEK_SCRIPT] * has_video + [REASON_SCRIPT] * has_reasons
    script = "".join(f"<script>{code}</script>\n" for code in scripts)
    page_class = "proof has-video" if has_video else "proof"
    lede = f'<p class="lede">{_text(manifest["lede"])}</p>' if manifest.get("lede") else ""
    title = _text(manifest["title"])
    return (
        '<!doctype html>\n<meta charset="utf-8">\n'
        f'<title>{title}</title>\n<link rel="stylesheet" href="skadi-theme.css">\n'
        f'<style>{STYLE}</style>\n<div class="{page_class}">\n<h1>{title}</h1>\n{lede}\n{tally}\n'
        f'{player}\n{"".join(sections)}\n</div>\n{script}'
    )


def render(manifest, out_dir):
    """Write the page and its image folder under out_dir; return the page path."""
    slug = _slug(manifest["slug"])
    images_dir = out_dir / f"{PAGE_PREFIX}{slug}"
    shutil.rmtree(images_dir, ignore_errors=True)
    recording = _recording(manifest, images_dir)
    rows = [
        _section(number, ac, images_dir, recording[1])
        for number, ac in enumerate(manifest["acs"], start=1)
    ]
    tally = _tally([state for _, state in rows])
    has_reasons = any(ac.get("verdict") and ac.get("reason") for ac in manifest["acs"])
    out_dir.mkdir(parents=True, exist_ok=True)
    page = out_dir / f"{PAGE_PREFIX}{slug}.html"
    page.write_text(_page(manifest, [row for row, _ in rows], tally, recording, has_reasons), encoding="utf-8")
    return page


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    args = parser.parse_args(argv)
    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        print(render(manifest, args.out_dir))
    except KeyError as field:
        print(f"ithildin-report: manifest {args.manifest}: missing field {field}", file=sys.stderr)
        return 1
    except (OSError, ValueError, TypeError, AttributeError) as reason:
        print(f"ithildin-report: manifest {args.manifest}: {reason}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
