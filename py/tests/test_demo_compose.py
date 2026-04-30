"""Unit tests for py/demo/compose.py — triptych assembly."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np
from PIL import Image

from demo.compose import compose_triptych


def _solid_frames(color, count, w, h):
    return [np.full((h, w, 3), color, dtype=np.uint8) for _ in range(count)]


def test_compose_dimensions():
    inp = _solid_frames((255, 0, 0), 3, 8, 4)
    ccl = _solid_frames((0, 255, 0), 3, 8, 4)
    mot = _solid_frames((0, 0, 255), 3, 8, 4)
    out = compose_triptych(inp, ccl, mot)
    assert len(out) == 3
    for img in out:
        assert isinstance(img, Image.Image)
        assert img.size == (24, 4)  # 3 panels × 8 wide, 4 tall
        assert img.mode == "RGB"


def test_compose_panel_content():
    """Each panel reflects the corresponding source stream's pixel content."""
    inp = _solid_frames((255, 0, 0), 1, 8, 4)
    ccl = _solid_frames((0, 255, 0), 1, 8, 4)
    mot = _solid_frames((0, 0, 255), 1, 8, 4)
    img = np.array(compose_triptych(inp, ccl, mot)[0])
    # Panel 0: x ∈ [0..7] should be all red
    assert (img[:, 0:8] == [255, 0, 0]).all()
    # Panel 1: x ∈ [8..15] should be all green
    assert (img[:, 8:16] == [0, 255, 0]).all()
    # Panel 2: x ∈ [16..23] should be all blue
    assert (img[:, 16:24] == [0, 0, 255]).all()


def test_compose_frame_count_mismatch_raises():
    inp = _solid_frames((255, 0, 0), 3, 8, 4)
    ccl = _solid_frames((0, 255, 0), 2, 8, 4)
    mot = _solid_frames((0, 0, 255), 3, 8, 4)
    import pytest
    with pytest.raises(AssertionError):
        compose_triptych(inp, ccl, mot)


def test_compose_dimension_mismatch_raises():
    inp = _solid_frames((255, 0, 0), 1, 8, 4)
    ccl = _solid_frames((0, 255, 0), 1, 8, 4)
    mot = _solid_frames((0, 0, 255), 1, 16, 4)   # different width
    import pytest
    with pytest.raises(AssertionError):
        compose_triptych(inp, ccl, mot)


def test_compose_no_extra_pixels_added():
    """Composer is panels-only — no labels drawn. All-black inputs → all-black output."""
    inp = _solid_frames((0, 0, 0), 1, 320, 240)
    ccl = _solid_frames((0, 0, 0), 1, 320, 240)
    mot = _solid_frames((0, 0, 0), 1, 320, 240)
    img = np.array(compose_triptych(inp, ccl, mot)[0])
    assert img.sum() == 0, "composer added pixels not from any source stream"
