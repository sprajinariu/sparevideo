"""Algorithm-tuning profiles. Mirrors cfg_t in hw/top/sparevideo_pkg.sv.

A profile is a flat dict of fields that the reference models accept as
kwargs. Adding a new field requires (a) a new struct member in
sparevideo_pkg, (b) a new key in every dict here. The SV/Python parity
test (test_profiles.py) catches drift.
"""
from __future__ import annotations

from typing import Mapping

ProfileT = Mapping[str, int | bool]

DEFAULT: ProfileT = dict(
    motion_thresh=16,
    alpha_shift=3,
    alpha_shift_slow=6,
    grace_frames=0,
    grace_alpha_shift=1,
    gauss_en=True,
    morph_en=True,
    hflip_en=False,
    gamma_en=True,
    scaler_en=True,
    scale_filter="bilinear",
    bbox_color=0x00_FF_00,
)

# Default + horizontal mirror (selfie-cam).
DEFAULT_HFLIP: ProfileT = dict(DEFAULT, hflip_en=True)

# EMA disabled (alpha=1 → raw frame differencing).
NO_EMA: ProfileT = dict(DEFAULT, alpha_shift=0, alpha_shift_slow=0)

# 3x3 mask opening bypassed.
NO_MORPH: ProfileT = dict(DEFAULT, morph_en=False)

# 3x3 Gaussian pre-filter bypassed.
NO_GAUSS: ProfileT = dict(DEFAULT, gauss_en=False)

# sRGB gamma correction bypassed (linear passthrough at output tail).
NO_GAMMA_COR: ProfileT = dict(DEFAULT, gamma_en=False)

# 2x spatial upscaler bypassed (output resolution = input resolution).
NO_SCALER: ProfileT = dict(DEFAULT, scaler_en=False)

PROFILES: dict[str, ProfileT] = {
    "default":       DEFAULT,
    "default_hflip": DEFAULT_HFLIP,
    "no_ema":        NO_EMA,
    "no_morph":      NO_MORPH,
    "no_gauss":      NO_GAUSS,
    "no_gamma_cor":  NO_GAMMA_COR,
    "no_scaler":     NO_SCALER,
}


def resolve(name: str) -> ProfileT:
    if name not in PROFILES:
        raise KeyError(
            f"unknown CFG profile {name!r}; known: {sorted(PROFILES)}"
        )
    return PROFILES[name]
