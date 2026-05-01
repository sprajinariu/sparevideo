"""Unit tests for py/demo/encode.py — animated WebP round-trip."""

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from PIL import Image

from demo.encode import write_webp


def _solid_frames(color, count, w, h):
    return [Image.new("RGB", (w, h), color) for _ in range(count)]


def test_write_webp_creates_file():
    frames = _solid_frames((128, 0, 0), 3, 16, 8)
    with tempfile.NamedTemporaryFile(suffix=".webp", delete=False) as f:
        path = f.name
    write_webp(frames, path, fps=15)
    assert Path(path).exists()
    assert Path(path).stat().st_size > 0


def test_write_webp_round_trip_frame_count():
    # Use different colored frames to avoid Pillow's lossless optimization
    # that collapses identical frames into a single frame
    frames = [
        Image.new("RGB", (16, 8), (255, 0, 0)),
        Image.new("RGB", (16, 8), (0, 255, 0)),
        Image.new("RGB", (16, 8), (0, 0, 255)),
        Image.new("RGB", (16, 8), (255, 255, 0)),
        Image.new("RGB", (16, 8), (255, 0, 255)),
    ]
    with tempfile.NamedTemporaryFile(suffix=".webp", delete=False) as f:
        path = f.name
    write_webp(frames, path, fps=15)
    decoded = Image.open(path)
    # Animated WebP exposes n_frames
    assert getattr(decoded, "n_frames", 1) == 5


def test_write_webp_round_trip_dimensions():
    frames = _solid_frames((0, 0, 128), 2, 32, 16)
    with tempfile.NamedTemporaryFile(suffix=".webp", delete=False) as f:
        path = f.name
    write_webp(frames, path, fps=15)
    decoded = Image.open(path)
    assert decoded.size == (32, 16)
