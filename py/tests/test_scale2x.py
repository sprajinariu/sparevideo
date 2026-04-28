"""Unit tests for the scale2x reference model.

Two hand-crafted goldens per mode keep the tests legible; the pipeline-level
test_models.py composition checks (added in Task 11) cover larger images.
"""
import numpy as np
import pytest

from models.ops.scale2x import scale2x


def _rgb(*triples):
    return np.array(triples, dtype=np.uint8).reshape(-1, 3)


def test_nn_2x2():
    src = np.array([[[10, 20, 30], [40, 50, 60]],
                    [[70, 80, 90], [100, 110, 120]]], dtype=np.uint8)
    out = scale2x(src, mode="nn")
    expected = np.array([
        [[10, 20, 30], [10, 20, 30], [40, 50, 60], [40, 50, 60]],
        [[10, 20, 30], [10, 20, 30], [40, 50, 60], [40, 50, 60]],
        [[70, 80, 90], [70, 80, 90], [100, 110, 120], [100, 110, 120]],
        [[70, 80, 90], [70, 80, 90], [100, 110, 120], [100, 110, 120]],
    ], dtype=np.uint8)
    assert np.array_equal(out, expected)


def test_bilinear_horizontal_only():
    # Single-row check: vertical interp degenerates to identity.
    src = np.array([[[0, 0, 0], [100, 100, 100], [200, 200, 200]]], dtype=np.uint8)
    out = scale2x(src, mode="bilinear")
    # Even cols: 0, 100, 200; odd cols: (0+100+1)/2=50, (100+200+1)/2=150,
    # right-edge replicate: 200.
    expected_row = np.array([[0, 0, 0], [50, 50, 50], [100, 100, 100],
                             [150, 150, 150], [200, 200, 200], [200, 200, 200]],
                            dtype=np.uint8)
    # Top out row == source; bottom out row == avg(top, prev) == top (top-edge replicate).
    assert np.array_equal(out[0], expected_row)
    assert np.array_equal(out[1], expected_row)


def test_bilinear_2x2_round_half_up():
    src = np.array([[[0, 0, 0], [3, 3, 3]],
                    [[7, 7, 7], [11, 11, 11]]], dtype=np.uint8)
    out = scale2x(src, mode="bilinear")
    # Top output rows replicate source row 0 horizontally:
    #   0, (0+3+1)/2=2, 3, 3 (right replicate)
    # Bottom output row 0 (interp between source row 0 and source row 0): same as top
    # Bottom output row 1 (interp between source row 1 and source row 0):
    #   horiz of row 1: 7, (7+11+1)/2=9, 11, 11
    #   vert avg: (0+7+1)/2=4, (2+9+1)/2=6, (3+11+1)/2=7, (3+11+1)/2=7
    assert out[0, 0, 0] == 0 and out[0, 1, 0] == 2 and out[0, 2, 0] == 3 and out[0, 3, 0] == 3
    assert out[1, 0, 0] == 0 and out[1, 1, 0] == 2 and out[1, 2, 0] == 3 and out[1, 3, 0] == 3
    assert out[2, 0, 0] == 7 and out[2, 1, 0] == 9 and out[2, 2, 0] == 11 and out[2, 3, 0] == 11
    assert out[3, 0, 0] == 4 and out[3, 1, 0] == 6 and out[3, 2, 0] == 7 and out[3, 3, 0] == 7


def test_unknown_mode_raises():
    src = np.zeros((2, 2, 3), dtype=np.uint8)
    with pytest.raises(ValueError):
        scale2x(src, mode="lanczos")


def test_dtype_mismatch_raises():
    with pytest.raises(ValueError):
        scale2x(np.zeros((2, 2, 3), dtype=np.float32), mode="nn")
