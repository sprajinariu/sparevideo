"""Unit tests for the gamma correction reference model + SV parity."""
from __future__ import annotations

import re
from pathlib import Path

import numpy as np
import pytest

from gen_gamma_lut import srgb_lut
from models.ops.gamma_cor import LUT, gamma_cor


SV_PATH = Path(__file__).resolve().parents[2] / "hw" / "ip" / "gamma" / "rtl" / "axis_gamma_cor.sv"


def test_lut_endpoints() -> None:
    """Black maps to black, white maps to white (LUT[32] is the sentinel)."""
    assert LUT[0] == 0
    assert LUT[32] == 255


def test_lut_monotonic() -> None:
    lut = srgb_lut()
    assert all(lut[i] <= lut[i + 1] for i in range(32))


def test_endpoints_round_trip() -> None:
    """gamma_cor(0) == 0; gamma_cor(255) == (LUT[31] + 7*LUT[32]) >> 3."""
    img = np.zeros((1, 2, 3), dtype=np.uint8)
    img[0, 1] = 255
    out = gamma_cor(img)
    assert out[0, 0].tolist() == [0, 0, 0]
    expected_top = (int(LUT[31]) + 7 * int(LUT[32])) >> 3
    assert out[0, 1].tolist() == [expected_top] * 3


def test_pixel_128() -> None:
    """pixel=128: addr=16, frac=0 -> exactly LUT[16]."""
    img = np.full((1, 1, 3), 128, dtype=np.uint8)
    out = gamma_cor(img)
    assert out[0, 0].tolist() == [int(LUT[16])] * 3


def test_pixel_4_interpolated() -> None:
    """pixel=4: addr=0, frac=4 -> (LUT[0]*4 + LUT[1]*4) >> 3."""
    img = np.full((1, 1, 3), 4, dtype=np.uint8)
    out = gamma_cor(img)
    expected = (int(LUT[0]) * 4 + int(LUT[1]) * 4) >> 3
    assert out[0, 0].tolist() == [expected] * 3


def test_per_channel_independence() -> None:
    """Each channel goes through the same LUT independently."""
    img = np.array([[[0, 64, 200]]], dtype=np.uint8)
    out = gamma_cor(img)
    expected_r = (int(LUT[0])  * 8 + int(LUT[1])  * 0) >> 3   # addr=0,  frac=0
    expected_g = (int(LUT[8])  * 8 + int(LUT[9])  * 0) >> 3   # addr=8,  frac=0
    expected_b = (int(LUT[25]) * 8 + int(LUT[26]) * 0) >> 3   # addr=25, frac=0
    assert out[0, 0].tolist() == [expected_r, expected_g, expected_b]


def test_sv_lut_matches_python() -> None:
    """Parse the SV localparam in axis_gamma_cor.sv; bytes must match the Python LUT."""
    if not SV_PATH.exists():
        pytest.skip(f"{SV_PATH} not yet created (Task 5)")
    text = SV_PATH.read_text()
    match = re.search(
        r"localparam\s+logic\s*\[7:0\]\s+SRGB_LUT\s*\[(?:0:32|33)\]\s*=\s*'\{([^}]*)\}",
        text,
    )
    assert match is not None, "SRGB_LUT localparam not found in axis_gamma_cor.sv"
    bytes_text = match.group(1)
    sv_values = [int(m.group(1)) for m in re.finditer(r"8'd\s*(\d+)", bytes_text)]
    assert len(sv_values) == 33, f"expected 33 LUT entries, got {len(sv_values)}"
    assert sv_values == srgb_lut(), "SV LUT bytes do not match Python srgb_lut()"
