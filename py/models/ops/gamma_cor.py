"""sRGB gamma correction reference model.

Mirrors axis_gamma_cor RTL exactly: per-channel 33-entry LUT addressed by
pixel[7:3] with linear interpolation across pixel[2:0]:

    addr = p >> 3
    frac = p & 0x7
    out  = (LUT[addr] * (8 - frac) + LUT[addr + 1] * frac) >> 3

The LUT is computed at import time from the closed-form sRGB encode formula
in py/gen_gamma_lut.py; the same script prints the matching SV localparam.
The SV-vs-Python parity test in py/tests/test_gamma_cor.py catches drift.
"""
from __future__ import annotations

import numpy as np

from gen_gamma_lut import srgb_lut

LUT = np.asarray(srgb_lut(), dtype=np.uint16)
assert LUT.shape == (33,)
assert LUT[0] == 0


def gamma_cor(image: np.ndarray) -> np.ndarray:
    """Apply per-channel sRGB encode LUT to an (H, W, 3) uint8 RGB image."""
    if image.dtype != np.uint8:
        raise TypeError(f"gamma_cor expects uint8, got {image.dtype}")
    if image.ndim != 3 or image.shape[2] != 3:
        raise ValueError(f"gamma_cor expects (H, W, 3), got {image.shape}")
    p    = image.astype(np.uint16)
    addr = p >> 3
    frac = p & 0x7
    lo   = LUT[addr]
    hi   = LUT[addr + 1]
    out  = (lo * (8 - frac) + hi * frac) >> 3
    return out.astype(np.uint8)
