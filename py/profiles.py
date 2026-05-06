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
    morph_open_en=True,
    morph_close_en=True,
    morph_close_kernel=3,
    hflip_en=False,
    gamma_en=True,
    scaler_en=True,
    hud_en=True,
    bbox_color=0x00_FF_00,
    # ---- bg_model selector (Phase 1: Python-only; RTL still EMA) ----
    bg_model=0,                       # BG_MODEL_EMA
    # ---- ViBe knobs (consumed only when bg_model==1) ----
    vibe_K=8,
    vibe_R=20,
    vibe_min_match=2,
    vibe_phi_update=16,
    vibe_phi_diffuse=16,
    vibe_init_scheme=2,               # VIBE_INIT_NOISE — upstream-canonical
    vibe_prng_seed=0xDEADBEEF,
    vibe_coupled_rolls=True,
    vibe_bg_init_mode=1,              # BG_INIT_LOOKAHEAD_MEDIAN
    vibe_bg_init_lookahead_n=0,       # 0 = sentinel "all available frames"
)

# Default + horizontal mirror (selfie-cam).
DEFAULT_HFLIP: ProfileT = dict(DEFAULT, hflip_en=True)

# EMA disabled (alpha=1 → raw frame differencing).
NO_EMA: ProfileT = dict(DEFAULT, alpha_shift=0, alpha_shift_slow=0)

# 3x3 mask opening AND closing bypassed (full mask-cleanup bypass).
NO_MORPH: ProfileT = dict(DEFAULT, morph_open_en=False, morph_close_en=False)

# 3x3 Gaussian pre-filter bypassed.
NO_GAUSS: ProfileT = dict(DEFAULT, gauss_en=False)

# sRGB gamma correction bypassed (linear passthrough at output tail).
NO_GAMMA_COR: ProfileT = dict(DEFAULT, gamma_en=False)

# 2x spatial upscaler bypassed (output resolution = input resolution).
NO_SCALER: ProfileT = dict(DEFAULT, scaler_en=False)

# README demo profile, tuned for the synthetic + Pexels triptychs:
#   scaler_en=False       — 320x240 panels (no 2x upscale)
#   gamma_en=False        — sources are already sRGB-encoded
#   alpha_shift=2         — faster fast-EMA (~4-frame recovery)
#   alpha_shift_slow=8    — bg barely drifts under sustained motion (~1/256/frame)
#                           so slow objects don't accumulate enough bg contamination
#                           to leave a trailing mask after the trailing edge passes
#   grace_frames=0        — synthetic source renders frame 0 as bg-only (boxes start
#                           off-frame), so EMA hard-init has no foreground to bake in.
DEMO: ProfileT = dict(
    DEFAULT, scaler_en=False, gamma_en=False,
    alpha_shift=2, alpha_shift_slow=8, grace_frames=0,
)

# HUD bitmap overlay bypassed.
NO_HUD: ProfileT = dict(DEFAULT, hud_en=False)

# === ViBe profiles (Phase 1: Python-only; RTL still EMA) ===

# Recommended ViBe default. Matches CFG_DEFAULT cleanup pipeline; bg block
# swaps EMA for ViBe (K=8, R=20) with look-ahead median init.
DEFAULT_VIBE: ProfileT = dict(
    DEFAULT,
    bg_model=1,
    vibe_K=8,
    vibe_R=20,
    vibe_min_match=2,
    vibe_phi_update=16,
    vibe_phi_diffuse=16,
    vibe_init_scheme=2,
    vibe_prng_seed=0xDEADBEEF,
    vibe_coupled_rolls=True,
    vibe_bg_init_mode=1,
    vibe_bg_init_lookahead_n=0,
)

# K=20 (literature-default; ~2.5x sample-bank RAM vs DEFAULT_VIBE).
VIBE_K20: ProfileT = dict(DEFAULT_VIBE, vibe_K=20)

# Negative-control: diffusion disabled. Validates diffusion is the frame-0
# ghost dissolution mechanism (design-doc §8 step 4).
VIBE_NO_DIFFUSE: ProfileT = dict(DEFAULT_VIBE, vibe_phi_diffuse=0,
                                  vibe_coupled_rolls=False)

# 3x3 Gaussian pre-filter bypassed under ViBe (peer of NO_GAUSS).
VIBE_NO_GAUSS: ProfileT = dict(DEFAULT_VIBE, gauss_en=False)

# Legacy frame-0 init (no look-ahead). A/B vs DEFAULT_VIBE.
VIBE_INIT_FRAME0: ProfileT = dict(DEFAULT_VIBE, vibe_bg_init_mode=0)

PROFILES: dict[str, ProfileT] = {
    "default":           DEFAULT,
    "default_hflip":     DEFAULT_HFLIP,
    "no_ema":            NO_EMA,
    "no_morph":          NO_MORPH,
    "no_gauss":          NO_GAUSS,
    "no_gamma_cor":      NO_GAMMA_COR,
    "no_scaler":         NO_SCALER,
    "demo":              DEMO,
    "no_hud":            NO_HUD,
    "default_vibe":      DEFAULT_VIBE,
    "vibe_k20":          VIBE_K20,
    "vibe_no_diffuse":   VIBE_NO_DIFFUSE,
    "vibe_no_gauss":     VIBE_NO_GAUSS,
    "vibe_init_frame0":  VIBE_INIT_FRAME0,
}


def resolve(name: str) -> ProfileT:
    if name not in PROFILES:
        raise KeyError(
            f"unknown CFG profile {name!r}; known: {sorted(PROFILES)}"
        )
    return PROFILES[name]
