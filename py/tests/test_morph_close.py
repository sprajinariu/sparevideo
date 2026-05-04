"""Unit tests for py/models/ops/morph_close.py.

morph_close mirrors the future axis_morph_clean RTL close stage. The
contract: input is a (H, W) bool mask, output is a (H, W) bool mask
after dilate-then-erode with the requested kernel. Kernel ∈ {3, 5}.
EDGE_REPLICATE policy at all four borders (scipy mode='nearest').
"""
from __future__ import annotations
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np
import pytest

from models.ops.morph_close import morph_close


def _put(mask: np.ndarray, ys, xs) -> None:
    for y, x in zip(ys, xs):
        mask[y, x] = True


def test_3x3_close_fills_single_pixel_hole():
    """A 1-px hole in the centre of a 3x3 foreground patch is filled by
    a 3x3 close (dilate fills the hole; subsequent erode preserves it)."""
    m = np.zeros((5, 5), dtype=bool)
    m[1:4, 1:4] = True
    m[2, 2] = False  # 1-px hole at center
    out = morph_close(m, kernel=3)
    assert out[2, 2], "3x3 close should fill a 1-px hole"
    # Outer foreground unchanged.
    assert out[1:4, 1:4].all()


def test_3x3_close_does_not_fill_3x3_hole():
    """A 3x3 hole inside a 5x5 foreground is NOT filled by a 3x3 close
    (the dilate can only grow blobs by one pixel; the hole is too big)."""
    m = np.ones((7, 7), dtype=bool)
    m[2:5, 2:5] = False  # 3x3 hole at center
    out = morph_close(m, kernel=3)
    assert not out[3, 3], "3x3 close should NOT fill a 3x3 hole"


def test_5x5_close_fills_2x2_hole():
    """A 2x2 hole inside a larger foreground is filled by a 5x5 close."""
    m = np.ones((8, 8), dtype=bool)
    m[3:5, 3:5] = False  # 2x2 hole
    out = morph_close(m, kernel=5)
    assert out[3:5, 3:5].all(), "5x5 close should fill a 2x2 hole"


def test_5x5_close_does_not_fill_5x5_hole():
    """A 5x5 hole is too big for a 5x5 close to fill."""
    m = np.ones((9, 9), dtype=bool)
    m[2:7, 2:7] = False  # 5x5 hole
    out = morph_close(m, kernel=5)
    assert not out[4, 4]


def test_close_does_not_grow_isolated_blob():
    """Idempotency-style: closing a single 3x3 isolated blob leaves it
    at the same outer extent (close = dilate then erode, both with same SE).
    """
    m = np.zeros((7, 7), dtype=bool)
    m[2:5, 2:5] = True
    out = morph_close(m, kernel=3)
    expected = m.copy()
    np.testing.assert_array_equal(out, expected)


def test_close_idempotent():
    """Applying close twice yields the same result as applying it once."""
    rng = np.random.default_rng(seed=42)
    m = rng.random((20, 20)) > 0.3  # ~70% foreground
    once  = morph_close(m, kernel=3)
    twice = morph_close(once, kernel=3)
    np.testing.assert_array_equal(once, twice)


def test_close_kernel_value_validation():
    m = np.zeros((4, 4), dtype=bool)
    with pytest.raises(ValueError, match="kernel must be 3 or 5"):
        morph_close(m, kernel=4)
    with pytest.raises(ValueError, match="kernel must be 3 or 5"):
        morph_close(m, kernel=7)


def test_close_dtype_check():
    m = np.zeros((4, 4), dtype=np.uint8)
    with pytest.raises(TypeError):
        morph_close(m, kernel=3)
