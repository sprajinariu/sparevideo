"""Animated WebP encoder for the README demo."""

from pathlib import Path
from typing import List, Union
from PIL import Image


def write_webp(
    frames: List[Image.Image],
    path: Union[str, Path],
    fps: int = 15,
    quality: int = 95,
) -> None:
    """Write `frames` as an animated WebP that loops forever.

    All frames must be the same size and mode. `fps` controls per-frame display
    duration; `quality` is Pillow's WebP quality knob (0-100, higher = bigger).
    """
    assert len(frames) > 0, "at least one frame required"
    duration_ms = max(int(round(1000 / fps)), 1)
    frames[0].save(
        str(path),
        format="WEBP",
        save_all=True,
        append_images=frames[1:],
        duration=duration_ms,  # single int — Pillow's WebP writer ignores list form
        loop=0,                # 0 = infinite
        lossless=False,
        quality=quality,
        method=6,              # slowest/best encoder method
    )
