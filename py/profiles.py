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
    vibe_bg_init_external=1,          # BG_INIT_LOOKAHEAD_MEDIAN
    vibe_bg_init_lookahead_n=0,       # 0 = sentinel "all available frames"
    # ---- PBAS knobs (consumed only when bg_model==2) ----
    pbas_N=0,
    pbas_R_lower=0,
    pbas_R_scale=0,
    pbas_Raute_min=0,
    pbas_T_lower=0,
    pbas_T_upper=0,
    pbas_T_init=0,
    pbas_R_incdec_q8=0,
    pbas_T_inc_q8=0,
    pbas_T_dec_q8=0,
    pbas_alpha=0,
    pbas_beta=0,
    pbas_mean_mag_min=0,
    pbas_bg_init_lookahead=0,
    pbas_prng_seed=0,
    pbas_R_upper=0,
    # ---- ViBe persistence-based FG demotion (Phase 1: Python-only) ----
    vibe_demote_en=False,
    vibe_demote_K_persist=0,
    vibe_demote_kernel=0,
    vibe_demote_consistency_thresh=0,
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
    vibe_bg_init_external=1,
    vibe_bg_init_lookahead_n=0,
)

# K=20 (literature-default; ~2.5x sample-bank RAM vs DEFAULT_VIBE).
VIBE_K20: ProfileT = dict(DEFAULT_VIBE, vibe_K=20)

# Negative-control: diffusion disabled. Validates diffusion is the frame-0
# ghost dissolution mechanism (design-doc §8 step 4).
VIBE_NO_DIFFUSE: ProfileT = dict(DEFAULT_VIBE, vibe_phi_diffuse=0)

# 3x3 Gaussian pre-filter bypassed under ViBe (peer of NO_GAUSS).
VIBE_NO_GAUSS: ProfileT = dict(DEFAULT_VIBE, gauss_en=False)

# Legacy frame-0 init (no look-ahead). A/B vs DEFAULT_VIBE.
VIBE_INIT_FRAME0: ProfileT = dict(DEFAULT_VIBE, vibe_bg_init_external=0)

# default_vibe + external-init via lookahead-median ROM. Exercises the
# $readmemh path end-to-end. Lookahead window = full source (sentinel 0).
VIBE_INIT_EXTERNAL: ProfileT = dict(
    DEFAULT_VIBE,
    vibe_bg_init_external=1,
    vibe_bg_init_lookahead_n=0,
)

# PBAS — Hofmann et al. 2012, Y + gradient features. Verified defaults
# from the andrewssobral PBAS.cpp reference impl.
PBAS_DEFAULT: ProfileT = dict(
    DEFAULT,
    bg_model=2,
    pbas_N=20,
    pbas_R_lower=18,
    pbas_R_scale=5,
    pbas_Raute_min=2,
    pbas_T_lower=2,
    pbas_T_upper=200,
    pbas_T_init=18,
    pbas_R_incdec_q8=13,
    pbas_T_inc_q8=256,
    pbas_T_dec_q8=13,
    pbas_alpha=7,
    pbas_beta=1,
    pbas_mean_mag_min=20,
    pbas_bg_init_lookahead=0,
    pbas_prng_seed=0xDEADBEEF,
    pbas_R_upper=0,
)

# PBAS + lookahead-median init (replaces the paper's frame-by-frame init).
PBAS_LOOKAHEAD: ProfileT = dict(PBAS_DEFAULT, pbas_bg_init_lookahead=1)

# Ablation: Raute_min=4 (published follow-up range: 3–5; higher = fewer false-bg).
PBAS_DEFAULT_RAUTE4: ProfileT = dict(PBAS_DEFAULT, pbas_Raute_min=4)

# Ablation: Raute_min=4 AND R_upper=80 cap.
# R_upper is an engineering knob (NOT a published PBAS parameter): caps R(x) from
# above at 80, preventing unbounded match-radius growth in high-d_min ghost regions.
PBAS_DEFAULT_RAUTE4_RCAP: ProfileT = dict(PBAS_DEFAULT, pbas_Raute_min=4, pbas_R_upper=80)

# ViBe + persistence-based foreground demotion (B'). Inherits DEFAULT_VIBE's
# bg-model and cleanup pipeline; toggles vibe_bg_init_external OFF (frame-0
# hard-init — no lookahead crutch) and enables the demote mechanism. Default
# consistency_thresh=3 was promoted from the original 1 after the Phase-1
# results: thresh=1 produced a single-slot-pollution cascade that hollowed
# real moving objects via low-contrast pixels in their outline; thresh=3
# requires three matching bank slots in a BG neighbor before firing, breaking
# the cascade at the cost of a slower wavefront (3 frames per ghost ring
# instead of 1). See docs/plans/2026-05-12-vibe-demote-python-results.md.
VIBE_DEMOTE: ProfileT = dict(
    DEFAULT_VIBE,
    vibe_bg_init_external=0,             # frame-0 hard-init
    vibe_bg_init_lookahead_n=0,          # unused under frame-0 init; keep sentinel
    vibe_demote_en=True,
    vibe_demote_K_persist=30,
    vibe_demote_kernel=3,
    vibe_demote_consistency_thresh=3,
)

# Demo-tuned vibe_demote: inherits DEMO's visual tunings (scaler off, gamma
# off, EMA alpha overrides — though alpha_shift_slow is unused under ViBe)
# and overlays vibe_demote's bg model + demote mechanism. Used for the
# `make demo DEMO_CFG=demo_vibe_demote` README-style WebPs.
DEMO_VIBE_DEMOTE: ProfileT = dict(
    DEMO,
    bg_model=1,
    vibe_K=8,
    vibe_R=20,
    vibe_min_match=2,
    vibe_phi_update=16,
    vibe_phi_diffuse=16,
    vibe_init_scheme=2,
    vibe_prng_seed=0xDEADBEEF,
    vibe_coupled_rolls=True,
    vibe_bg_init_external=0,
    vibe_bg_init_lookahead_n=0,
    vibe_demote_en=True,
    vibe_demote_K_persist=30,
    vibe_demote_kernel=3,
    vibe_demote_consistency_thresh=3,
)

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
    "vibe_no_gauss":      VIBE_NO_GAUSS,
    "vibe_init_frame0":   VIBE_INIT_FRAME0,
    "vibe_init_external":      VIBE_INIT_EXTERNAL,
    "vibe_demote":                  VIBE_DEMOTE,
    "demo_vibe_demote":             DEMO_VIBE_DEMOTE,
    "pbas_default":                 PBAS_DEFAULT,
    "pbas_lookahead":               PBAS_LOOKAHEAD,
    "pbas_default_raute4":          PBAS_DEFAULT_RAUTE4,
    "pbas_default_raute4_rcap":     PBAS_DEFAULT_RAUTE4_RCAP,
}


def resolve(name: str) -> ProfileT:
    if name not in PROFILES:
        raise KeyError(
            f"unknown CFG profile {name!r}; known: {sorted(PROFILES)}"
        )
    return PROFILES[name]


if __name__ == "__main__":
    import argparse, sys
    ap = argparse.ArgumentParser()
    ap.add_argument("--query", required=True, help="profile name")
    ap.add_argument("--field", required=True, help="field name")
    args = ap.parse_args()
    if args.query not in PROFILES:
        sys.exit(f"unknown profile '{args.query}'; known: {sorted(PROFILES)}")
    profile = PROFILES[args.query]
    val = profile.get(args.field)
    if val is None:
        sys.exit(f"field '{args.field}' not in profile '{args.query}'")
    if isinstance(val, bool):
        print(int(val))
    else:
        print(val)
