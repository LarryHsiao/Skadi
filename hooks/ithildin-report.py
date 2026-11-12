#!/usr/bin/env python3
"""Render the proof page /ithildin hands to a reviewer: one row per AC.

Usage: python3 -I ithildin-report.py <manifest.json> [--out-dir <dir>]

The manifest names one page and its acceptance criteria:

    {"slug": "psg5056", "title": "PSG-5056 proof", "lede": "optional",
     "acs": [{"text": "The empty list shows the placeholder",
              "shot": "/abs/ac-1.png",
              "hint": "open the settings screen and I'll shoot it",
              "notes": ["optional line", ...]}]}

An AC whose shot is absent, or names a file that does not exist, draws a dashed
missing-proof row carrying its hint, so a failed capture is visible rather than
a silent gap. The page opens with a count of captured ACs against the total.
Images are copied beside the page, one page and one image folder per slug, so
the page is self-contained in the Henneth folder.

Prints the page path on stdout; any failure exits non-zero with a reason on
stderr. Stdlib only.
"""

import argparse
import html
import json
import re
import shutil
import sys
from pathlib import Path

DEFAULT_OUT_DIR = Path.home() / ".skadi" / "henneth"
PAGE_PREFIX = "ithildin-"
DEFAULT_MISSING_HINT = "not captured yet"

STYLE = """
  body { margin: 0; }
  .proof { max-width: 1100px; margin: 0 auto; padding: 16px; }
  h1 { margin: 0 0 4px; }
  .lede { margin: 0 0 8px; opacity: .8; }
  .tally { margin: 0 0 24px; font-weight: 600; }
  section { margin: 0 0 36px; }
  section h2 { margin: 0 0 8px; font-size: 1.1rem; }
  img { max-width: 100%; height: auto; display: block; border: 1px solid #0003; }
  .missing { border: 1px dashed #0004; padding: 40px 16px; text-align: center; font-size: .9rem; opacity: .7; }
  .notes { font-size: .88rem; margin: 6px 0 0; padding-left: 18px; }
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


def _copy_image(source, images_dir, name):
    """Copy one image beside the page; return its path relative to the page."""
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


def _section(number, ac, images_dir):
    shot = _copy_image(ac["shot"], images_dir, f"ac-{number}") if _present(ac.get("shot")) else None
    return (
        f"<section><h2>{number}. {_text(ac['text'])}</h2>"
        f'{_proof(shot, ac.get("hint"))}{_notes(ac.get("notes"))}</section>',
        shot is not None,
    )


def _page(manifest, sections, proven):
    lede = f'<p class="lede">{_text(manifest["lede"])}</p>' if manifest.get("lede") else ""
    title = _text(manifest["title"])
    tally = f'<p class="tally">{proven} of {len(sections)} captured</p>'
    return (
        '<!doctype html>\n<meta charset="utf-8">\n'
        f'<title>{title}</title>\n<link rel="stylesheet" href="skadi-theme.css">\n'
        f'<style>{STYLE}</style>\n<div class="proof">\n<h1>{title}</h1>\n{lede}\n{tally}\n'
        f'{"".join(sections)}\n</div>\n'
    )


def render(manifest, out_dir):
    """Write the page and its image folder under out_dir; return the page path."""
    slug = _slug(manifest["slug"])
    images_dir = out_dir / f"{PAGE_PREFIX}{slug}"
    shutil.rmtree(images_dir, ignore_errors=True)
    rows = [
        _section(number, ac, images_dir)
        for number, ac in enumerate(manifest["acs"], start=1)
    ]
    proven = sum(1 for _, captured in rows if captured)
    out_dir.mkdir(parents=True, exist_ok=True)
    page = out_dir / f"{PAGE_PREFIX}{slug}.html"
    page.write_text(_page(manifest, [row for row, _ in rows], proven), encoding="utf-8")
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
