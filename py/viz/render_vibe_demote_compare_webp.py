"""Render labelled side-by-side animated WebPs comparing ViBe demotion variants.

One WebP per source under media/demo/vibe-demote-compare-<source>.webp. Each WebP
animates 200 frames, showing 4 method outputs left-to-right with method
labels above each panel.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # py/ on sys.path

from experiments.run_vibe_demote_compare import METHODS, N_FRAMES, SOURCES, _produce_masks
from frames.video_source import load_frames

OUT_DIR = Path("media/demo")
OUT_DIR.mkdir(parents=True, exist_ok=True)
LABEL_H = 24  # pixels at top of each frame for the label
FONT_PATHS = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]


def _load_font(size: int) -> ImageFont.FreeTypeFont:
    for path in FONT_PATHS:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def _label_panel(panel: Image.Image, label: str, font: ImageFont.FreeTypeFont) -> Image.Image:
    w, h = panel.size
    out = Image.new("RGB", (w, h + LABEL_H), (40, 40, 40))
    draw = ImageDraw.Draw(out)
    bbox = draw.textbbox((0, 0), label, font=font)
    tx = (w - (bbox[2] - bbox[0])) // 2
    ty = (LABEL_H - (bbox[3] - bbox[1])) // 2
    draw.text((tx, ty), label, fill=(220, 220, 220), font=font)
    out.paste(panel, (0, LABEL_H))
    return out


def render(source: str, n_frames: int = N_FRAMES) -> None:
    frames = load_frames(source, width=320, height=240, num_frames=n_frames)
    if len(frames) < n_frames:
        raise SystemExit(f"{source}: only {len(frames)} frames available, need {n_frames}")
    streams: dict[str, list[np.ndarray]] = {}
    for method in METHODS:
        streams[method] = _produce_masks(method, frames)
    font = _load_font(14)
    h, w = streams[METHODS[0]][0].shape
    pages = []
    for i in range(n_frames):
        labelled = []
        for method in METHODS:
            mask = streams[method][i].astype(np.uint8) * 255
            panel = Image.fromarray(mask, mode="L").convert("RGB")
            labelled.append(_label_panel(panel, method, font))
        strip_w = sum(p.size[0] for p in labelled)
        strip_h = labelled[0].size[1]
        strip = Image.new("RGB", (strip_w, strip_h), (40, 40, 40))
        x = 0
        for p in labelled:
            strip.paste(p, (x, 0))
            x += p.size[0]
        pages.append(strip)
    out_path = OUT_DIR / f"vibe-demote-compare-{source.replace(':', '_').replace('/', '_')}.webp"
    pages[0].save(out_path, format="WEBP", save_all=True,
                  append_images=pages[1:], duration=33, loop=0,
                  lossless=True, quality=80)
    print(f"[{source}] → {out_path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", type=int, default=N_FRAMES)
    parser.add_argument("--source", type=str, default=None,
                        help="run a single source (full path) instead of all SOURCES")
    args = parser.parse_args()
    if args.source:
        render(args.source, args.frames)
    else:
        for src in SOURCES:
            render(src, args.frames)


if __name__ == "__main__":
    main()
