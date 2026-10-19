#!/usr/bin/env python3
"""Render the side-by-side page /manwe --human hands to the human's eye.

Usage: python3 -I manwe-compare.py <manifest.json> [--out-dir <dir>]

The manifest names one page and its pairs:

    {"slug": "psg5056", "title": "PSG-5056: Figma vs iPad", "lede": "optional",
     "pairs": [{"title": "ADD NEW", "spec": "/abs/spec.png", "shot": "/abs/shot.png",
                "specLabel": "Figma", "shotLabel": "iPad",
                "specHint": "no frame in Figma", "shotHint": "choose a protocol",
                "notes": ["measured delta", ...]}]}

Each pair draws the spec left and the shot right at the same CSS width, so one
logical px lines up, with a collapsible Overlay whose slider cross-fades them.
A side that is null or names a file that is absent draws a dashed placeholder
carrying its hint. Images are copied beside the page, so the page is
self-contained in the Henneth folder, one page and one image folder per slug.

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
PAGE_PREFIX = "manwe-compare-"
DEFAULT_SPEC_LABEL = "Spec"
DEFAULT_SHOT_LABEL = "Shot"
DEFAULT_MISSING_HINT = "not captured yet"
INITIAL_OVERLAY_PERCENT = 50

STYLE = """
  body { margin: 0; }
  .compare { max-width: 2200px; margin: 0 auto; padding: 16px; }
  h1 { margin: 0 0 4px; }
  .lede { margin: 0 0 20px; opacity: .8; }
  section { margin: 0 0 40px; }
  section h2 { margin: 0 0 8px; font-size: 1.15rem; }
  .pair { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; align-items: start; }
  figure { margin: 0; }
  figcaption { font-size: .85rem; font-weight: 600; margin: 0 0 6px; }
  img { width: 100%; height: auto; display: block; border: 1px solid #0003; }
  .missing { border: 1px dashed #0004; padding: 40px 16px; text-align: center; font-size: .9rem; opacity: .7; }
  .overlay { position: relative; margin-top: 12px; max-width: 1024px; }
  .overlay img + img { position: absolute; inset: 0 auto auto 0; }
  .ctl { font-size: .85rem; margin-top: 12px; display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  details summary { cursor: pointer; font-size: .9rem; }
  .notes { font-size: .88rem; margin: 6px 0 0; padding-left: 18px; }
  @media (max-width: 900px) { .pair { grid-template-columns: 1fr; } }
"""

SLIDER_SCRIPT = """
  document.querySelectorAll('details').forEach(d => {
    const top = d.querySelector('img.top');
    if (!top) return;
    const range = document.createElement('input');
    range.type = 'range';
    range.min = 0;
    range.max = 100;
    range.value = d.dataset.start;
    range.addEventListener('input', () => { top.style.opacity = range.value / 100; });
    const ctl = document.createElement('label');
    ctl.className = 'ctl';
    ctl.append(d.dataset.specLabel + ' ', range, ' ' + d.dataset.shotLabel);
    d.insertBefore(ctl, d.querySelector('.overlay'));
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


def _copy_image(source, images_dir, name):
    """Copy one image beside the page; return its path relative to the page."""
    target = f"{name}{Path(source).suffix}"
    images_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, images_dir / target)
    return f"{images_dir.name}/{target}"


def _figure(caption, image, hint):
    body = f'<img src="{_text(image)}">' if image else f'<div class="missing">{_text(hint)}</div>'
    return f"<figure><figcaption>{_text(caption)}</figcaption>{body}</figure>"


def _overlay(spec_image, shot_image, spec_label, shot_label):
    labels = (
        f'data-spec-label="{_text(spec_label)}" data-shot-label="{_text(shot_label)}"'
        f' data-start="{INITIAL_OVERLAY_PERCENT}"'
    )
    return (
        f"<details {labels}><summary>Overlay</summary>"
        f'<div class="overlay"><img src="{_text(spec_image)}">'
        f'<img class="top" src="{_text(shot_image)}" style="opacity:{INITIAL_OVERLAY_PERCENT / 100}"></div>'
        "</details>"
    )


def _notes(notes):
    if not notes:
        return ""
    items = "".join(f"<li>{_text(note)}</li>" for note in notes)
    return f'<ul class="notes">{items}</ul>'


def _section(number, pair, images_dir):
    spec = _copy_image(pair["spec"], images_dir, f"pair-{number}-spec") if _present(pair.get("spec")) else None
    shot = _copy_image(pair["shot"], images_dir, f"pair-{number}-shot") if _present(pair.get("shot")) else None
    spec_label = pair.get("specLabel", DEFAULT_SPEC_LABEL)
    shot_label = pair.get("shotLabel", DEFAULT_SHOT_LABEL)
    both = (
        _figure(spec_label, spec, pair.get("specHint") or DEFAULT_MISSING_HINT)
        + _figure(shot_label, shot, pair.get("shotHint") or DEFAULT_MISSING_HINT)
    )
    overlay = _overlay(spec, shot, spec_label, shot_label) if spec and shot else ""
    return (
        f"<section><h2>{number}. {_text(pair.get('title', ''))}</h2>"
        f'<div class="pair">{both}</div>{overlay}{_notes(pair.get("notes"))}</section>'
    )


def _page(manifest, sections):
    lede = f'<p class="lede">{_text(manifest["lede"])}</p>' if manifest.get("lede") else ""
    title = _text(manifest["title"])
    return (
        '<!doctype html>\n<meta charset="utf-8">\n'
        f'<title>{title}</title>\n<link rel="stylesheet" href="skadi-theme.css">\n'
        f'<style>{STYLE}</style>\n<div class="compare">\n<h1>{title}</h1>\n{lede}\n'
        f'{"".join(sections)}\n</div>\n<script>{SLIDER_SCRIPT}</script>\n'
    )


def render(manifest, out_dir):
    """Write the page and its image folder under out_dir; return the page path."""
    slug = _slug(manifest["slug"])
    images_dir = out_dir / f"{PAGE_PREFIX}{slug}"
    shutil.rmtree(images_dir, ignore_errors=True)
    sections = [
        _section(number, pair, images_dir)
        for number, pair in enumerate(manifest["pairs"], start=1)
    ]
    out_dir.mkdir(parents=True, exist_ok=True)
    page = out_dir / f"{PAGE_PREFIX}{slug}.html"
    page.write_text(_page(manifest, sections), encoding="utf-8")
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
        print(f"manwe-compare: manifest {args.manifest}: missing field {field}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as reason:
        print(f"manwe-compare: manifest {args.manifest}: {reason}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
