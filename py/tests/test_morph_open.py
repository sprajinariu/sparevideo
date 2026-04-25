"""Unit tests for py/models/ops/morph_open.py."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np
import pytest

from models.ops.morph_open import morph_open


def test_all_zeros_stays_zero():
    mask = np.zeros((8, 8), dtype=bool)
    out = morph_open(mask)
    assert out.dtype == bool
    assert out.shape == (8, 8)
    assert not out.any()


def test_all_ones_stays_ones():
    mask = np.ones((8, 8), dtype=bool)
    out = morph_open(mask)
    assert out.all()


def test_isolated_pixel_removed():
    mask = np.zeros((8, 8), dtype=bool)
    mask[4, 4] = True
    out = morph_open(mask)
    assert not out.any(), f"Isolated pixel not removed:\n{out.astype(int)}"


def test_thin_stripe_removed():
    mask = np.zeros((8, 8), dtype=bool)
    mask[3, :] = True
    out = morph_open(mask)
    assert not out.any(), f"Thin stripe survived opening:\n{out.astype(int)}"


def test_3x3_block_survives():
    mask = np.zeros((8, 8), dtype=bool)
    mask[2:5, 3:6] = True
    out = morph_open(mask)
    np.testing.assert_array_equal(out, mask)


def test_5x5_block_idempotent():
    mask = np.zeros((8, 8), dtype=bool)
    mask[1:6, 1:6] = True
    out = morph_open(mask)
    np.testing.assert_array_equal(out, mask)


def test_edge_replication_corner():
    mask = np.zeros((8, 8), dtype=bool)
    mask[0:3, 0:3] = True
    out = morph_open(mask)
    np.testing.assert_array_equal(out, mask)
