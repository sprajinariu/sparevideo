"""Unit tests for the axis_hflip Python reference model."""

import sys
from pathlib import Path

import numpy as np

# Allow running standalone (mirrors test_morph_open.py setup).
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from models.ops.hflip import hflip


def test_hflip_2d_uint8():
    img = np.array([[1, 2, 3, 4],
                    [5, 6, 7, 8]], dtype=np.uint8)
    expected = np.array([[4, 3, 2, 1],
                         [8, 7, 6, 5]], dtype=np.uint8)
    out = hflip(img)
    assert out.shape == img.shape
    assert out.dtype == img.dtype
    assert np.array_equal(out, expected)


def test_hflip_3d_rgb():
    img = np.zeros((2, 3, 3), dtype=np.uint8)
    img[0, 0] = (255,   0,   0)
    img[0, 1] = (  0, 255,   0)
    img[0, 2] = (  0,   0, 255)
    out = hflip(img)
    assert tuple(out[0, 0]) == (0,   0, 255)
    assert tuple(out[0, 1]) == (0, 255,   0)
    assert tuple(out[0, 2]) == (255, 0,   0)


def test_hflip_idempotent_twice():
    rng = np.random.default_rng(0)
    img = rng.integers(0, 256, size=(8, 16, 3), dtype=np.uint8)
    assert np.array_equal(hflip(hflip(img)), img)


def test_hflip_does_not_mutate_input():
    img = np.arange(24, dtype=np.uint8).reshape(2, 4, 3)
    snapshot = img.copy()
    _ = hflip(img)
    assert np.array_equal(img, snapshot)


if __name__ == "__main__":
    test_hflip_2d_uint8()
    test_hflip_3d_rgb()
    test_hflip_idempotent_twice()
    test_hflip_does_not_mutate_input()
    print("ALL HFLIP MODEL TESTS PASSED")
