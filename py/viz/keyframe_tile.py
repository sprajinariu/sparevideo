"""Extract a few keyframes from each animated WebP and stack vertically into a
single PNG so a multimodal reviewer can do qualitative inspection across the
timeline in a single image."""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

WEBP_PATHS = [
    Path("media/demo/pbas-compare-media_source_birdseye-320x240.mp4.webp"),
    Path("media/demo/pbas-compare-media_source_people-320x240.mp4.webp"),
]
KEYFRAMES = [0, 16, 32, 64, 96, 128, 160, 199]
OUT_DIR = Path("py/experiments/our_outputs/pbas_compare_keyframes")
OUT_DIR.mkdir(parents=True, exist_ok=True)
LABEL_W = 56  # pixels reserved on the left for the "Frame N" tag


def _load_font(size: int) -> ImageFont.FreeTypeFont:
    for path in [
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def tile(webp_path: Path) -> Path:
    im = Image.open(webp_path)
    n_frames = getattr(im, "n_frames", 1)
    valid_kf = [k for k in KEYFRAMES if k < n_frames]
    rows = []
    for k in valid_kf:
        im.seek(k)
        rows.append(im.convert("RGB"))
    strip_w, strip_h = rows[0].size
    grid_w = LABEL_W + strip_w
    grid_h = strip_h * len(rows)
    grid = Image.new("RGB", (grid_w, grid_h), (40, 40, 40))
    font = _load_font(13)
    draw = ImageDraw.Draw(grid)
    for i, (k, page) in enumerate(zip(valid_kf, rows)):
        grid.paste(page, (LABEL_W, i * strip_h))
        draw.text((6, i * strip_h + strip_h // 2 - 7), f"f={k:>3}",
                  fill=(220, 220, 220), font=font)
    out = OUT_DIR / (webp_path.stem + "_keyframes.png")
    grid.save(out)
    print(f"{webp_path.name} -> {out}  ({n_frames} frames, {len(valid_kf)} keyframes)")
    return out


def main() -> None:
    for p in WEBP_PATHS:
        if not p.exists():
            print(f"missing: {p}")
            continue
        tile(p)


if __name__ == "__main__":
    main()
